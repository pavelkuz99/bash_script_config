#!/bin/bash

USAGE="setup.sh <DVD_ISO_mountpoint> <DVD_ISO_device> <three_component_devices> <LVM_mount_point>"

set -e

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $@" >&2
}

log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $@"
}

arguments_check(){
  if [[ -z "$*" ]]; then 
      err "no arguments given" 
      echo "usage:  $USAGE"; exit 1
    elif [[ "$#" -lt 6  ]]; then
      err "few arguments given"
      echo "USAGE:  $USAGE"; exit 1
   else
    if [[ $(blkid | grep $2 | wc -l) -eq 0 ]]; then
      err "no DVD ISO drive named '$2' inserted"; exit 1
    fi 
    for directory in $1 $6; do
      if [[ -d $directory && ! $(df --output=target | grep -qws $directory) ]]; then
        log "$directory directory exists and available"
      else
        err "$directory directory does not exist or already mounted"; exit 1
      fi
    done
    for argument in $3 $4 $5; do 
      if [[ -b $argument && ! $(grep -qs $argument /proc/mounts) ]]; then
        log "$argument block device exists and available"
      else
        err "$argument block device does not exist or already mounted"; exit 1
      fi
    done
  fi
}

ISO_DIR=$1; 
ISO_DEVICE=$2; 
BLOCK1=$3; BLOCK2=$4; BLOCK3=$5
RAID_MOUNT=$6

configure_ssh(){
   echo 'AllowUsers root' >> /etc/ssh/sshd_config
   iptables -A INPUT -i eth0 -p tcp --dport 22 -j ACCEPT
   iptables -A INPUT -i eth0 -p tcp ! --dport 22 -j DROP
   systemctl restart sshd.service
   log "configured ssh service, restricted to root and port 22"  
}

setup_local_repo() {
  mount $1 $2
  echo "UUID=$(blkid $ISO_DEVICE -s UUID -o value)\
        $ISO_DIR $(blkid $ISO_DEVICE -s TYPE -o value) ro,user,auto 0 0" >> /etc/fstab
  for param in "[LocalRepo]" "name=LocalRepository" "baseurl=file://$2" "enabled=1"\
               "gpgcheck=1" "gpgkey=file:///etc/pki/rpm-gpg/RPM-KEY-CentOS-7"; do    
    echo $param >> /etc/yum.repos.d/local.repo
  done
}

add_local_repo(){
if [[ $(yum repoinfo LocalRepo | grep enabled | wc -l) -ge 1 ]]; then
    log "local repo is already enabled"
  else
    setup_local_repo $ISO_DEVICE $ISO_DIR
    log "permanently added local DVD ISO repo on $ISO_DIR"
fi
}

install_packages(){
if [[ $(yum repoinfo LocalRepo | grep enabled | wc -l) -ge 1 ]]; then
    yum -y -q install $@; log "installed $@ packages"
  else
    err "local repo is not enabled, can not install required $@ packages"; exit 1
fi
}

setup_raid5_lvm() {    
  mdadm --create $1 --level=5 --raid-devices=3 $BLOCK{1..3} ||\
        (err "can\'t create RAID5 with mdadm, exiting..." && exit 2)
  RAID_DEVICE=$(cat /proc/mdstat | grep "$1\|active\|$BLOCK1\|$BLOCK2\|$BLOCK3")
  if [[ ! -z $RAID_DEVICE ]]; then
      log "RAID5 of $BLOCK1, $BLOCK2, $BLOCK3 succesfully created"   
    else
      err "some issues with RAID5"; exit 1   
  fi
  pvcreate $1 || err "can not create physical volume on $1"
  log "created $1 physical volume"
  vgcreate raid5 $1 || err "can not create volume group on $1"
  log "created $1 volume group"
  lvcreate -L 150MB raid5 -n lvm0 || err "can not create vogical volume on $1"
  mkfs.xfs /dev/raid5/lvm0; log "created LVM with xfs on RAID5 - $RAID_DEVICE"
  mount /dev/raid5/lvm0 $RAID_MOUNT; log "mounted RAID5 LVM on $RAID_MOUNT"
  echo "/dev/raid/lvm0   $RAID_MOUNT   xfs  defaults  0 0" >> /etc/fstab
}

setup_nfs_share(){ 
  systemctl enable rpcbind nfs-server nfs-lock nfs-idmap
  systemctl start rpcbind nfs-server nfs-lock nfs-idmap
  log "enabled rpcbind, nfs-server, nfs-lock, nfs-idmap services"
  echo "$RAID_MOUNT *(rw,sync,no_root_squash,no_all_squash)" >> /etc/exports
  exportfs -a; systemctl restart nfs-server
  for service in nfs mountd rpc-bind; do
    firewall-cmd --quiet --permanent --zone=public --add-service=$service
  done
  firewall-cmd --reload
  log "NFS share for $RAID_MOUNT is enabled"
}

arguments_check $@; configure_ssh; add_local_repo; install_packages mdadm nfs-utils;
setup_raid5_lvm /dev/md6; setup_nfs_share
log "script has finished"
