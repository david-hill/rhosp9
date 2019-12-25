#!/bin/bash
#
# This runs an upgrade of Cinder Block Storage nodes.
#
set -eu

# Always ensure yum has full cache
yum makecache || echo "Yum makecache failed. This can cause failure later on."

# Special-case OVS for https://bugs.launchpad.net/tripleo/+bug/1635205
special_case_ovs_upgrade_if_needed

yum -y install python-zaqarclient  # needed for os-collect-config
yum -y -q update
