#!/usr/bin/env bash
VERSION=${VERSION:-"4.3.0-0.nightly-2020-02-06-155513"}
installerURL=${installerURL:-"https://raw.githubusercontent.com/openshift/installer/release-4.3/data/data/rhcos.json"}
INSTALL_BAREMETAL=${INSTALL_BAREMETAL:-false}
USE_ALIAS=${USE_ALIAS:-false}
IPMI_IP=mgmt-e26-h29-740xd.alias.bos.scalelab.redhat.com
IPMI_USER=quads
IPMI_PASSWD=504322
IPMI_PXE_DEVICE=NIC.Integrated.1-1-1
# BM_IF is the linux name for IPMI_PXE_DEVICE
BM_IF=${BM_IF:-eno1}
# DISABLE_IFS contains the list of devices to be disabled to prevent dhcp
DISABLE_IFS=(eno3)

export MAC_BAREMETAL=52:54:00:f9:8e:00

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

echo "delete existing VMs"
./cleanup.sh

if [[ "${FROM_TOP:-false}" == "true" ]]; then
    if [[ "${USE_ALIAS}" == "true" ]]; then
        ~/clean-interfaces.sh --nuke
    fi

    set -ex
    yum -y groupinstall 'Virtualization Host'
    yum -y install unzip ipmitool wget virt-install jq python3 httpd syslinux-tftpboot haproxy httpd virt-install vim-enhanced git tmux
    set +ex

    if ! cat /etc/os-release | egrep 'VERSION="8'; then
        echo "copy extra syslinux files for tftpboot" 
        yum -y unzip
        /bin/rm -rf ~/syslinux
        mkdir ~/syslinux
        pushd ~/syslinux
        wget -O syslinux.zip https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.zip
        unzip syslinux.zip 
        /bin/cp -f ./bios/core/lpxelinux.0 /var/lib/tftpboot/
        /bin/cp -f ./bios/com32/elflink/ldlinux/ldlinux.c32 /var/lib/tftpboot/
        popd
    fi

    echo "set up pxe files"
    PXEDIR="/var/lib/tftpboot/pxelinux.cfg"
    [ -e /var/lib/tftpboot/pxelinux.cfg ] || mkdir -p $PXEDIR
    cp pxelinux-cfg-default ${PXEDIR}/worker
    ln -s ${PXEDIR}/worker ${PXEDIR}/default
    cp -s ${PXEDIR}/worker ${PXEDIR}/baremetal
    sed -i s/worker.ign/baremetal.ign/ ${PXEDIR}/baremetal
    cp ${PXEDIR}/default ${PXEDIR}/bootstrap
    sed -i s/worker.ign/bootstrap.ign/ ${PXEDIR}/bootstrap
    ln -s ${PXEDIR}/bootstrap ${PXEDIR}/01-52-54-00-f9-8e-41
    cp ${PXEDIR}/default ${PXEDIR}/master
    sed -i s/worker.ign/master.ign/ ${PXEDIR}/master
    for name in master0 master1 master2; do
        mac=$(cat ocp4-upi-dnsmasq.conf | sed -n -r "s/dhcp-host=([^,]+).*$name/\1/p")
        m=$(echo $mac | sed s/\:/-/g | tr '[:upper:]' '[:lower:]')
        ln -s ${PXEDIR}/master ${PXEDIR}/01-${m}
    done 

    echo "download filetranspile"
    [ -d ~/bin ] || mkdir ~/bin
    wget -O ~/bin/filetranspile https://raw.githubusercontent.com/ashcrow/filetranspiler/18/filetranspile
    chmod u+x ~/bin/filetranspile
    echo "pip install modules for filetranspile"
    pip3 install PyYAML
 
    echo "install docker"
    if ! yum install -y podman; then
        yum install -y yum-utils device-mapper-persistent-data lvm2
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y containerd.io-1.2.13 docker-ce-19.03.8 docker-ce-cli-19.03.8
        mkdir /etc/docker
        cat > /etc/docker/daemon.json <<EOF
{
  "iptables": false,
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ]
}
EOF
        mkdir -p /etc/systemd/system/docker.service.d
        systemctl daemon-reload
        systemctl enable --now docker
    fi
    systemctl enable NetworkManager --now
    nmcli con add type bridge ifname baremetal con-name baremetal ipv4.method manual ipv4.addr 192.168.222.1/24 ipv4.dns 192.168.222.1 ipv4.dns-priority 10 autoconnect yes bridge.stp no
    nmcli con reload baremetal
    nmcli con up baremetal

    if [[ "${INSTALL_BAREMETAL}" == "true" ]]; then
        git clone https://github.com/dell/iDRAC-Redfish-Scripting.git ~/Redfish
        pushd ~/Redfish/"Redfish Python"/
        MAC_BAREMETAL=`python GetEthernetInterfacesREDFISH.py -u ${IPMI_USER} -p {IPMI_PASSWD} -ip ${IPMI_IP} -d {IPMI_PXE_DEVICE} | awk '/^MACAddress:/{print $2}'`
        m=$(echo ${MAC_BAREMETAL} | sed s/\:/-/g | tr '[:upper:]' '[:lower:]')
        ln -s ${PXEDIR}/baremetal ${PXEDIR}/01-${m}
        popd
        nmcli con down $BM_IF
        nmcli con del $BM_IF
        nmcli con add type bridge-slave autoconnect yes con-name $BM_IF ifname $BM_IF master baremetal
        nmcli con reload $BM_IF
        nmcli con up $BM_IF
    fi
    
    echo "disable firewalld and selinux"
    systemctl disable --now firewalld
    setenforce 0
    sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
    
    echo "after disable firewalld, restart libvirt"
    systemctl restart libvirtd
    
    echo "disable libvirt default network"
    if virsh net-list | grep default; then
        virsh net-destroy default
        virsh net-undefine default
    fi
    
    echo "setup libvirt network ocp4-upi"
    if ! virsh net-list | grep ocp4-upi; then
        virsh net-define ocp4-upi-net.xml
        virsh net-autostart ocp4-upi
        virsh net-start ocp4-upi
    fi
    
    echo "set up iptables"
    iptables -F
    iptables -X
    iptables -F -t nat
    iptables -X -t nat
    oif=$(ip route | sed -n -r '0,/default/s/.* dev (\w+).*/\1/p')
    iptables -t nat -A POSTROUTING -s 192.168.222.0/24 ! -d 192.168.222.0/24 -o $oif -j MASQUERADE
    
    echo "set up /etc/resolv.conf"
    sed -i 's/^search.*/search test.myocp4.com/' /etc/resolv.conf
    if ! grep 192.168.222.1 /etc/resolv.conf; then
        sed -i '/^search/a nameserver\ 192.168.222.1' /etc/resolv.conf
    fi

    if [[ -f ${SCRIPTPATH}/ocp4-upi-dnsmasq.conf ]]; then
        OIF=${oif} envsubst < ${SCRIPTPATH}/ocp4-upi-dnsmasq.conf > /etc/dnsmasq.conf
    fi
    
    cat ~/ocp4-upi-haproxy.cfg > /etc/haproxy/haproxy.cfg
    sed -i s/Listen\ 80/Listen\ 81/ /etc/httpd/conf/httpd.conf
    mkdir /var/www/html/ocp4-upi

    if ! [[ -f ~/.ssh/id_rsa ]]; then
        ssh-keygen -f ~/.ssh/id_rsa -q -N ""
    fi
    pub_key_content=`cat ~/.ssh/id_rsa.pub`
    sed -i -r -e "s|sshKey:.*|sshKey: ${pub_key_content}|" ${SCRIPTPATH}/install-config.yaml

    systemctl enable --now haproxy httpd dnsmasq

