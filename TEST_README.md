# Testing Guide for get_hba_hcl_link.py

This directory contains comprehensive unit tests for the `get_hba_hcl_link.py` script.

## Test Files

- `test_get_hba_hcl_link.py` - Main test suite with all unit tests
- `run_tests.py` - Test runner script with additional options
- `test_data.json` - Sample HCL data for testing
- `TEST_README.md` - This file

## Running Tests

### Basic Test Execution

```bash
# Run all tests
python3 test_get_hba_hcl_link.py

# Or use the test runner
python3 run_tests.py
```

### Advanced Test Options

```bash
# Run with verbose output
python3 run_tests.py -v

# Run with quiet output
python3 run_tests.py -q

# Run only tests matching a pattern
python3 run_tests.py -p "input"

# List all available tests
python3 run_tests.py --list

# Run specific test class
python3 -m unittest test_get_hba_hcl_link.TestHCLDataLoading

# Run specific test method
python3 -m unittest test_get_hba_hcl_link.TestHCLDataLoading.test_load_hcl_data_success
```

## Test Coverage

The test suite covers the following areas:

### 1. HCL Data Loading (`TestHCLDataLoading`)
- ✅ Successful JSON file loading
- ✅ File not found handling
- ✅ Invalid JSON format handling
- ✅ Missing required keys validation
- ✅ Missing device type validation

### 2. HCL Statistics (`TestHCLStatistics`)
- ✅ Statistics calculation
- ✅ Output formatting
- ✅ Error handling

### 3. Device Link Lookup (`TestDeviceLinkLookup`)
- ✅ Successful device lookup
- ✅ Device not found handling
- ✅ Case-insensitive matching
- ✅ Missing field handling
- ✅ Different device types (controller, ssd, hdd, nic)

### 4. Input Validation (`TestInputValidation`)
- ✅ Valid PCI ID format acceptance
- ✅ Invalid format rejection
- ✅ Wrong format handling
- ✅ Keyboard interrupt handling

### 5. Device Choice (`TestDeviceChoice`)
- ✅ Valid device type selection
- ✅ Invalid choice handling
- ✅ Non-numeric input handling
- ✅ Empty input handling
- ✅ Keyboard interrupt handling

### 6. Integration Tests (`TestIntegration`)
- ✅ Real PCI ID lookup using actual data from controller list

## Test Data

The tests use both:
- **Mock data** - Generated within test methods for isolated testing
- **Real data** - Sample PCI IDs from `localcli_vsan-debug-controller-list.txt`

## Test Structure

Each test class follows the standard unittest pattern:
- `setUp()` - Initialize test fixtures
- Individual test methods with descriptive names
- Proper assertions and error checking

## Key Testing Features

### Mocking
- Uses `unittest.mock` for input/output mocking
- Simulates user input and file operations
- Captures stdout for output verification

### Error Handling
- Tests both success and failure scenarios
- Validates proper error messages
- Ensures graceful handling of exceptions

### Edge Cases
- Empty inputs
- Invalid formats
- Missing data fields
- Keyboard interrupts
- File system errors

## Continuous Integration

To integrate these tests into a CI/CD pipeline:

```bash
# Run tests and capture exit code
python3 run_tests.py -q
echo $?  # Should be 0 for success, 1 for failure
```

## Adding New Tests

To add new tests:

1. Create a new test method in the appropriate test class
2. Follow the naming convention: `test_<function_name>_<scenario>`
3. Add proper docstrings explaining what the test does
4. Include both positive and negative test cases
5. Update this README if adding new test categories

## Example Test Output

```
test_load_hcl_data_success (test_get_hba_hcl_link.TestHCLDataLoading) ... ok
test_load_hcl_data_file_not_found (test_get_hba_hcl_link.TestHCLDataLoading) ... ok
test_get_device_link_found (test_get_hba_hcl_link.TestDeviceLinkLookup) ... ok
test_get_valid_input_valid (test_get_hba_hcl_link.TestInputValidation) ... ok

==================================================
Test Summary:
Tests run: 25
Failures: 0
Errors: 0
Skipped: 0
```

## Troubleshooting

### Common Issues

1. **Import Error**: Make sure `get_hba_hcl_link.py` is in the same directory
2. **Permission Error**: Ensure test files are executable (`chmod +x test_*.py`)
3. **Python Version**: Tests require Python 3.6+ for f-strings and other features

### Debug Mode

For debugging test failures:

```bash
# Run with maximum verbosity
python3 run_tests.py -v

# Run specific failing test
python3 -m unittest test_get_hba_hcl_link.TestDeviceLinkLookup.test_get_device_link_found -v
```
