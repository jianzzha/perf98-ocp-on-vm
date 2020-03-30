#!/usr/bin/bash
oc delete node perf150
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

