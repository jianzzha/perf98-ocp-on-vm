#!/usr/bin/env python
import json
import sys
import re

pxe_device = sys.argv[1]
with open("boot_devices.txt", "r") as f:
    boot_array = json.load(f)
    dev_index = len(boot_array) - 1 
    for item in boot_array:
        if item["Name"] != pxe_device and re.match("NIC", item["Name"]) and item["Index"] < dev_index:
            item["Enabled"] = False 
        elif item["Name"] == pxe_device:
            dev_index = item["Index"]

with open("boot_devices.txt", "w") as f:
    json.dump(boot_array, f)
 
