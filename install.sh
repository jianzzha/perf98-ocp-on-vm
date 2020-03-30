yum -y install libvirt syslinux-tftpboot haproxy httpd virt-install jq
sed -i s/Listen\ 80/Listen\ 81/ /etc/httpd/conf/httpd.conf
mkdir /var/www/html/ocp4-upi
cat ocp4-upi-dnsmasq.conf >> /etc/dnsmasq.conf

