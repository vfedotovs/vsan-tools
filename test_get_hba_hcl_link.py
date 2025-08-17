#!/usr/bin/python3
import unittest
import json
import tempfile
import os
import sys
from unittest.mock import patch, mock_open, MagicMock
from io import StringIO

# Import the functions to test
from get_hba_hcl_link import (
    load_hcl_data,
    print_hcl_statistics,
    get_device_link,
    get_valid_input,
    get_device_choice
)

class TestHCLDataLoading(unittest.TestCase):
    """Test cases for HCL data loading functionality."""
    
    def setUp(self):
        """Set up test fixtures."""
        self.sample_hcl_data = {
            "data": {
                "controller": [
                    {
                        "vid": "1000",
                        "did": "0014", 
                        "ssid": "020e",
                        "svid": "1137",
                        "vcglink": "http://example.com/controller1"
                    },
                    {
                        "vid": "15b3",
                        "did": "101f",
                        "ssid": "0014", 
                        "svid": "15b3",
                        "vcglink": "http://example.com/controller2"
                    }
                ],
                "ssd": [
                    {
                        "vid": "8086",
                        "did": "a1d2",
                        "ssid": "0101",
                        "svid": "1137", 
                        "vcglink": "http://example.com/ssd1"
                    }
                ],
                "hdd": [
                    {
                        "vid": "15ad",
                        "did": "07c0",
                        "ssid": "07c0",
                        "svid": "15ad",
                        "vcglink": "http://example.com/hdd1"
                    }
                ],
                "nic": [
                    {
                        "vid": "8086",
                        "did": "7111",
                        "ssid": "1976",
                        "svid": "15ad",
                        "vcglink": "http://example.com/nic1"
                    }
                ]
            }
        }
    
    def test_load_hcl_data_success(self):
        """Test successful loading of HCL data."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(self.sample_hcl_data, f)
            temp_file = f.name
        
        try:
            data = load_hcl_data(temp_file)
            self.assertEqual(data, self.sample_hcl_data)
        finally:
            os.unlink(temp_file)
    
    def test_load_hcl_data_file_not_found(self):
        """Test handling of missing file."""
        with self.assertRaises(SystemExit):
            load_hcl_data('nonexistent_file.json')
    
    def test_load_hcl_data_invalid_json(self):
        """Test handling of invalid JSON."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            f.write("invalid json content")
            temp_file = f.name
        
        try:
            with self.assertRaises(SystemExit):
                load_hcl_data(temp_file)
        finally:
            os.unlink(temp_file)
    
    def test_load_hcl_data_missing_data_key(self):
        """Test handling of JSON missing 'data' key."""
        invalid_data = {"wrong_key": {}}
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(invalid_data, f)
            temp_file = f.name
        
        try:
            with self.assertRaises(SystemExit):
                load_hcl_data(temp_file)
        finally:
            os.unlink(temp_file)
    
    def test_load_hcl_data_missing_device_type(self):
        """Test handling of JSON missing required device type."""
        invalid_data = {
            "data": {
                "controller": [],
                "ssd": []
                # Missing hdd and nic
            }
        }
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(invalid_data, f)
            temp_file = f.name
        
        try:
            with self.assertRaises(SystemExit):
                load_hcl_data(temp_file)
        finally:
            os.unlink(temp_file)

class TestHCLStatistics(unittest.TestCase):
    """Test cases for HCL statistics functionality."""
    
    def test_print_hcl_statistics(self):
        """Test statistics calculation and printing."""
        data = {
            "data": {
                "controller": [{"vid": "1000"}],
                "ssd": [{"vid": "8086"}, {"vid": "15ad"}],
                "hdd": [{"vid": "15ad"}],
                "nic": [{"vid": "8086"}, {"vid": "15ad"}, {"vid": "1000"}]
            }
        }
        
        with patch('sys.stdout', new=StringIO()) as fake_output:
            stats = print_hcl_statistics(data)
        
        expected_stats = {
            'controller': 1,
            'ssd': 2,
            'hdd': 1,
            'nic': 3
        }
        
        self.assertEqual(stats, expected_stats)
        output = fake_output.getvalue()
        self.assertIn("HBA controllers: 1", output)
        self.assertIn("SSD and NVME disks: 2", output)
        self.assertIn("HDD disks: 1", output)
        self.assertIn("NIC cards: 3", output)

