#! /bin/bash

set -eux

echo "### HARDENING DOCKER"
# /etc/sysconfig/docker exists on AL2 ECS AMI but not on AL2023 ECS AMI
# (AL2023 configures Docker via systemd unit drop-ins instead).
if [ -f /etc/sysconfig/docker ]; then
  sed -i "s/1024:4096/65535:65535/g" "/etc/sysconfig/docker"
fi

echo "### HARDENING EC2 INSTACE"
echo "ulimit -u unlimited" >> /etc/rc.local
echo "ulimit -n 1048576" >> /etc/rc.local
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
echo "fs.file-max=65536" >> /etc/sysctl.conf
/sbin/sysctl -p /etc/sysctl.conf


echo "### INSTALL PACKAGES"
yum update -y
yum install -y amazon-efs-utils aws-cli
# yum-utils is only needed for `needs-restarting -r` below. On AL2023 the
# yum shim resolves this to dnf-utils and a transient dnf cache race can
# cause the transaction to abort mid-install (RPM disappears from cache
# before install completes). Because `set -eux` is on, that aborts the
# whole userdata and the SETUP AGENT block never writes ECS_CLUSTER, so
# the node fails to join ECS. Make this install non-fatal — the reboot
# check below already handles missing needs-restarting via its default
# case branch.
yum install -y yum-utils || echo "WARN: yum-utils install failed, needs-restarting reboot check will be skipped"


echo "### SETUP EFS"
EFS_DIR=/mnt/efs
EFS_ID=${tf_efs_id}

mkdir -p $${EFS_DIR}
echo "$${EFS_ID}:/ $${EFS_DIR} efs tls,_netdev" >> /etc/fstab

for i in $(seq 1 20); do mount -a -t efs defaults && break || sleep 60; done

echo "### SETUP AGENT"

echo "ECS_CLUSTER=${tf_cluster_name}" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true" >> /etc/ecs/ecs.config


echo "### EXTRA USERDATA"
${userdata_extra}

echo "### REBOOT IF KERNEL/CORE PACKAGES UPDATED"
# Wiz scans the running kernel; without reboot it stays on the AMI's baked kernel
# even though yum update installed a newer one. Stop the ECS agent first so the
# scheduler does not place tasks on this node before the reboot completes.
# Docker is left running — the reboot stops it cleanly via systemd shutdown,
# and on AL2 ECS AMI the ECS agent is After=cloud-final.service so it hasn't
# started yet at this point (no in-flight tasks to interrupt).
needs-restarting -r >/dev/null 2>&1 && NEEDS_RESTART=0 || NEEDS_RESTART=$?
case $NEEDS_RESTART in
  0)
    echo "No reboot required"
    ;;
  1)
    echo "Reboot required to activate updated kernel"
    systemctl stop ecs || true
    shutdown -r +1 "Activating updated kernel"
    ;;
  *)
    echo "needs-restarting exited $NEEDS_RESTART; skipping reboot to avoid acting on errors"
    ;;
esac
