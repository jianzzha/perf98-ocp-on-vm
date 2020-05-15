#!/usr/bin/env python
import json
import sys
import re

pxe_device = sys.argv[1]
with open("boot_devices.txt", "r") as f:
    boot_array = json.load(f)
    for item in boot_array:
        if item["Name"] == pxe_device:
            expected_pxedev_current_index = item["Index"]
        if re.match("HardDisk", item["Name"]):
            disk_current_index = item["Index"]
    if disk_current_index == 0 and expected_pxedev_current_index == 1:
        # exit 0 means no update
        sys.exit(0)   
    for item in boot_array:
        item["Enabled"] = True
        if re.match("HardDisk", item["Name"]):
            item["Index"] = 0
        if item["Name"] == pxe_device:
            item["Index"] = 1
        if item["Index"] == 0 and not re.match("HardDisk", item["Name"]):
            item["Index"] = expected_pxedev_current_index
        

with open("boot_devices.txt", "w") as f:
    json.dump(boot_array, f)

# exit 2 means update the bios
sys.exit(2)
 