class TestDeviceLinkLookup(unittest.TestCase):
    """Test cases for device link lookup functionality."""
    
    def setUp(self):
        """Set up test fixtures."""
        self.test_data = {
            "data": {
                "controller": [
                    {
                        "vid": "1000",
                        "did": "0014",
                        "ssid": "020e", 
                        "svid": "1137",
                        "vcglink": "http://example.com/controller1"
                    },
                    {
                        "vid": "15b3",
                        "did": "101f",
                        "ssid": "0014",
                        "svid": "15b3", 
                        "vcglink": "http://example.com/controller2"
                    }
                ],
                "ssd": [
                    {
                        "vid": "8086",
                        "did": "a1d2",
                        "ssid": "0101",
                        "svid": "1137",
                        "vcglink": "http://example.com/ssd1"
                    }
                ]
            }
        }
    
    def test_get_device_link_found(self):
        """Test successful device lookup."""
        result = get_device_link(self.test_data, 2, "1000/0014/1137/020e", "controller")
        expected = "Found PCI ID: 1000/0014/1137/020e\nVSAN HCL link: http://example.com/controller1"
        self.assertEqual(result, expected)
    
    def test_get_device_link_not_found(self):
        """Test device lookup when not found."""
        result = get_device_link(self.test_data, 2, "9999/9999/9999/9999", "controller")
        expected = "No match found in all.json for provided ID: 9999/9999/9999/9999"
        self.assertEqual(result, expected)
    
    def test_get_device_link_case_insensitive(self):
        """Test case-insensitive matching."""
        result = get_device_link(self.test_data, 2, "1000/0014/1137/020E", "controller")
        expected = "Found PCI ID: 1000/0014/1137/020E\nVSAN HCL link: http://example.com/controller1"
        self.assertEqual(result, expected)
    
    def test_get_device_link_missing_fields(self):
        """Test handling of devices with missing fields."""
        data_with_missing_fields = {
            "data": {
                "controller": [
                    {
                        "vid": "1000",
                        "did": "0014",
                        # Missing ssid, svid, vcglink
                    },
                    {
                        "vid": "15b3",
                        "did": "101f", 
                        "ssid": "0014",
                        "svid": "15b3",
                        "vcglink": "http://example.com/controller2"
                    }
                ]
            }
        }
        
        # Should skip the first device and find the second
        result = get_device_link(data_with_missing_fields, 2, "15b3/101f/15b3/0014", "controller")
        expected = "Found PCI ID: 15b3/101f/15b3/0014\nVSAN HCL link: http://example.com/controller2"
        self.assertEqual(result, expected)
    
    def test_get_device_link_ssd_type(self):
        """Test lookup for SSD devices."""
        result = get_device_link(self.test_data, 1, "8086/a1d2/1137/0101", "ssd")
        expected = "Found PCI ID: 8086/a1d2/1137/0101\nVSAN HCL link: http://example.com/ssd1"
        self.assertEqual(result, expected)

class TestInputValidation(unittest.TestCase):
    """Test cases for input validation functionality."""
    
    @patch('builtins.input', return_value='1000/0014/1137/020e')
    def test_get_valid_input_valid(self, mock_input):
        """Test valid input acceptance."""
        with patch('sys.stdout', new=StringIO()) as fake_output:
            result = get_valid_input()
        
        self.assertEqual(result, '1000/0014/1137/020e')
        output = fake_output.getvalue()
        self.assertIn("Valid input received: 1000/0014/1137/020e", output)
    
    @patch('builtins.input', side_effect=['invalid', '1000/0014/1137/020e'])
    def test_get_valid_input_invalid_then_valid(self, mock_input):
        """Test handling of invalid input followed by valid input."""
        with patch('sys.stdout', new=StringIO()) as fake_output:
            result = get_valid_input()
        
        self.assertEqual(result, '1000/0014/1137/020e')
        output = fake_output.getvalue()
        self.assertIn("Invalid input", output)
        self.assertIn("Valid input received: 1000/0014/1137/020e", output)
    
    @patch('builtins.input', side_effect=['1000/0014/1137', '1000/0014/1137/020e'])
    def test_get_valid_input_wrong_format(self, mock_input):
        """Test handling of wrong format input."""
        with patch('sys.stdout', new=StringIO()) as fake_output:
            result = get_valid_input()
        
        self.assertEqual(result, '1000/0014/1137/020e')
        output = fake_output.getvalue()
        self.assertIn("Invalid input", output)
    
    @patch('builtins.input', side_effect=KeyboardInterrupt())
    def test_get_valid_input_keyboard_interrupt(self, mock_input):
        """Test handling of keyboard interrupt."""
        with self.assertRaises(SystemExit):
            get_valid_input()

