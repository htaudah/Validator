#!/bin/sh
# A shell script to prepare a Tiny Core virtual machine as a validation appliance for Workspace ONE
# Written by: Hani Audah <ht.aramco@gmail.com>
# Last updated on: May/10/2020
# -------------------------------------------------------------------------------------------------

if [ $# -eq 0 ]; then
    echo "Usage: $0 ip_address"
    exit 1
fi

# Get path the script is running from
SCRIPT=`realpath $0`
SCRIPTPATH=`dirname $SCRIPT`


# This part should be skipped if running from the appliance itself
if [ $1 != 'localhost' ]; then
    # Copy the built-in SSH key to appliance to skip future SSH password prompts
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SCRIPTPATH}/id_rsa.pub tc@$1:/home/tc/.ssh/authorized_keys
    # Now copy all needed local files to appliance
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SCRIPTPATH}/id_rsa tc@$1 "mkdir /home/tc/work"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SCRIPTPATH}/id_rsa ${SCRIPTPATH}/*.sh tc@$1:/home/tc/work
    # Now just continue the script from the appliance itself and exit
    #ssh -i ./id_rsa tc@$1
    exit 0
fi

# Mount the CDROM we booted from to get the install source (this part adapted from Tiny Core tc-install)
CDROMS=`cat /etc/sysconfig/cdroms 2>/dev/null | grep -o sr[[:digit:]]`
for CD in $CDROMS; do
    [ -d /mnt/"$CD" ] && mount /mnt/"$CD" 2>/dev/null
    KERNEL_FOUND=false
    ROOTFS_FOUND=false
    if [ -d /mnt/"$CD"/boot ]; then
        [ -r /mnt/"$CD"/boot/vmlinuz ] &&  KERNEL_FOUND=true
        [ -r /mnt/"$CD"/boot/core.gz ] && ROOTFS_FOUND=true
        [ -r /mnt/"$CD"/boot/vmlinuz64 ] && KERNEL_FOUND=true
        [ -r /mnt/"$CD"/boot/corepure64.gz ] && ROOTFS_FOUND=true
        ( $KERNEL_FOUND ) && ( $ROOTFS_FOUND ) && CDROM="$CD"
        break
    fi
done
if [ -z "$CDROM" ]; then
    echo "Could not find a valid Tiny Core installation CD"
    abort
fi

# Install needed extensions now, before moving to disk in tc-install

# VMWare Tools
tce-load -wi open-vm-tools
# Needed to avoid some obscure error (TODO: details?)
tce-load -wi pcre.tcz
# Web server
tce-load -wi attr.tcz
tce-load -wi lighttpd.tcz
# keep them in a safe place without extensions needed only for creating the image
mkdir -p /tmp/tcz/optional
cp /tmp/tce/optional/* /tmp/tcz/optional/
cp /etc/sysconfig/tcedir/onboot.lst /tmp/tcz

# Create the datastore extension that contains all configuration files to be added to the image
mkdir -p /tmp/prepare/dstore
PREFIX=/tmp/prepare/dstore

# Enable SSH
mkdir -p ${PREFIX}/usr/local/etc/ssh
sudo cp /usr/local/etc/ssh/sshd_config.orig ${PREFIX}/usr/local/etc/ssh/sshd_config
# Allow root login
sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' ${PREFIX}/usr/local/etc/ssh/sshd_config
# Create directories for self-signed certs and keys
sudo mkdir -p ${PREFIX}/etc/ssl/certs
sudo mkdir -p ${PREFIX}/etc/ssl/keys
# Generate the Root CA keys
sudo cp /usr/local/etc/ssl/openssl.cnf.dist /usr/local/etc/ssl/openssl.cnf
sudo openssl genrsa -out ${PREFIX}/etc/ssl/keys/rootselfsigned.key 2048
sudo openssl req -x509 -new -nodes -key ${PREFIX}/etc/ssl/keys/rootselfsigned.key -sha256 -days 1825 \
    -out ${PREFIX}/etc/ssl/certs/rootselfsigned.pem -subj "/C=SA/ST=Riyadh/L=Riyadh/O=VMWare/OU=Workspace One/CN=www.vmware.com"
# Generate the web certificate. Since we're using a wildcard, we can ignore the expected URL
sudo openssl req -new -sha256 -nodes -out ${PREFIX}/etc/ssl/certs/webselfsigned.csr -newkey rsa:2048 \
    -keyout ${PREFIX}/etc/ssl/keys/webselfsigned.key -subj "/C=SA/ST=Riyadh/L=Riyadh/O=VMWare/OU=Workspace ONE/CN=*"
sudo openssl x509 -req -in ${PREFIX}/etc/ssl/certs/webselfsigned.csr -CA ${PREFIX}/etc/ssl/certs/rootselfsigned.pem \
    -CAkey ${PREFIX}/etc/ssl/keys/rootselfsigned.key -CAcreateserial -out ${PREFIX}/etc/ssl/certs/webselfsigned.crt -days 1825 -sha256

# Prepare a dummy site for responses
sudo mkdir -p ${PREFIX}/var/www/test
sudo mkdir -p ${PREFIX}/var/www/uploads
sudo chown tc:staff ${PREFIX}/var/www/test
echo "<html>" >> ${PREFIX}/var/www/test/index.html
echo "  <body>" >> ${PREFIX}/var/www/test/index.html
echo "    Hello friend" >> ${PREFIX}/var/www/test/index.html
echo "  </body>" >> ${PREFIX}/var/www/test/index.html
echo "</html>" >> ${PREFIX}/var/www/test/index.html
# A lighttpd conf suitable for testing
sudo touch ${PREFIX}/var/www/lighttpd.conf
sudo chown tc:staff ${PREFIX}/var/www/lighttpd.conf
sudo cat << EOF > ${PREFIX}/var/www/lighttpd.conf
mimetype.assign = (".html" => "text/html")
server.document-root = "/var/www/test"
server.username = "tc"
server.groupname = "staff"
#server.chroot = "/var/www"
server.upload-dirs=("/var/www/uploads")
server.pid-file == "/var/www/server.pid"
index-file.names=("index.html")
#ssl enabled for all, then disabled as-needed per port
ssl.engine = "enable"
ssl.pemfile = "/etc/ssl/certs/webselfsigned.crt"
ssl.privkey = "/etc/ssl/keys/webselfsigned.key"
ssl.ca-file = "/etc/ssl/certs/rootselfsigned.pem"
EOF
# This is no longer done during appliance setup; the validator will initiate httpd based on
# the port numbers specified in the prereq sheet
#sudo /usr/local/httpd/sbin/httpd -p 80 -h /var/www/test/

# Change root password to match tc
echo "root:vmbox" | sudo chpasswd

# For creating the datastore extension
tce-load -wi squashfs-tools
sudo mksquashfs /tmp/prepare/dstore /tmp/prepare/dstore.tcz
cp /tmp/prepare/dstore.tcz /tmp/tcz/optional/
# Add it to be "installed" during appliance bootup
echo "dstore.tcz" >> /tmp/tcz/onboot.lst

# Install Tiny Core to disk. Parameters for tc-install.sh are as follows:
# (/mnt/"$CDROM"/boot/core.gz: install source, frugal: install type, sda: target, 0: skip boot menu, ext4: file system,
#  yes: make it bootable, no: not installing from Core Plus, X: N/A if not Core Plus, none: N/A if not Core Plus,
#  /tmp/extensionz: install extensions from this dir, tce=sda1
tce-load -wi tc-install
ls /mnt/"$CDROM"/boot/
sudo tc-install.sh /mnt/"$CDROM"/boot/core.gz frugal sda 0 ext4 yes no X none /tmp/tcz tce=sda1 nodhcp waitusb=5

# Work directory for mounting and tailoring the image
mkdir -p /tmp/prepare/disk
mkdir -p /tmp/prepare/extract
sudo mount /dev/sda1 /tmp/prepare/disk
cp /tmp/prepare/disk/tce/boot/core.gz /tmp/prepare/
cd /tmp/prepare/extract
zcat /tmp/prepare/core.gz | sudo cpio -i -H newc -d

# Now the core.gz is unpacked into /tmp/prepare/extract and ready for editing
PREFIX=/tmp/prepare/extract
# Add auto-start services to boot script
echo '/usr/local/etc/init.d/openssh start' | sudo tee -a ${PREFIX}/opt/bootlocal.sh > /dev/null
echo '/usr/local/etc/init.d/open-vm-tools start' | sudo tee -a ${PREFIX}/opt/bootlocal.sh > /dev/null
# Overwrite shadow file to preserve passwords
sudo cp -f -p /etc/shadow ${PREFIX}/etc/shadow
sudo cp ${SCRIPTPATH}/load_ovfprops.sh ${PREFIX}/opt/
cat ${SCRIPTPATH}/load_ovfprops.sh | sudo tee -a ${PREFIX}/opt/bootlocal.sh > /dev/null
# Copy any script files that need to be part of the appliance
# TODO: maybe make this more maintanable?
sudo mkdir -p ${PREFIX}/opt/validator
sudo cp -f ${SCRIPTPATH}/check_certificate.sh ${PREFIX}/opt/validator/
sudo cp -f ${SCRIPTPATH}/check_connection.sh ${PREFIX}/opt/validator/

find | sudo cpio -o -H newc | gzip -2 > /tmp/prepare/tinycore.gz
sudo cp -f -p /tmp/prepare/tinycore.gz /tmp/prepare/disk/tce/boot/core.gz
sudo umount /tmp/prepare/disk
# Power off the machine for OVA capture
sudo poweroff
