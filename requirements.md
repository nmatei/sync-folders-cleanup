# Sync Duplicates

This project scope is to create some shell scripts to 'sync' the content of a local directory having duplicates files/folders.

# Description

- The script will be runned using .sh command in a terminal inside main folder to be synced (or pass the path as an argument, ask for confirmation, in case user did not provide a path the current directory will be used, but ask user to confirm using 'y/n' before start syncing).

- main requirement for user: 
  - script should identify 2 folders to sync:
    - Folder_name: the folder that contains the original files/folders - this will remain unchanged.
    - Folder_name - Old: this folder got duplicated in the past, and has 'Old' suffix, and could contains
        a) the same files/folders as the original one, so some of them are duplicates (same name, size, checksum)
        b) could contain some some new files/folders that are not in the original one
        c) also could have the same file name but different content (different size, checksum), in case this file got modified by mistake in this folder


# Requirements

- we will have more steps in this process, that will generate a log file named 'sync-summary.html' to keep track of all the actions taken during the sync process, and to have a reference for future review.
- All sections will have posibility to 'collapse/expand' to make it easier to review the log file later, and to focus on specific sections when needed.

## Remove duplicates files
    - Identify duplicate files based on name, size, or checksum.
    - move all files marked as duplicates inside ./sync-duplicates, keeping only one copy - duplicate files will be deleted from the 'Old' folder, and only one copy will be kept in the original folder.
    - collect all paths of the 'moved' files in a log file named 'sync-summary.html' for future reference (in Removed Duplicates section)
    - log should contain the file path / file name / size - for each removed duplicate file
    - log should contain the total number of removed duplicate files and the total size of removed duplicate files

## Save new files
    - Identify new files in the 'Old' folder that are not present in the original folder.
    - move all new files to the original folder (keeping the original folder structure), and log their paths in the 'sync-summary.html' file (in New Files section)
    - log should contain the file path / file name / size - for each moved new file
    - log should contain the total number of moved new files and the total size of moved new files

## Handle modified files
    - Identify files with the same name but different content (different size, checksum) in the 'Old' folder compared to the original folder.
    - for now we will just log the paths of these modified files in the 'sync-summary.html' file (in Modified Files section) for future reference, and we will not move or delete any of these files, as we need to review them manually before taking any action.
    - log should contain the file path / file name / size / date modified - for each modified file
    - log should contain the total number of modified files and the total size of modified files
    - when logging an entry in this case we want to have one 'name' since the name is unique, but to have 2 columns for date modified and point to 'possible newest' and 'possible oldest' to help us review these files later and decide which one to keep, or if we need to keep both of them.