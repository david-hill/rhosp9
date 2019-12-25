#!/bin/bash

set -eu

DEBUG="true" # set false if the verbosity is a problem
SCRIPT_NAME=$(basename $0)

function log_debug {
  if [[ $DEBUG = "true" ]]; then
    echo "`date` $SCRIPT_NAME tripleo-upgrade $(facter hostname) $1"
  fi
}

function is_bootstrap_node {
  if [ "$(hiera -c /etc/puppet/hiera.yaml bootstrap_nodeid | tr '[:upper:]' '[:lower:]')" = "$(facter hostname | tr '[:upper:]' '[:lower:]')" ]; then
    log_debug "Node is bootstrap"
    echo "true"
  fi
}

function check_resource {

  if [ "$#" -ne 3 ]; then
      echo_error "ERROR: check_resource function expects 3 parameters, $# given"
      exit 1
  fi

  service=$1
  state=$2
  timeout=$3

  if [ "$state" = "stopped" ]; then
      match_for_incomplete='Started'
  else # started
      match_for_incomplete='Stopped'
  fi

  nodes_local=$(pcs status  | grep ^Online | sed 's/.*\[ \(.*\) \]/\1/g' | sed 's/ /\|/g')
  if timeout -k 10 $timeout crm_resource --wait; then
      node_states=$(pcs status --full | grep "$service" | grep -v Clone | { egrep "$nodes_local" || true; } )
      if echo "$node_states" | grep -q "$match_for_incomplete"; then
          echo_error "ERROR: cluster finished transition but $service was not in $state state, exiting."
          exit 1
      else
        echo "$service has $state"
      fi
  else
      echo_error "ERROR: cluster remained unstable for more than $timeout seconds, exiting."
      exit 1
  fi

}

function echo_error {
    echo "$@" | tee /dev/fd2
}

function systemctl_swift {
    services=( openstack-swift-account-auditor openstack-swift-account-reaper openstack-swift-account-replicator openstack-swift-account \
               openstack-swift-container-auditor openstack-swift-container-replicator openstack-swift-container-updater openstack-swift-container \
               openstack-swift-object-auditor openstack-swift-object-replicator openstack-swift-object-updater openstack-swift-object openstack-swift-proxy )
    action=$1
    case $action in
        stop)
            services=$(systemctl | grep swift | grep running | awk '{print $1}')
            ;;
        start)
            enable_swift_storage=$(hiera -c /etc/puppet/hiera.yaml 'enable_swift_storage')
            if [[ $enable_swift_storage != "true" ]]; then
                services=( openstack-swift-proxy )
            fi
            ;;
        *)  services=() ;;  # for safetly, should never happen
    esac
    for S in ${services[@]}; do
        systemctl $action $S
    done
}

# Special-case OVS for https://bugs.launchpad.net/tripleo/+bug/1635205
function special_case_ovs_upgrade_if_needed {
    if [[ -n $(rpm -q --scripts openvswitch | awk '/postuninstall/,/*/' | grep "systemctl.*try-restart") ]]; then
        echo "Manual upgrade of openvswitch - restart in postun detected"
        rm -rf OVS_UPGRADE
        mkdir OVS_UPGRADE && pushd OVS_UPGRADE
        echo "Attempting to downloading latest openvswitch with yumdownloader"
        yumdownloader --resolve openvswitch
        for pkg in $(ls -1 *.rpm);  do
            if rpm -U --test $pkg 2>&1 | grep "already installed" ; then
                echo "Looks like newer version of $pkg is already installed, skipping"
            else
                echo "Updating $pkg with nopostun option"
                rpm -U --replacepkgs --nopostun $pkg
            fi
        done
        popd
    else
        echo "Skipping manual upgrade of openvswitch - no restart in postun detected"
    fi

}

# https://bugs.launchpad.net/tripleo/+bug/1704131 guard against yum update
# waiting for an existing process until the heat stack time out
function check_for_yum_lock {
    if [[ -f /var/run/yum.pid ]] ; then
        ERR="ERROR existing yum.pid detected - can't continue! Please ensure
there is no other package update process for the duration of the minor update
worfklow. Exiting."
        echo $ERR
        exit 1
   fi
}

# This function tries to resolve an RPM dependency issue that can arise when
# updating ceph packages on nodes that do not run the ceph-osd service. These
# nodes do not require the ceph-osd package, and updates will fail if the
# ceph-osd package cannot be updated because it's not available in any enabled
# repo. The dependency issue is resolved by removing the ceph-osd package from
# nodes that don't require it.
#
# No change is made to nodes that use the ceph-osd service (e.g. ceph storage
# nodes, and hyperconverged nodes running ceph-osd and compute services). The
# ceph-osd package is left in place, and the currently enabled repos will be
# used to update all ceph packages.
function yum_pre_update {
    echo "Checking for ceph-osd dependency issues"

    # No need to proceed if the ceph-osd package isn't installed
    if ! rpm -q ceph-osd >/dev/null 2>&1; then
        echo "ceph-osd package is not installed"
        # Downstream only: ensure the Ceph OSD product key is removed if the
        # ceph-osd package was previously removed.
        rm -f /etc/pki/product/288.pem
        return
    fi

    # Do not proceed if there's any sign that the ceph-osd package is in use:
    # - Are there OSD entries in /var/lib/ceph/osd?
    # - Are any ceph-osd processes running?
    # - Are there any ceph data disks (as identified by 'ceph-disk')
    if [ -n "$(ls -A /var/lib/ceph/osd 2>/dev/null)" ]; then
        echo "ceph-osd package is required (there are OSD entries in /var/lib/ceph/osd)"
        return
    fi

    if [ "$(pgrep -xc ceph-osd)" != "0" ]; then
        echo "ceph-osd package is required (there are ceph-osd processes running)"
        return
    fi

    if ceph-disk list |& grep -q "ceph data"; then
        echo "ceph-osd package is required (ceph data disks detected)"
        return
    fi

    # Get a list of all ceph packages available from the currently enabled
    # repos. Use "--showduplicates" to ensure the list includes installed
    # packages that happen to be up to date.
    local ceph_pkgs="$(yum list available --showduplicates 'ceph-*' |& awk '/^ceph/ {print $1}' | sort -u)"

    # No need to proceed if no ceph packages are available from the currently
    # enabled repos.
    if [ -z "$ceph_pkgs" ]; then
        echo "ceph packages are not available from any enabled repo"
        return
    fi

    # No need to proceed if the ceph-osd package *is* available
    if [[ $ceph_pkgs =~ ceph-osd ]]; then
        echo "ceph-osd package is available from an enabled repo"
        return
    fi

    echo "ceph-osd package is not required, but is preventing updates to other ceph packages"
    echo "Removing ceph-osd package to allow updates to other ceph packages"
    yum -y remove ceph-osd
    if [ $? -eq 0 ]; then
        # Downstream only: remove the Ceph OSD product key (rhbz#1500594)
        rm -f /etc/pki/product/288.pem
    fi
}
