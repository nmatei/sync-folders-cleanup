#!/usr/bin/env bash
#
# sync-duplicates.sh
#
# Syncs a folder that was duplicated in the past. The duplicate carries an
# " - Old" suffix. For every "<name>" / "<name> - Old" pair found inside the
# target directory, files in the Old folder are classified by relative path:
#
#   * duplicate  -> same path, same size, same checksum
#                   The Old copy is moved into ./sync-duplicates (quarantine),
#                   the original is kept untouched.
#   * new        -> path exists only in the Old folder
#                   Moved into the original folder, preserving structure.
#   * modified   -> same path, different size or checksum
#                   Logged only. Nothing is moved or deleted.
#
# All actions are written to ./sync-summary.html (collapsible sections),
# created inside the target folder.
#
# Usage: ./sync-duplicates.sh [TARGET_DIR]
#        If TARGET_DIR is omitted, the current directory is used (after
#        confirmation).

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors (disabled when not a TTY or when NO_COLOR is set)
# ---------------------------------------------------------------------------

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_GREY=$'\033[90m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''
  C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_GREY=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print to stderr so progress messages don't pollute captured stdout.
info() { printf '%s\n' "$*" >&2; }

# A bold, colored section title with a rule underneath.
title() { # <color> <text>
  printf '\n%s%s%s%s\n' "$1" "$C_BOLD" "$2" "$C_RESET" >&2
  printf '%s%s%s\n' "$C_GREY" "────────────────────────────────────────────────────────" "$C_RESET" >&2
}

# A per-file action line: <colored-tag> <relative path>
action() { # <color> <tag> <text>
  printf '  %s%-10s%s %s\n' "$1" "$2" "$C_RESET" "$3" >&2
}

# Cross-platform-ish stat helpers (macOS / BSD stat syntax).
file_size()  { stat -f '%z' "$1"; }                 # size in bytes
file_mtime() { stat -f '%m' "$1"; }                 # mtime, epoch seconds
file_mtime_human() { stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1"; }

file_checksum() { shasum -a 256 "$1" | awk '{print $1}'; }

# Human-readable size from a byte count.
human_size() {
  local bytes="$1"
  if   (( bytes >= 1073741824 )); then awk -v b="$bytes" 'BEGIN{printf "%.2f GB", b/1073741824}'
  elif (( bytes >= 1048576 ));    then awk -v b="$bytes" 'BEGIN{printf "%.2f MB", b/1048576}'
  elif (( bytes >= 1024 ));       then awk -v b="$bytes" 'BEGIN{printf "%.2f KB", b/1024}'
  else printf '%d B' "$bytes"
  fi
}

# HTML-escape a string (handles & < > " ).
html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# 1. Argument & confirmation handling
# ---------------------------------------------------------------------------

RAW_TARGET="${1:-$(pwd)}"

if [[ ! -d "$RAW_TARGET" ]]; then
  info "Error: '$RAW_TARGET' is not a directory."
  exit 1
fi

# Resolve to an absolute path.
TARGET="$(cd "$RAW_TARGET" && pwd)"

title "$C_CYAN" "Sync Duplicates"
info "${C_BOLD}Target folder:${C_RESET} $TARGET"
if [[ -t 0 ]]; then
  printf 'Sync this folder? [y/n] ' >&2
  read -r answer
else
  # Non-interactive (piped input handled by the read below if available).
  read -r answer || answer=""
fi

case "$answer" in
  y|Y) ;;
  *) info "Aborted by user."; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Output locations (inside the target folder)
# ---------------------------------------------------------------------------

QUARANTINE_DIR="$TARGET/sync-duplicates"
SUMMARY_FILE="$TARGET/sync-summary.html"

# ---------------------------------------------------------------------------
# Accumulators for the report
# ---------------------------------------------------------------------------

DUP_ROWS=""    ; DUP_COUNT=0    ; DUP_BYTES=0
NEW_ROWS=""    ; NEW_COUNT=0    ; NEW_BYTES=0
MOD_ROWS=""    ; MOD_COUNT=0
PAIR_ROWS=""   ; PAIR_COUNT=0
EMPTY_ROWS=""  ; EMPTY_COUNT=0
DSSTORE_COUNT=0

# ---------------------------------------------------------------------------
# 2. Pair discovery
# ---------------------------------------------------------------------------

declare -a OLD_DIRS=()
while IFS= read -r d; do
  OLD_DIRS+=("$d")
