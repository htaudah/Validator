#!/bin/sh
# A shell script to prepare a Tiny Core virtual machine as a validation appliance for Workspace ONE
# Written by: Hani Audah <ht.aramco@gmail.com>
# Last updated on: May/10/2020
# -------------------------------------------------------------------------------------------------

if [ $# -eq 0 ]; then
    echo "Usage: $0 ip_address"
    exit 1
fi

# This part should be skipped if running from the appliance itself
if [ $1 -eq 'localhost' ]; then
    # Copy the built-in SSH key to appliance to skip future SSH password prompts
    scp ./id_rsa.pub tc@$1:/home/tc/.ssh/authorized_keys
    # Now copy all local files to appliance
    ssh -i ./id_rsa tc@$1 "mkdir /home/tc/prepare"
    scp -i ./id_rsa * tc@$1:/home/tc/prepare
    # Now just continue the script from the appliance itself and exit
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
        ( $KERNEL_FOUND ) && ( $ROOTFS_FOUND ) && VALIDCD="$CD"
        break
    fi
done
if [ -z "$VALIDCD" ]; then
    echo "Could not find a valid Tiny Core installation CD"
    abort
else
    CD=`trim $VALIDCD`
fi

# Install needed extensions now, before moving to disk in tc-install
tce-load -wi openssh
# VMWare Tools
tce-load -wi open-vm-tools
# Needed to avoid some obscure error (TODO: details?)
tce-load -wi pcre.tcz
tce-load -wi attr.tcz
tce-load -wi lighttpd.tcz
# keep them in a safe place without extensions needed only for creating the image
mkdir -p /tmp/tcz/optional
cp /tmp/tce/optional/* /tmp/tcz/optional/
cp /etc/sysconfig/tcedir/onboot.lst /tmp/tcz

# Install Tiny Core to disk. Parameters for tc-install.sh are as follows:
# (/mnt/"$CD"/boot/core.gz: install source, frugal: install type, sda: target, 0: skip boot menu, ext4: file system,
#  yes: make it bootable, no: not installing from Core Plus, X: N/A if not Core Plus, none: N/A if not Core Plus,
#  /tmp/extensionz: install extensions from this dir, tce=sda1
tce-load -wi tc-install
sudo tc-install.sh /mnt/"$CD"/boot/core.gz frugal sda 0 ext4 yes no X none /tmp/tcz tce=sda1 nodhcp waitusb=5

# Work directory for mounting and tailoring the image
mkdir -p /tmp/prepare/disk
mkdir -p /tmp/prepare/extract
sudo mount /dev/sda1 /tmp/prepare/disk
cp /tmp/prepare/disk/tce/boot/core.gz /tmp/prepare/
cd /tmp/prepare/extract
zcat /tmp/prepare/core.gz | sudo cpio -i -H newc -d
find | sudo cpio -o -H newc | gzip -2 > ../tinycore.gz
sudo cp -f ../tinycore.gz /tmp/prepare/disk/tce/boot/core.gz
sudo umount /tmp/prepare/disk

# Install and enable SSH
#tce-load -wi openssh
sudo cp /usr/local/etc/ssh/sshd_config.orig /usr/local/etc/ssh/sshd_config
# Allow root login
sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /usr/local/etc/ssh/sshd_config
sudo /usr/local/etc/init.d/openssh start
echo '/usr/local/etc/init.d/openssh start' | sudo tee -a /opt/bootlocal.sh > /dev/null
echo "root:vmbox" | sudo chpasswd
# VMWare Tools
tce-load -wi open-vm-tools
tce-load -wi pcre.tcz
sudo /usr/local/etc/init.d/open-vm-tools start
echo '/usr/local/etc/init.d/open-vm-tools start' | sudo tee -a /opt/bootlocal.sh > /dev/null
# Install the lighttpd webserver
tce-load -wi attr.tcz
tce-load -wi lighttpd.tcz
# Create directories for self-signed certs and keys
sudo mkdir -p /etc/ssl/certs
sudo mkdir -p /etc/ssl/keys
# Generate the Root CA keys
sudo mv /usr/local/etc/ssl/openssl.cnf.dist /usr/local/etc/ssl/openssl.cnf
sudo openssl genrsa -out /etc/ssl/keys/rootselfsigned.key 2048
sudo openssl req -x509 -new -nodes -key /etc/ssl/keys/rootselfsigned.key -sha256 -days 1825 \
    -out /etc/ssl/certs/rootselfsigned.pem -subj "/C=SA/ST=Riyadh/L=Riyadh/O=VMWare/OU=Workspace One/CN=www.vmware.com"
# Generate the web certificate. Since we're using a wildcard, we can ignore the expected URL
sudo openssl req -new -sha256 -nodes -out /etc/ssl/certs/webselfsigned.csr -newkey rsa:2048 \
    -keyout /etc/ssl/keys/webselfsigned.key -subj "/C=SA/ST=Riyadh/L=Riyadh/O=VMWare/OU=Workspace ONE/CN=*"
sudo openssl x509 -req -in /etc/ssl/certs/webselfsigned.csr -CA /etc/ssl/certs/rootselfsigned.pem \
    -CAkey /etc/ssl/keys/rootselfsigned.key -CAcreateserial -out /etc/ssl/certs/webselfsigned.crt -days 1825 -sha256
# Prepare a dummy site for responses
sudo mkdir -p /var/www/test
sudo mkdir -p /var/www/uploads
sudo chown tc:staff /var/www/test
echo "<html>" >> /var/www/test/index.html
echo "  <body>" >> /var/www/test/index.html
echo "    Hello friend" >> /var/www/test/index.html
echo "  </body>" >> /var/www/test/index.html
echo "</html>" >> /var/www/test/index.html
# A lighttpd conf suitable for testing
sudo touch /var/www/lighttpd.conf
sudo chown tc:staff /var/www/lighttpd.conf
sudo cat << EOF > /var/www/lighttpd.conf
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
