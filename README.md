# Sync Duplicates

A shell script that "syncs" a folder which was **duplicated in the past**. The
duplicate folder carries an ` - Old` suffix (e.g. `Photos` and `Photos - Old`).
For every such pair found, the script reconciles the two folders and produces a
collapsible HTML report of everything it did.

## What it does

For each `<name>` / `<name> - Old` pair, every file in the **Old** folder is
classified by its **relative path** and handled as follows:

| Category      | Condition                                              | Action                                                                 |
|---------------|--------------------------------------------------------|------------------------------------------------------------------------|
| **Duplicate** | Same relative path, **same size and checksum**         | The Old copy is **moved into `sync-duplicates/`** (quarantine). The original is kept untouched. |
| **New**       | Path exists **only** in the Old folder                 | **Moved into the original folder**, preserving the directory structure. |
| **Modified**  | Same relative path, but **different size or checksum** | **Logged only** — nothing is moved or deleted, so you can review manually. |

After moving files, any folders left **empty** inside the Old folder (including
the Old folder itself if fully synced) are **removed**, and the removed paths are
listed in the report.

Folders without a matching ` - Old` sibling are left completely untouched. An
` - Old` folder with no matching original is reported as **skipped**.

All actions are written to **`sync-summary.html`** inside the target folder, with
collapsible sections (with emoji headers) for *Processed Pairs*, *Removed
Duplicates*, *New Files*, *Modified Files*, and *Removed Empty Folders*. For
modified files the report shows the *Original* and *Old* paths side by side, each
with its modification date — the most recently changed copy is highlighted in
**green** to help you decide which version to keep.

> **Note:** Both `sync-duplicates/` and `sync-summary.html` are created **inside
> the target folder** being synced. Nothing is deleted outright — duplicates are
> moved to the quarantine folder so you can verify before removing them.

## Requirements

- macOS / BSD (uses `stat -f` and `shasum`). Bash 3.2+ (the macOS default) works.

## Setup — make the script executable

Only needed once:

```sh
chmod +x sync-duplicates.sh
```

## Usage

### Run on a specific folder (pass the path as an argument)

```sh
./sync-duplicates.sh /path/to/main-folder
```

### Run without arguments (uses the current directory)

```sh
cd /path/to/main-folder
/path/to/sync-duplicates.sh
```

In both cases the script prints the resolved target folder and asks for
confirmation before making any changes:

```
Sync this folder? [y/n]
```

Answer `y` to proceed, anything else to abort.

### Disable colored output

Set `NO_COLOR` (useful for logs / non-interactive runs):

```sh
NO_COLOR=1 ./sync-duplicates.sh /path/to/main-folder
```

## Output

After a run you will find, inside the target folder:

- **`sync-summary.html`** — open it in a browser to review every action in
  collapsible sections.
- **`sync-duplicates/`** — quarantined duplicate files, mirroring their original
  `<name> - Old/...` paths so you can trace where each came from. Created only if
  duplicates were found.

## Trying it out (test fixtures)

This repo ships with example data that exercises all three categories plus
unpaired and orphan folders:

```sh
# 1. Copy the example fixtures into a working folder
cp -Rp test/files-to-sync-examples test/files-to-sync

# 2. Run the script against it (confirm with y)
./sync-duplicates.sh test/files-to-sync

# 3. Open the report
open test/files-to-sync/sync-summary.html
```

The example set contains **12 duplicates, 12 new files, and 11 modified files**
across two pairs (`Photos`, `Docs`), three unpaired folders that must stay
untouched (`Music`, `Downloads`, `Projects`), and one orphan `Orphan - Old`
folder that is reported as skipped.

## Notes & safety

- The script is **idempotent** for duplicates and new files: a second run finds
  nothing new to move. Modified files are intentionally re-listed every run since
  they are never touched — resolve them manually and re-run.
- Nothing is permanently deleted. Review `sync-duplicates/` and delete it yourself
  once you are satisfied with the results.
