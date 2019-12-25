#!/bin/bash
#
# This delivers the ceph-storage upgrade script to be invoked as part of the tripleo
# major upgrade workflow.
#
set -eu

UPGRADE_SCRIPT=/root/tripleo_upgrade_node.sh

declare -f special_case_ovs_upgrade_if_needed > $UPGRADE_SCRIPT
# use >> here so we don't lose the declaration we added above
cat >> $UPGRADE_SCRIPT << ENDOFCAT
#!/bin/bash
### DO NOT MODIFY THIS FILE
### This file is automatically delivered to the ceph-storage nodes as part of the
### tripleo upgrades workflow


function systemctl_ceph {
    action=\$1
    systemctl \$action ceph
}

# "so that mirrors aren't rebalanced as if the OSD died" - gfidente
ceph osd set noout

systemctl_ceph stop

# Always ensure yum has full cache
yum makecache || echo "Yum makecache failed. This can cause failure later on."

special_case_ovs_upgrade_if_needed
yum -y install python-zaqarclient  # needed for os-collect-config
yum -y update
systemctl_ceph start

ceph osd unset noout

ENDOFCAT

# ensure the permissions are OK
chmod 0755 $UPGRADE_SCRIPT

