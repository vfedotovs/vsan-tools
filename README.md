# vsan-tools

CLI utility should help HCL URL extraction based on device PCID from all.json file 

```sh
❯ ./get_hba_hcl_link.py
HCL all.json file has count of following items:
HBA controllers: 277
HDD disks: 1939
SSD and NVME disks: 6421
NIC cards: 311

Example of real controller ID:  VID/DID/SVID/SSID
Real HBA ID: 1000/0014/1137/020e
Found PCI ID: 1000/0014/1137/020e
VSAN HCL link: http://www.vmware.com/resources/compatibility/detail.php?deviceCategory=vsanio&productid=44545

Please choose a device:
1: controller
2: hdd
3: nic
4: ssd or nvme
Enter the number corresponding to your choice: 4

You have selected: ssd

Please enter the input in format XXXX/XXXX/XXXX/XXXX: 1e0f/001F/1028/222B
Valid input received: 1e0f/001F/1028/222B


-- Get HCL link result ---
Found PCI ID: 1e0f/001F/1028/222B
VSAN HCL link:
http://www.vmware.com/resources/compatibility/detail.php?deviceCategory=ssd&productid=56780
```

## Feature rodamp
- [x] Controller(HBA) HCL URL extraction based on PCID (MVP)
- [x] Dynamic all 4 device type URL extraction (HBA, ssd or nvme, hdd, nic) using PCID
- [ ] Known issue some ssd devices doe not have PCID keys for device entry implemnet device lookup by model or part number
- [ ] Implement PCID load from ESXI vm-support log bundle configuration files
