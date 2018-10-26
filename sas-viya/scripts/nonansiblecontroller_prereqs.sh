#!/bin/bash
## Do initial preperation of the non-ansible boxes. This should be restricted to preparing for ansible to 
## reach onto the box by installing its prerequest (should already be present on redhat), installing nfs to
## mount the ansible controller share, and copying the public key there into the authorized keys.
#
set -x
set -v

DIRECTORY_NFS_SHARE="/exports/bastion"
NFS_MOUNT_POINT="/mnt/AnsibleController/bastion"
NFS_SEMAPHORE_DIR="${NFS_MOUNT_POINT}/setup/readiness_flags"
NFS_ANSIBLE_KEYS="${NFS_MOUNT_POINT}/setup/ansible_key"
NFS_ANSIBLE_INVENTORIES_DIR="${NFS_MOUNT_POINT}/setup/ansible/inventory"
NFS_ANSIBLE_GROUPS_DIR="${NFS_MOUNT_POINT}/setup/ansible/groups"

if [ -z "$1" ]; then
	PRIMARY_USER="sas"
else
	PRIMARY_USER="$1"
fi
nfs_server_fqdn="$2"
if [ -z "$nfs_server_fqdn" ]; then
	nfs_server_fqdn="ansible"
fi
csv_group_list="$3"


# remove the requiretty from the sudoers file. Per bug https://bugzilla.redhat.com/show_bug.cgi?id=1020147 this is unnecessary and has been removed on future releases of redhat, 
# so is just a slowdown that denies pipelining and makes the non-tty session from azure extentions break on sudo without faking one (my prefered method is ssh back into the same user, but seriously..)
sed -i -e '/Defaults    requiretty/{ s/.*/# Defaults    requiretty/ }' /etc/sudoers

yum install -y nfs-utils rpcbind postfix

systemctl enable postfix
systemctl start postfix

mkdir -p "${NFS_MOUNT_POINT}"
echo "${nfs_server_fqdn}:${DIRECTORY_NFS_SHARE} ${NFS_MOUNT_POINT}  nfs rw,hard,intr,bg 0 0" >> /etc/fstab
#mount -a

mount "${NFS_MOUNT_POINT}"
RET=$?
while [ "$RET" -gt "0" ]; do
	echo "Waiting 5 seconds for mount to be possible"
	sleep 5
	mount "${NFS_MOUNT_POINT}"
	RET=$?
done
echo "Mounting Successful"

wait_count=0
stop_waiting_count=600
ANSIBLE_AUTHORIZED_KEY_FILE="${NFS_ANSIBLE_KEYS}/id_rsa.pub"
while [ ! -e "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; do
	echo "waiting 5 seconds for key to come around"
	sleep 1
	if [ "$((wait_count++))" -gt "$stop_waiting_count" ]; then
		exit 1
	fi
done
su - ${PRIMARY_USER} <<END
mkdir -p $HOME/.ssh
cat "$ANSIBLE_AUTHORIZED_KEY_FILE" >> "/home/${PRIMARY_USER}/.ssh/authorized_keys"
chmod 600 "/home/${PRIMARY_USER}/.ssh/authorized_keys"
END

HOSTNAME="$(hostname | cut -f1 -d'.')"
HOSTNAME_FQDN="$(hostname -f)"
#ansible_become=true
INVENTORY_LINE="${HOSTNAME} ansible_host=${HOSTNAME_FQDN} ansible_user='${PRIMARY_USER}' ansible_ssh_extra_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' ansible_connection='ssh' ansible_ssh_pipelining=true"  

ansible_temp_filename="/tmp/tmp.inv.ansible"

rm -f "$ansible_temp_filename"
OLD_IFS="$IFS"
IFS=","
for v in $csv_group_list; do
echo "[${v}]" >> "$ansible_temp_filename"
echo "${HOSTNAME}" >> "$ansible_temp_filename"
done
IFS="$OLD_IFS"
su - ${PRIMARY_USER} <<END
touch "${NFS_SEMAPHORE_DIR}/$(hostname)_ready"
echo "$INVENTORY_LINE" > "${NFS_ANSIBLE_INVENTORIES_DIR}/$(hostname)_inventory_line"
cat "$ansible_temp_filename" > "${NFS_ANSIBLE_GROUPS_DIR}/$(hostname)_inventory_groups"
END