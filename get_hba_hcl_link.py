#!/usr/bin/python3
import json
import os
import re
import sys

def load_hcl_data(json_file='all.json'):
    """Load HCL data from JSON file with proper error handling."""
    if not os.path.exists(json_file):
        print(f"Error: File '{json_file}' does not exist.")
        print("Download file with command below:")
        print(" curl -o all.json https://partnerweb.vmware.com/service/vsan/all.json")
        sys.exit(1)
    
    try:
        with open(json_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        # Validate JSON structure
        if 'data' not in data:
            print("Error: Invalid JSON structure. 'data' key not found.")
            sys.exit(1)
        
        required_keys = ['controller', 'hdd', 'ssd', 'nic']
        for key in required_keys:
            if key not in data['data']:
                print(f"Error: Required key '{key}' not found in JSON data.")
                sys.exit(1)
        
        return data
    
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON format in '{json_file}': {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error reading file '{json_file}': {e}")
        sys.exit(1)

def print_hcl_statistics(data):
    """Print statistics about HCL data."""
    try:
        cont_list_len = len(data['data']['controller'])
        ssd_list_len = len(data['data']['ssd'])
        hdd_list_len = len(data['data']['hdd'])
        nic_list_len = len(data['data']['nic'])
        
        print("HCL all.json file has count of following items:")
        print(f"HBA controllers: {cont_list_len}")
        print(f"HDD disks: {hdd_list_len}")
        print(f"SSD and NVME disks: {ssd_list_len}")
        print(f"NIC cards: {nic_list_len}")
        print()
        
        return {
            'controller': cont_list_len,
            'ssd': ssd_list_len,
            'hdd': hdd_list_len,
            'nic': nic_list_len
        }
    except Exception as e:
        print(f"Error calculating statistics: {e}")
        sys.exit(1)

def get_device_link(data, dev_list_len: int, dev_pci_id: str, dev_type: str) -> str:
    """Get HCL link for a device by PCI ID."""
    try:
        # Fix: Remove -1 from range to include all devices
        for i in range(dev_list_len):
            device = data['data'][dev_type][i]
            
            # Use .get() for all fields to handle missing keys gracefully
            vid = device.get('vid')
            did = device.get('did')
            ssid = device.get('ssid')
            svid = device.get('svid')
            device_vcg_link = device.get('vcglink')
            
            # Skip devices with missing required fields
            if any(field is None for field in [vid, did, ssid, svid, device_vcg_link]):
                continue
            
            full_pci_id = f"{vid}/{did}/{svid}/{ssid}"
            
            if full_pci_id.lower() == dev_pci_id.lower():
                return f"Found PCI ID: {dev_pci_id}\nVSAN HCL link: {device_vcg_link}"
        
        return f"No match found in all.json for provided ID: {dev_pci_id}"
    
    except Exception as e:
        return f"Error searching for device: {e}"

def get_valid_input():
    """Get valid PCI ID input from user."""
    pattern = r'^[a-zA-Z0-9]{4}/[a-zA-Z0-9]{4}/[a-zA-Z0-9]{4}/[a-zA-Z0-9]{4}$'
    
    while True:
        try:
            user_input = input("Please enter the input in format XXXX/XXXX/XXXX/XXXX: ").strip()
            
            if re.match(pattern, user_input):
                print(f"Valid input received: {user_input}")
                return user_input
            else:
                print("Invalid input. Each section must contain exactly 4 alphanumeric characters. Please try again.")
        
        except KeyboardInterrupt:
            print("\nOperation cancelled by user.")
            sys.exit(0)
        except EOFError:
            print("\nEnd of input reached.")
            sys.exit(0)

def get_device_choice():
    """Get device type choice from user."""
    choices = {
        1: "controller",
        2: "hdd", 
        3: "nic",
        4: "ssd"
    }
    
    while True:
        try:
            print("\nPlease choose a device:")
            print("1: controller")
            print("2: hdd")
            print("3: nic")
            print("4: ssd or nvme")
            
            user_input = input("Enter the number corresponding to your choice: ").strip()
            
            if not user_input:
                print("Please enter a valid number.")
                continue
            
            user_choice = int(user_input)
            
            if user_choice in choices:
                print(f"\nYou have selected: {choices[user_choice]}")
                return choices[user_choice]
            else:
                print("Invalid input. Please enter a number between 1 and 4.")
        
        except ValueError:
            print("Invalid input. Please enter a valid number.")
        except KeyboardInterrupt:
            print("\nOperation cancelled by user.")
            sys.exit(0)
        except EOFError:
            print("\nEnd of input reached.")
            sys.exit(0)

def main():
    """Main function to orchestrate the HCL lookup process."""
    try:
        # Load HCL data
        data = load_hcl_data()
        
        # Print statistics
        stats = print_hcl_statistics(data)
        
        # Example lookup
        print("Example of real controller ID: VID/DID/SVID/SSID")
        print("Real HBA ID: 1000/0014/1137/020e")
        real_hba = "1000/0014/1137/020e"
        print(get_device_link(data, stats['controller'], real_hba, 'controller'))
        print()
        
        # Get user input
        user_device_choice = get_device_choice()
        user_pcid_device_input = get_valid_input()
        
        print(f"DEBUG: User selected device type: {user_device_choice}")
        print(f"DEBUG: User provided pcid: {user_pcid_device_input}")
        
        # Lookup device
        print("-- Get HCL link result ---")
        result = get_device_link(data, stats[user_device_choice], user_pcid_device_input, user_device_choice)
        print(result)
        
    except KeyboardInterrupt:
        print("\nOperation cancelled by user.")
        sys.exit(0)
    except Exception as e:
        print(f"Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
