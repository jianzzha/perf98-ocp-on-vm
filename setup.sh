#!/usr/bin/env bash

if false; then
echo "disable firewalld and selinux"
systemctl disable --now firewalld
setenforce 0

echo "after disable firewalld, restart libvirt"
systemctl restart libvirtd

echo "setup libvirt network ocp4-upi"
virsh net-define ocp4-upi-net.xml
virsh net-autostart ocp4-upi
virsh net-start ocp4-upi
fi
iptables -F
iptables -X
iptables -F -t nat
iptables -X -t nat
oif=$(ip route | awk '/^default/ {print $NF}')
iptables -t nat -A POSTROUTING -s 192.168.222.0/24 ! -d 192.168.222.0/24 -o $oif -j MASQUERADE

sed -i 's/^search.*/search test.myocp4.com/' /etc/resolv.conf
sed -i '/^search/a nameserver\ 192.168.222.1' /etc/resolv.conf

./cleanup.sh

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
/usr/bin/cp -f worker.ign /root/ocp-on-vm/

popd
/usr/bin/rm -f perf150.ign
ct -i worker.ign -f fix-ign -o perf150.ign
/usr/bin/cp -f perf150.ign /var/www/html/ocp4-upi

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


ipmitool -I lanplus -H perf150-drac.perf.lab.eng.bos.redhat.com -U root -P 100yard- chassis bootdev pxe
ipmitool -I lanplus -H perf150-drac.perf.lab.eng.bos.redhat.com -U root -P 100yard- chassis power cycle

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

while oc get nodes | egrep "perf150 *NotReady"; do
  sleep 5
done

> /root/.ssh/known_hosts