fi

if [[ "${DOWNLOAD_IMAGE:-false}" == "true" ]]; then
    set -ex
    echo "download images"

    /bin/rm -rf ~/openshift-client-linux*
    /bin/rm -rf /var/www/html/ocp4-upi/rhcos*

    wget -N -P ~ https://mirror.openshift.com/pub/openshift-v4/clients/ocp-dev-preview/${VERSION}/{openshift-client-linux-${VERSION}.tar.gz,openshift-install-linux-${VERSION}.tar.gz}
    [ -d ~/bin ] || mkdir ~/bin
    /bin/rm -rf ~/bin/{kubectl,oc,openshift*}
    tar -C ~/bin -xzf ~/openshift-client-linux-${VERSION}.tar.gz 
    tar -C ~/bin -xzf ~/openshift-install-linux-${VERSION}.tar.gz

    baseURI=`curl -s $installerURL | jq -r '(.baseURI)'`
    bios=`curl -s $installerURL | jq -r '(.images.metal.path)'`
    kernel=`curl -s $installerURL | jq -r '(.images.kernel.path)'`
    initramfs=`curl -s $installerURL | jq -r '(.images.initramfs.path)'`
    wget -N -P /var/www/html/ocp4-upi $baseURI/{$bios,$kernel,$initramfs}
    ln -s /var/www/html/ocp4-upi/${bios} /var/www/html/ocp4-upi/rhcos-metal-bios.raw.gz
    ln -s /var/www/html/ocp4-upi/${initramfs} /var/www/html/ocp4-upi/rhcos-installer-initramfs.img
    ln -s /var/www/html/ocp4-upi/${kernel} /var/www/html/ocp4-upi/rhcos-installer-kernel
    chmod a+rx /var/www/html/ocp4-upi
    set +ex
fi

set -ex
echo "remove exisiting install directory"
rm -rf  ~/ocp4-upi-install-1

echo "recreate install directory"
mkdir ~/ocp4-upi-install-1
cp install-config.yaml ~/ocp4-upi-install-1
pushd ~/ocp4-upi-install-1
openshift-install create manifests
sed -i s/mastersSchedulable.*/mastersSchedulable:\ False/ manifests/cluster-scheduler-02-config.yml

