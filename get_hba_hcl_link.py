#!/usr/bin/python3
import json
import os


# Check if the JSON file exists
json_file = 'all.json'
if not os.path.exists(json_file):
    print(f"File '{json_file}' does not exist.")
    print("Download file with command below.")
    print(" curl -o all.json https://partnerweb.vmware.com/service/vsan/all.json")
    exit(1)

# Load the JSON data from a file
with open(json_file) as f:
    data = json.load(f)


cont_list_len = len(data['data']['controller'])


''' Controller json structure
  "vid": "15b3",
  "did": "101f",
  "ssid": "0014",
  "svid": "15b3",
  "vcglink": "http://www.vmware.com/resources/compatibility/detail.php?deviceCategory=rdmanic&productid=52097",
'''


def get_hba_link(hcl_data, cont_list_len: int, hba_pci_id: str) -> str:
    for i in range(cont_list_len - 1):
        vid = data['data']['controller'][i]['vid']
        did = data['data']['controller'][i]['did']
        ssid = data['data']['controller'][i]['ssid']
        svid = data['data']['controller'][i]['svid']
        hba_vcg_link = data['data']['controller'][i]['vcglink']
        full_hba_pci_id = vid + "/" + did + "/" + svid + "/" + ssid

        if full_hba_pci_id == hba_pci_id:
            return "Found PCI ID: " + hba_pci_id + "\nVSAN HCL link: " + hba_vcg_link
    return "No match found in all.json for provided ID:" + hba_pci_id


hba_id_to_check = "1111/2222/3333/4444"
real_hba = "1000/0014/1137/020e"

print(get_hba_link(data, cont_list_len, hba_id_to_check))
print(get_hba_link(data, cont_list_len, real_hba))
