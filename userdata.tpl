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


echo "### SETUP AGENT"
# Written FIRST, before any yum: with `set -eux` a failure further down used to
# abort the userdata before this block, the agent then registered in the
# "default" cluster and the node never joined (2026-10-23: 18 staging/uat
# nodes, TOPS-12504). Safe this early - ecs.service starts after cloud-final,
# i.e. only once the rest of this script (EFS mount included) has run.
echo "ECS_CLUSTER=${tf_cluster_name}" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true" >> /etc/ecs/ecs.config

# ecs.service is only ordered After=cloud-final - it starts even when this
# script fails. With the cluster already configured above, a failed mandatory
# step (package install, EFS mount, extra userdata) must not leave a node that
# joins the cluster and takes tasks half-bootstrapped: keep the agent off
# instead. The node then shows as InService but not registered, which the
# golden-AMI morning check alerts on.
bootstrap_failed() {
  echo "ERROR: mandatory bootstrap step failed - masking ecs.service so this node does not join the cluster"
  systemctl mask --now ecs || true
}
trap bootstrap_failed ERR

echo "### INSTALL PACKAGES"
# At boot the SSM agent installs its plugins (Inspector, GuardDuty runtime
# monitoring, SSM agent update associations) at the same time as this script,
# and yum fails straight away with "can't create transaction lock on
# /var/lib/rpm/.rpm.lock". Retry instead of aborting on the first collision.
yum_retry() {
  for attempt in $(seq 1 20); do
    yum "$@" && return 0
    echo "WARN: yum $* failed (attempt $attempt/20, rpm lock held by another installer?) - retrying in 15s"
    sleep 15
  done
  return 1
}
# The patched golden AMI is already current; a failed update must not stop
# the node from joining.
yum_retry update -y || echo "WARN: yum update failed after retries - continuing on the AMI's packages"
yum_retry install -y amazon-efs-utils aws-cli
# yum-utils is only needed for `needs-restarting -r` below. On AL2023 the
# yum shim resolves this to dnf-utils and a transient dnf cache race can
# cause the transaction to abort mid-install (RPM disappears from cache
# before install completes). Because `set -eux` is on, that would abort the
# rest of the userdata (EFS, extra userdata, reboot check). Make this
# install non-fatal — the reboot
# check below already handles missing needs-restarting via its default
# case branch.
yum_retry install -y yum-utils || echo "WARN: yum-utils install failed, needs-restarting reboot check will be skipped"


echo "### SETUP EFS"
EFS_DIR=/mnt/efs
EFS_ID=${tf_efs_id}

mkdir -p $${EFS_DIR}
echo "$${EFS_ID}:/ $${EFS_DIR} efs tls,_netdev" >> /etc/fstab

for i in $(seq 1 20); do mount -a -t efs defaults && break || sleep 60; done
# The loop above ends successfully even when every attempt failed.
mountpoint -q "$${EFS_DIR}"



echo "### EXTRA USERDATA"
${userdata_extra}

# Mandatory bootstrap done; nothing below may keep the agent off.
trap - ERR

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
