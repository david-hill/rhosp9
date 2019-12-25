#!/bin/bash
#
# This delivers the compute upgrade script to be invoked as part of the tripleo
# major upgrade workflow.
#
set -eu

UPGRADE_SCRIPT=/root/tripleo_upgrade_node.sh

cat > $UPGRADE_SCRIPT << ENDOFCAT
### DO NOT MODIFY THIS FILE
### This file is automatically delivered to the compute nodes as part of the
### tripleo upgrades workflow

# pin nova to kilo (messaging +-1) for the nova-compute service

crudini  --set /etc/nova/nova.conf upgrade_levels compute $upgrade_level_nova_compute

# Always ensure yum has full cache
yum makecache || echo "Yum makecache failed. This can cause failure later on."

$(declare -f special_case_ovs_upgrade_if_needed)
special_case_ovs_upgrade_if_needed

yum -y install python-zaqarclient  # needed for os-collect-config
yum -y install openstack-nova-migration # needed for libvirt migration via ssh
yum -y update

# Problem creating vif if not restarted.
if systemctl is-enabled openvswitch; then
   systemctl restart openvswitch
fi

# Look like it is required after the installation of the new openvswitch.
if systemctl is-enabled neutron-openvswitch-agent; then
    if systemctl is-failed neutron-openvswitch-agent; then
        systemctl restart neutron-openvswitch-agent
    fi
fi

ENDOFCAT

# ensure the permissions are OK
chmod 0755 $UPGRADE_SCRIPT

