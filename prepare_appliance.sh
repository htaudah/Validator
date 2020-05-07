#!/bin/sh
# Install TinyCore to disk
#TODO: provide answers to all installation questions
#TODO: determine path of running script and skip installation to disk if already installed
tce-load -wi tc-install
sudo tc-install.sh
# VMWare Tools
tce-load -wi open-vm-tools
tce-load -wi pcre.tcz
sudo /usr/local/etc/init.d/open-vm-tools start
tce-load -wi openssh
sudo cp /usr/local/etc/ssh/sshd_config.orig /usr/local/etc/ssh/sshd_config
# Allow root login
sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /usr/local/etc/ssh/sshd_config
sudo /usr/local/etc/init.d/openssh start
sudo echo "root:vmbox" | sudo chpasswd
# Install the lighttpd webserver
sudo tce-load -wi attr.tcz
sudo tce-load -wi lighttpd.tcz
# Create directories for self-signed certs and keys
sudo mkdir -p /etc/ssl/certs
sudo mkdir -p /etc/ssl/keys
# Generate the Root CA keys
sudo mv /usr/local/etc/ssl/openssl.cnf.dist /usr/local/etc/ssl/openssl.cnf
sudo openssl genrsa -out /etc/ssl/keys/rootselfsigned.key 2048
sudo openssl req -x509 -new -nodes -key /etc/ssl/keys/rootselfsigned.key -sha256 -days 1825 \
    -out /etc/ssl/certs/rootselfsigned.pem -subj "/C=SA/ST=Riyadh/L=Riyadh/O=VMWare/OU=Workspace One/CN="
# Prepare a dummy site for responses
sudo mkdir -p /var/www/test
sudo echo "<html>" >> /var/www/test/index.html
sudo echo "  <body>" >> /var/www/test/index.html
sudo echo "    Hello friend" >> /var/www/test/index.html
sudo echo "  </body>" >> /var/www/test/index.html
sudo echo "</html>" >> /var/www/test/index.html
# A lighttpd conf suitable for testing
sudo cat << EOF > /var/www/lighttpd.conf
mimetype.assign = (".html" => "text/html")
server.document-root = "/var/www/test"
server.username = "tc"
server.groupname = "staff"
#server.chroot = "/var/www"
server.upload-dirs=("/var/www/uploads")
index-file.names=("index.html")
#ssl enabled for all, then disabled as-needed per port
ssl.engine = "enable"
ssl.pemfile = "/etc/ssl/certs/webselfsigned.crt"
ssl.privkey = "/etc/ssl/keys/webselfsigned.key"
ssl.ca-file = "/etc/ssl/certs/rootselfsigned.pem"
$SERVER["socket"] == ":<#SSL_PORT#>" {
}
EOF
# This is no longer done during appliance setup; the validator will initiate httpd based on
# the port numbers specified in the prereq sheet
#sudo /usr/local/httpd/sbin/httpd -p 80 -h /var/www/test/