#!/usr/bin/env bash

echo "Copying config files ...."
cp ../commands/localcli_vsan-debug-controller-list.txt .
cp ../commands/esxcfg-info_-a.txt .

echo "Extracting HBA PCI IDs ...."
cat localcli_vsan-debug-controller-list.txt |
  grep -E "vmhba|VSAN|PCI" |
  xargs -n 10 |
  grep true >only_vsan_vmhba.txt

cat localcli_vsan-debug-controller-list.txt |
  grep -E "vmhba|VSAN|PCI" |
  xargs -n 10 |
  grep false >none_vsan_vmhba.txt

echo "Extracting NIC PCI IDs ...."
grep -B 7 "thernet controller" esxcfg-info_-a.txt | sed -e 's/\.//g' | sed 's/-//g' | grep -vE "Class|Vendor Name" | sed 's/^[[:space:]]*|//' | tr '\n' ' ' | sed 's/ Vendor Id/\nVendor Id/g' | sort | uniq >nic_bci_ids.txt

# grep -B 7 "thernet controller" esxcfg-info_-a.txt |
#   sed -e 's/\.//g' | \                # Remove all periods
# sed 's/-//g' | \                      # Remove all dashes
# grep -vE "Class|Vendor Name" | \      # Exclude lines containing "Class" or "Vendor Name"
# sed 's/^[[:space:]]*|//' | \          # Remove leading spaces and the "|" character
# tr '\n' ' ' | \                       # Replace newlines with spaces
# sed 's/ Vendor Id/\nVendor Id/g' | \  # Insert newline before each "Vendor Id" for separation
# sort | \                              # Sort the results
# uniq >nic_bci_ids.txt                 # Remove duplicate lines

echo "You can use find ids in files only_vsan_vmhba.txt and nic_bci_ids.txt"
