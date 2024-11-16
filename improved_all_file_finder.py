#!/usr/bin/env python3

import os
import concurrent.futures


def find_vobd_all_in_folder(folder):
    """Search for all 'vobd.all' files in the given folder and its subfolders."""
    vobd_files = []
    for dirpath, dirnames, filenames in os.walk(folder):
        if 'vobd.all' in filenames:
            vobd_files.append(os.path.join(dirpath, 'vobd.all'))
    return vobd_files

def find_all_vobd_all(folders):
    """Find all 'vobd.all' files in multiple folders using multithreading."""
    vobd_file_paths = []

    # Use ThreadPoolExecutor to search in parallel
    with concurrent.futures.ThreadPoolExecutor() as executor:
        # Submit tasks for each folder to the executor
        futures = [executor.submit(find_vobd_all_in_folder, folder) for folder in folders]

        # Collect results as they complete
        for future in concurrent.futures.as_completed(futures):
            vobd_file_paths.extend(future.result())

    return vobd_file_paths

# Get all subdirectories in the current directory
current_directory = os.getcwd()
folders = [os.path.join(current_directory, folder) for folder in os.listdir(current_directory)
           if os.path.isdir(os.path.join(current_directory, folder))]

# Find all vobd.all file paths in the subdirectories
all_vobd_paths = find_all_vobd_all(folders)

# Print results
for path in all_vobd_paths:
    print(path)

