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
        if re.match("Disk", item["Name"]):
            disk_current_index = item["Index"]
    if disk_current_index == 0 and expected_pxedev_current_index == 1:
        # exit 0 means no update
        sys.exit(0)   
    for item in boot_array:
        if re.match("Disk", item["Name"]):
            item["Index"] = 0
            item["Enabled"] = true
        if item["Name"] == pxe_device:
            item["Index"] = 1
            item["Enabled"] = true
        if item["Index"] == 0 and not re.match("Disk", item["Name"]):
            item["Index"] = expected_pxedev_current_index
            item["Enabled"] = true

with open("boot_devices.txt", "w") as f:
    json.dump(boot_array, f)

# exit 2 means update the bios
sys.exit(2)
 