class TestDeviceChoice(unittest.TestCase):
    """Test cases for device choice functionality."""
    
    @patch('builtins.input', return_value='1')
    def test_get_device_choice_valid_controller(self, mock_input):
        """Test valid controller choice."""
        with patch('sys.stdout', new=StringIO()) as fake_output:
            result = get_device_choice()
        
        self.assertEqual(result, 'controller')
        output = fake_output.getvalue()
        self.assertIn("You have selected: controller", output)
    
    @patch('builtins.input', return_value='4')
    def test_get_device_choice_valid_ssd(self, mock_input):
        """Test valid SSD choice."""
        with patch('sys.stdout', new=StringIO()) as fake_output:
            result = get_device_choice()
        
        self.assertEqual(result, 'ssd')
        output = fake_output.getvalue()
        self.assertIn("You have selected: ssd", output)
    
    @patch('builtins.input', side_effect=['5', '1'])
    def test_get_device_choice_invalid_then_valid(self, mock_input):
        """Test invalid choice followed by valid choice."""
        with patch('sys.stdout', new=StringIO()) as fake_output:
            result = get_device_choice()
        
        self.assertEqual(result, 'controller')
        output = fake_output.getvalue()
        self.assertIn("Invalid input", output)
        self.assertIn("You have selected: controller", output)
    
    @patch('builtins.input', side_effect=['abc', '2'])
    def test_get_device_choice_non_numeric_then_valid(self, mock_input):
        """Test non-numeric input followed by valid choice."""
        with patch('sys.stdout', new=StringIO()) as fake_output:
            result = get_device_choice()
        
        self.assertEqual(result, 'hdd')
        output = fake_output.getvalue()
        self.assertIn("Invalid input", output)
        self.assertIn("You have selected: hdd", output)
    
    @patch('builtins.input', side_effect=['', '3'])
    def test_get_device_choice_empty_then_valid(self, mock_input):
        """Test empty input followed by valid choice."""
        with patch('sys.stdout', new=StringIO()) as fake_output:
            result = get_device_choice()
        
        self.assertEqual(result, 'nic')
        output = fake_output.getvalue()
        self.assertIn("Please enter a valid number", output)
        self.assertIn("You have selected: nic", output)
    
    @patch('builtins.input', side_effect=KeyboardInterrupt())
    def test_get_device_choice_keyboard_interrupt(self, mock_input):
        """Test handling of keyboard interrupt."""
        with self.assertRaises(SystemExit):
            get_device_choice()

class TestIntegration(unittest.TestCase):
    """Integration tests using real PCI IDs from the controller list file."""
    
    def test_real_pci_id_lookup(self):
        """Test lookup with real PCI ID from the controller list."""
        # Using a real PCI ID from the controller list file
        real_pci_id = "1000/0014/1137/020e"  # Broadcom Cisco 12G Modular Raid Controller
        
        # Create minimal test data with this PCI ID
        test_data = {
            "data": {
                "controller": [
                    {
                        "vid": "1000",
                        "did": "0014",
                        "ssid": "020e",
                        "svid": "1137",
                        "vcglink": "http://example.com/broadcom-controller"
                    }
                ],
                "ssd": [],
                "hdd": [],
                "nic": []
            }
        }
        
        result = get_device_link(test_data, 1, real_pci_id, "controller")
        expected = f"Found PCI ID: {real_pci_id}\nVSAN HCL link: http://example.com/broadcom-controller"
        self.assertEqual(result, expected)

if __name__ == '__main__':
    # Create test suite
    test_suite = unittest.TestSuite()
    
    # Add test classes
    test_classes = [
        TestHCLDataLoading,
        TestHCLStatistics, 
        TestDeviceLinkLookup,
        TestInputValidation,
        TestDeviceChoice,
        TestIntegration
    ]
    
    for test_class in test_classes:
        tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
        test_suite.addTests(tests)
    
    # Run tests
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(test_suite)
    
    # Exit with appropriate code
    sys.exit(not result.wasSuccessful())
