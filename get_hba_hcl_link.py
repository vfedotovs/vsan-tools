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

"""
Existing device keys in HCL file
❯ jq '.data | keys' formatted_all.txt
[
  "controller",
  "hdd",
  "nic",
  "ssd"
]
"""
    

cont_list_len = len(data['data']['controller'])
ssd_list_len = len(data['data']['ssd'])
hdd_list_len = len(data['data']['hdd'])
nic_list_len = len(data['data']['nic'])


print("HCL all.json file has count of following items: ")
print("HBA controllers: " + str(cont_list_len))
print("HDD disks: " + str(hdd_list_len))
print("SSD and NVME disks: " + str(ssd_list_len))
print("NIC cards: " + str(nic_list_len))
print("  ")

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


def get_device_link(hcl_data, dev_list_len: int, dev_pci_id: str, dev_type: str) -> str:
    for i in range(dev_list_len - 1):
        vid = data['data'][dev_type][i]['vid']
        did = data['data'][dev_type][i]['did']
        ssid = data['data'][dev_type][i]['ssid']
        svid = data['data'][dev_type][i]['svid']
        device_vcg_link = data['data'][dev_type][i]['vcglink']
        full_pci_id = vid + "/" + did + "/" + svid + "/" + ssid

        if full_pci_id == dev_pci_id:
            return "Found PCI ID: " + dev_pci_id + "\nVSAN HCL link: \n" + device_vcg_link
    return "No match found in all.json for provided ID:" + hba_pci_id





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

def get_device_choice():
    # Define the possible choices
    choices = {
        1: "controller",
        2: "hdd",
        3: "nic",
        4: "ssd"
    }
    
    # Loop to ask for user input until a valid choice is made
    while True:
        try:
            print("\nPlease choose a device:")
            print("1: controller")
            print("2: hdd")
            print("3: nic")
            print("4: ssd or nvme")
            
            # Get user input and convert it to an integer
            user_input = int(input("Enter the number corresponding to your choice: ").strip())
            
            # Check if the input is valid (between 1 and 4)
            if user_input in choices:
                print(f"\nYou have selected: {choices[user_input]}")
                return choices[user_input]
            else:
                print("\nInvalid input. Please enter a number between 1 and 4.")
        
        except ValueError:
            # Catch non-integer inputs and prompt the user again
            print("\nInvalid input. Please enter a valid number.")


# print(get_hba_link(data, cont_list_len, hba_id_to_check))
print("Example of real controller ID:  VID/DID/SVID/SSID")
print("Real HBA ID: 1000/0014/1137/020e ")
real_hba = "1000/0014/1137/020e"
hba_id_to_check = "1111/2222/3333/4444"
print(get_hba_link(data, cont_list_len, real_hba))


# Dynamic User input check
user_device_choice = get_device_choice()
print("DEBUG: User selected device type: " + user_device_choice)
user_pcid_device_input = get_valid_input()
print("DEBUG: User provided pcid: " + user_pcid_device_input)

print("User device type choice: " + str(user_device_choice))

# working original function
# print(get_hba_link(data, cont_list_len, user_pcid_device_input))

print("-- Get HCL link result ---")
if user_device_choice == "controller":
    print(get_device_link(data, cont_list_len, user_pcid_device_input, 'controller'))

if user_device_choice == "ssd":
    print(get_device_link(data, ssd_list_len,user_pcid_device_input, 'ssd'))