done < <(find "$TARGET" -mindepth 1 -maxdepth 1 -type d -name '* - Old' | sort)

title "$C_CYAN" "Discovering folder pairs"
if (( ${#OLD_DIRS[@]} == 0 )); then
  info "${C_YELLOW}No '<name> - Old' folders found inside $TARGET. Nothing to do.${C_RESET}"
else
  info "Found ${C_BOLD}${#OLD_DIRS[@]}${C_RESET} '* - Old' folder(s)."
fi

# ---------------------------------------------------------------------------
# 3. Per-pair processing
# ---------------------------------------------------------------------------

for OLD_DIR in "${OLD_DIRS[@]}"; do
  OLD_NAME="$(basename "$OLD_DIR")"
  BASE_NAME="${OLD_NAME% - Old}"
  ORIG_DIR="$TARGET/$BASE_NAME"

  if [[ ! -d "$ORIG_DIR" ]]; then
    info "${C_YELLOW}Skipping '$OLD_NAME': matching original folder '$BASE_NAME' not found.${C_RESET}"
    PAIR_ROWS+="<tr><td>$(html_escape "$OLD_NAME")</td><td><em>missing original — skipped</em></td></tr>"
    continue
  fi

  title "$C_BLUE" "Pair: $BASE_NAME  ←  $OLD_NAME"
  PAIR_COUNT=$((PAIR_COUNT + 1))
  PAIR_ROWS+="<tr><td>$(html_escape "$BASE_NAME")</td><td>$(html_escape "$OLD_NAME")</td></tr>"

  # Walk every file in the Old folder. Use a null-delimited stream so paths
  # with spaces/newlines are handled safely.
  while IFS= read -r -d '' OLD_FILE; do
    REL="${OLD_FILE#"$OLD_DIR"/}"

    # macOS junk: delete .DS_Store outright (never quarantined). Removing them
    # lets the empty-folder cleanup collapse folders that held only this file.
    if [[ "$(basename "$OLD_FILE")" == ".DS_Store" ]]; then
      rm -f "$OLD_FILE"
      DSSTORE_COUNT=$((DSSTORE_COUNT + 1))
      action "$C_GREY" "skipped" "$REL ${C_GREY}→ .DS_Store deleted${C_RESET}"
      continue
    fi

    ORIG_FILE="$ORIG_DIR/$REL"

    old_size="$(file_size "$OLD_FILE")"

    if [[ -f "$ORIG_FILE" ]]; then
      orig_size="$(file_size "$ORIG_FILE")"

      if [[ "$old_size" == "$orig_size" ]] \
         && [[ "$(file_checksum "$OLD_FILE")" == "$(file_checksum "$ORIG_FILE")" ]]; then
        # ---- Duplicate: quarantine the Old copy ----
        dest="$QUARANTINE_DIR/$OLD_NAME/$REL"
        mkdir -p "$(dirname "$dest")"
        mv "$OLD_FILE" "$dest"

        DUP_COUNT=$((DUP_COUNT + 1))
        DUP_BYTES=$((DUP_BYTES + old_size))
        DUP_ROWS+="<tr><td>$(html_escape "$OLD_NAME/$REL")</td><td>$(html_escape "$(basename "$REL")")</td><td>$(human_size "$old_size")</td></tr>"
        action "$C_GREEN" "duplicate" "$OLD_NAME/$REL ${C_GREY}→ quarantined${C_RESET}"
      else
        # ---- Modified: log only ----
        orig_mtime="$(file_mtime "$ORIG_FILE")"
        old_mtime="$(file_mtime "$OLD_FILE")"
        orig_mtime_h="$(file_mtime_human "$ORIG_FILE")"
        old_mtime_h="$(file_mtime_human "$OLD_FILE")"

        # The most recently modified copy (the "last changed") is highlighted
        # in green so it is easy to spot which version to likely keep.
        if (( old_mtime >= orig_mtime )); then
          orig_date_cls="date-old"; old_date_cls="date-new"
        else
          orig_date_cls="date-new"; old_date_cls="date-old"
        fi

        MOD_COUNT=$((MOD_COUNT + 1))
        MOD_ROWS+="<tr class=\"mod\"><td>$(html_escape "$(basename "$REL")")</td><td>$(html_escape "$BASE_NAME/$REL")<br><span class=\"date $orig_date_cls\">$(html_escape "$orig_mtime_h")</span></td><td>$(html_escape "$OLD_NAME/$REL")<br><span class=\"date $old_date_cls\">$(html_escape "$old_mtime_h")</span></td></tr>"
        action "$C_YELLOW" "modified" "$REL ${C_GREY}→ logged only${C_RESET}"
      fi
    else
      # ---- New: move into the original folder ----
      dest="$ORIG_DIR/$REL"
      mkdir -p "$(dirname "$dest")"
      mv "$OLD_FILE" "$dest"

      NEW_COUNT=$((NEW_COUNT + 1))
      NEW_BYTES=$((NEW_BYTES + old_size))
      NEW_ROWS+="<tr><td>$(html_escape "$BASE_NAME/$REL")</td><td>$(html_escape "$(basename "$REL")")</td><td>$(human_size "$old_size")</td></tr>"
      action "$C_CYAN" "new" "$REL ${C_GREY}→ moved into $BASE_NAME/${C_RESET}"
    fi
  done < <(find "$OLD_DIR" -type f -print0)
done

# ---------------------------------------------------------------------------
# 3b. Remove empty folders left behind in the Old folders
# ---------------------------------------------------------------------------
# After files are moved out, directories inside the Old folder (and the Old
# folder itself) may be empty. Repeatedly remove empties so that nested empty
# trees collapse from the leaves up.

if (( ${#OLD_DIRS[@]} > 0 )); then
  title "$C_CYAN" "Removing empty folders"
  for OLD_DIR in "${OLD_DIRS[@]}"; do
    while :; do
      removed_any=0
      while IFS= read -r -d '' d; do
        if rmdir "$d" 2>/dev/null; then
          removed_any=1
          rel="${d#"$TARGET"/}"
          EMPTY_COUNT=$((EMPTY_COUNT + 1))
          EMPTY_ROWS+="<tr><td>$(html_escape "$rel")</td></tr>"
          action "$C_GREY" "removed" "$rel/"
        fi
      done < <(find "$OLD_DIR" -depth -type d -empty -print0 2>/dev/null)
      (( removed_any )) || break
    done
  done
  (( EMPTY_COUNT == 0 )) && info "  ${C_GREY}No empty folders left behind.${C_RESET}"
fi

# ---------------------------------------------------------------------------
# 4. sync-summary.html generation
# ---------------------------------------------------------------------------

generated_at="$(date '+%Y-%m-%d %H:%M:%S')"

[[ -z "$DUP_ROWS"   ]] && DUP_ROWS='<tr><td colspan="3"><em>None</em></td></tr>'
[[ -z "$NEW_ROWS"   ]] && NEW_ROWS='<tr><td colspan="3"><em>None</em></td></tr>'
[[ -z "$MOD_ROWS"   ]] && MOD_ROWS='<tr><td colspan="3"><em>None</em></td></tr>'
[[ -z "$PAIR_ROWS"  ]] && PAIR_ROWS='<tr><td colspan="2"><em>None</em></td></tr>'
[[ -z "$EMPTY_ROWS" ]] && EMPTY_ROWS='<tr><td><em>None</em></td></tr>'

cat > "$SUMMARY_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Sync Summary</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
         margin: 2rem; color: #1d1d1f; background: #f5f5f7; }
  h1 { margin-bottom: .25rem; }
  .meta { color: #6e6e73; margin-bottom: 1.5rem; }
  details { background: #fff; border: 1px solid #d2d2d7; border-radius: 10px;
            margin-bottom: 1rem; padding: .5rem 1rem; }
  summary { font-size: 1.15rem; font-weight: 600; cursor: pointer; padding: .5rem 0; }
  table { border-collapse: collapse; width: 100%; margin-top: .5rem; }
  th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid #ececec;
           font-size: .92rem; vertical-align: top; }
  th { background: #fafafa; }
  tr.mod td { background: #fff8e6; }
  .totals { margin-top: .75rem; font-weight: 600; }
  small { color: #6e6e73; }
  code { background: #eee; padding: .1rem .35rem; border-radius: 4px; }
  .hint { color: #6e6e73; margin: .25rem 0 .5rem; font-size: .9rem; }
  .date { display: inline-block; margin-top: .15rem; font-size: .82rem; }
  .date-new { color: #1a7f37; font-weight: 600; }   /* last changed (most recent) */
  .date-old { color: #9b9b9f; }                      /* older copy */
</style>
</head>
<body>
<h1>🔄 Sync Summary</h1>
<div class="meta">
  Target: <code>$(html_escape "$TARGET")</code><br>
  Generated: $generated_at<br>
  Folder pairs processed: $PAIR_COUNT
</div>

<details open>
  <summary>📂 Processed Pairs ($PAIR_COUNT)</summary>
  <table>
    <thead><tr><th>Original</th><th>Old</th></tr></thead>
    <tbody>$PAIR_ROWS</tbody>
  </table>
</details>

<details open>
  <summary>🗑️ Removed Duplicates ($DUP_COUNT)</summary>
  <table>
    <thead><tr><th>File Path</th><th>Name</th><th>Size</th></tr></thead>
    <tbody>$DUP_ROWS</tbody>
  </table>
  <div class="totals">Total: $DUP_COUNT file(s), $(human_size "$DUP_BYTES")</div>
  <small>Identical copies found in the Old folder, moved into <code>sync-duplicates/</code>; one copy kept in the original folder.</small>
</details>

<details open>
  <summary>✨ New Files ($NEW_COUNT)</summary>
  <p class="hint">New files found inside the <strong>Old</strong> folder (not present in the original) were <strong>moved to the main</strong> (original) folder, preserving their folder structure.</p>
  <table>
    <thead><tr><th>File Path (destination)</th><th>Name</th><th>Size</th></tr></thead>
    <tbody>$NEW_ROWS</tbody>
  </table>
  <div class="totals">Total: $NEW_COUNT file(s), $(human_size "$NEW_BYTES")</div>
</details>

<details open>
  <summary>✏️ Modified Files ($MOD_COUNT)</summary>
  <p class="hint">Same file name but different content in each folder. Nothing is moved or deleted — review manually and decide which copy to keep. The date shown in <span class="date-new">green</span> is the <strong>last changed</strong> (most recent) copy; the <span class="date-old">grey</span> one is older.</p>
  <table>
    <thead><tr><th>Name</th><th>Original</th><th>Old</th></tr></thead>
    <tbody>$MOD_ROWS</tbody>
  </table>
  <div class="totals">Total: $MOD_COUNT file(s)</div>
</details>

<details open>
  <summary>🧹 Removed Empty Folders ($EMPTY_COUNT)</summary>
  <p class="hint">Folders left empty inside the Old folder after syncing were removed.</p>
  <table>
    <thead><tr><th>Folder Path</th></tr></thead>
    <tbody>$EMPTY_ROWS</tbody>
  </table>
  <div class="totals">Total: $EMPTY_COUNT folder(s)</div>
</details>

</body>
</html>
HTML

title "$C_CYAN" "Summary"
printf '  %s%-22s%s %s%d%s file(s)  %s(%s)%s\n' \
  "$C_GREEN" "Duplicates quarantined" "$C_RESET" "$C_BOLD" "$DUP_COUNT" "$C_RESET" "$C_GREY" "$(human_size "$DUP_BYTES")" "$C_RESET" >&2
printf '  %s%-22s%s %s%d%s file(s)  %s(%s)%s\n' \
  "$C_CYAN" "New files moved" "$C_RESET" "$C_BOLD" "$NEW_COUNT" "$C_RESET" "$C_GREY" "$(human_size "$NEW_BYTES")" "$C_RESET" >&2
printf '  %s%-22s%s %s%d%s file(s)\n' \
  "$C_YELLOW" "Modified (logged only)" "$C_RESET" "$C_BOLD" "$MOD_COUNT" "$C_RESET" >&2
printf '  %s%-22s%s %s%d%s folder(s)\n' \
  "$C_GREY" "Empty folders removed" "$C_RESET" "$C_BOLD" "$EMPTY_COUNT" "$C_RESET" >&2
printf '  %s%-22s%s %s%d%s file(s)\n' \
  "$C_GREY" ".DS_Store deleted" "$C_RESET" "$C_BOLD" "$DSSTORE_COUNT" "$C_RESET" >&2

title "$C_CYAN" "Generated files & folders"
info "  ${C_BOLD}Report:${C_RESET}      $SUMMARY_FILE"
if (( DUP_COUNT > 0 )); then
  info "  ${C_BOLD}Quarantine:${C_RESET}  $QUARANTINE_DIR/"
else
  info "  ${C_BOLD}Quarantine:${C_RESET}  ${C_GREY}(not created — no duplicates found)${C_RESET}"
fi
info ""
info "${C_GREEN}${C_BOLD}✓ Done.${C_RESET} Open the report in a browser to review collapsible sections."