echo "create ignition files"
openshift-install create ignition-configs
/usr/bin/cp -f *.ign /var/www/html/ocp4-upi
popd
set +ex

if [[ "${INSTALL_BAREMETAL}" == "true" ]]; then
    echo "set up baremetal server ignition"
    mkdir -p fix-ign/etc/sysconfig/network-scripts/
    for IFNAME in "${DISABLE_IFS[@]}"; do
        cat << EOF > fix-ign/etc/sysconfig/network-scripts/ifcfg-${IFNAME}
DEVICE=${IFNAME}
BOOTPROTO=none
ONBOOT=no
EOF
    done
    /usr/bin/cp -f ~/ocp4-upi-install-1/worker.ign ./ 
    /usr/bin/rm -f baremetal.ign
    if command -v filetranspile >/dev/null 2>&1 && [[ -d fix-ign ]]; then
        filetranspile -i worker.ign -f fix-ign -o baremetal.ign
        /usr/bin/cp -f baremetal.ign /var/www/html/ocp4-upi
        setup_baremetal="true"
    else
        echo "filetranspile not installed or fix-ign directory not exist!"
        echo "no baremetal ignition file generated!"
        setup_baremetal="false" 
    fi
else
    setup_baremetal="false"
fi

echo "start bootstrap VM ..."
virt-install -n ocp4-upi-bootstrap --pxe --os-type=Linux --os-variant=rhel8.0 --ram=8192 --vcpus=4 --network network=ocp4-upi,mac=52:54:00:f9:8e:41 --disk size=120,bus=scsi,sparse=yes --check disk_size=off --noautoconsole
while true; do
    sleep 3
    if virsh list --all | grep 'shut off'; then
       vm=$(virsh list --all | awk '/shut off/{print $2}')
       virsh start ${vm}
       break
    fi
done       

echo "start master VMs ..."
for i in {0..2}; do
    virt-install -n ocp4-upi-master${i} --pxe --os-type=Linux --os-variant=rhel8.0 --ram=12288 --vcpus=4 --network network=ocp4-upi,mac=52:54:00:f9:8e:2${i} --disk size=120,bus=scsi,sparse=yes --check disk_size=off --noautoconsole;
    while true; do
        sleep 3
        if virsh list --all | grep 'shut off'; then
            vm=$(virsh list --all | awk '/shut off/{print $2}')
            virsh start ${vm}
            break
        fi
    done
done

for i in {0..100}; do
    echo "waiting for all 3 masters ready ..."
    sleep 10
    count=$(oc get nodes | egrep '^master.* +Ready' | wc -l)
    if [ $count -eq 3 ]; then
        echo "all 3 masters in ready state"
        break
    fi
    if [ $i -eq 100 ]; then
        echo "not all master nodes in ready state"
        exit 1
    fi
done

echo "start worker VM ..."
virt-install -n ocp4-upi-worker0 --pxe --os-type=Linux --os-variant=rhel8.0 --ram=8192 --vcpus=4 --network network=ocp4-upi,mac=52:54:00:f9:8e:30 --disk size=120,bus=scsi,sparse=yes --check disk_size=off --noautoconsole
while true; do
    sleep 3
    if virsh list --all | grep 'shut off'; then
       vm=$(virsh list --all | awk '/shut off/{print $2}')
       virsh start ${vm}
       break
    fi
done       
count=2
while ((count > 0)); do
  echo "waiting for Pending csr"
  if oc get csr | grep Pending; then
    csr=$(oc get csr | grep Pending | awk '{print$1}')
    oc adm certificate approve $csr
    ((count--))
  fi
  sleep 5
done

if [[ ${setup_baremetal} == "false" ]]; then
    exit 0
fi

echo "update bios pxe device order"
pushd ~/Redfish/"Redfish Python"/
python GetBiosBootOrderBootSourceStateREDFISH.py -u ${IPMI_USER} -p ${IPMI_PASSWD} -ip ${IPMI_IP} 
/bin/cp -f ${SCRIPTPATH}/redfish_update_pxe.py ./
python redfish_update_pxe.p $IPMI_PXE_DEVICE
python ChangeBootOrderBootSourceStateREDFISH.py -u ${IPMI_USER} -p ${IPMI_PASSWD} -ip ${IPMI_IP}
popd

ipmitool -I lanplus -H ${IPMI_IP} -U ${IPMI_USER} -P ${IPMI_PASSWD} chassis bootdev pxe
ipmitool -I lanplus -H ${IPMI_IP} -U ${IPMI_USER} -P ${IPMI_PASSWD} chassis power cycle

count=2
while ((count > 0)); do
  echo "waiting for Pending csr"
  if oc get csr | grep Pending; then
    csr=$(oc get csr | grep Pending | awk '{print$1}')
    oc adm certificate approve $csr
    ((count--))
  fi
  sleep 5
done

> /root/.ssh/known_hosts

