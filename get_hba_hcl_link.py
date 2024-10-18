#!/usr/bin/python3
import json
import os
import re

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



def get_valid_input():
    # Define the regular expression pattern for 4 alphanumeric characters in each section
    pattern = r'^[a-zA-Z0-9]{4}/[a-zA-Z0-9]{4}/[a-zA-Z0-9]{4}/[a-zA-Z0-9]{4}$'
    
    while True:
        user_input = input("Please enter the input in format XXXX/XXXX/XXXX/XXXX: ").strip()
        
        # Check if the input matches the required pattern
        if re.match(pattern, user_input):
            print("Valid input received:", user_input)
            return user_input
        else:
            print("Invalid input. Each section must contain exactly 4 alphanumeric characters. Please try again.")

# Call the function to prompt the user for input


print(get_hba_link(data, cont_list_len, hba_id_to_check))
print("Example of real controller ID:  VID/DID/SVID/SSID")
print(get_hba_link(data, cont_list_len, real_hba))
device_to_check = get_valid_input()
print(get_hba_link(data, cont_list_len, device_to_check))




