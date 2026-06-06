# 0. remove any previous test folder (if you ran this before)
rm -rf test/files-to-sync

# 1. Copy the example fixtures into a working folder
cp -Rp test/files-to-sync-examples test/files-to-sync

# 2. Run the script against it (confirm with y)
./sync-duplicates.sh test/files-to-sync

# 3. Open the report
open test/files-to-sync/sync-summary.html