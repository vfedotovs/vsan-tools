#!/usr/bin/python3
"""
Simple test runner for get_hba_hcl_link.py tests.
Usage: python3 run_tests.py [options]
"""

import sys
import unittest
import argparse
from test_get_hba_hcl_link import (
    TestHCLDataLoading,
    TestHCLStatistics,
    TestDeviceLinkLookup,
    TestInputValidation,
    TestDeviceChoice,
    TestIntegration
)

def run_tests(verbosity=2, pattern=None):
    """Run the test suite with specified options."""
    # Create test suite
    test_suite = unittest.TestSuite()
    
    # Define all test classes
    test_classes = [
        TestHCLDataLoading,
        TestHCLStatistics,
        TestDeviceLinkLookup,
        TestInputValidation,
        TestDeviceChoice,
        TestIntegration
    ]
    
    # Add tests based on pattern if specified
    if pattern:
        loader = unittest.TestLoader()
        for test_class in test_classes:
            tests = loader.loadTestsFromTestCase(test_class)
            for test in tests:
                if pattern.lower() in str(test).lower():
                    test_suite.addTest(test)
    else:
        # Add all tests
        for test_class in test_classes:
            tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
            test_suite.addTests(tests)
    
    # Run tests
    runner = unittest.TextTestRunner(verbosity=verbosity)
    result = runner.run(test_suite)
    
    # Print summary
    print(f"\n{'='*50}")
    print(f"Test Summary:")
    print(f"Tests run: {result.testsRun}")
    print(f"Failures: {len(result.failures)}")
    print(f"Errors: {len(result.errors)}")
    print(f"Skipped: {len(result.skipped) if hasattr(result, 'skipped') else 0}")
    
    if result.failures:
        print(f"\nFailures:")
        for test, traceback in result.failures:
            print(f"  {test}: {traceback}")
    
    if result.errors:
        print(f"\nErrors:")
        for test, traceback in result.errors:
            print(f"  {test}: {traceback}")
    
    return result.wasSuccessful()

def main():
    """Main function to handle command line arguments and run tests."""
    parser = argparse.ArgumentParser(description='Run tests for get_hba_hcl_link.py')
    parser.add_argument('-v', '--verbose', action='store_true', 
                       help='Increase verbosity')
    parser.add_argument('-q', '--quiet', action='store_true',
                       help='Decrease verbosity')
    parser.add_argument('-p', '--pattern', type=str,
                       help='Run only tests matching pattern')
    parser.add_argument('--list', action='store_true',
                       help='List all available tests')
    
    args = parser.parse_args()
    
    # Determine verbosity
    if args.verbose:
        verbosity = 3
    elif args.quiet:
        verbosity = 1
    else:
        verbosity = 2
    
    # List tests if requested
    if args.list:
        print("Available test classes:")
        test_classes = [
            TestHCLDataLoading,
            TestHCLStatistics,
            TestDeviceLinkLookup,
            TestInputValidation,
            TestDeviceChoice,
            TestIntegration
        ]
        
        for test_class in test_classes:
            print(f"  {test_class.__name__}")
            loader = unittest.TestLoader()
            tests = loader.loadTestsFromTestCase(test_class)
            for test in tests:
                print(f"    {test}")
        return 0
    
    # Run tests
    success = run_tests(verbosity=verbosity, pattern=args.pattern)
    
    # Exit with appropriate code
    return 0 if success else 1

if __name__ == '__main__':
    sys.exit(main())
