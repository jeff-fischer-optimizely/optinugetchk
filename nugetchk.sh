#!/usr/bin/env bash
# nugetchk.sh - EPiServer/Optimizely NuGet Package Health Checker
# Designed to run on Azure App Service Linux (Kudu SSH)
#
# Usage: bash nugetchk.sh [--notes] [--debug] [app_root_path]
#   --notes          Show all release note summaries between installed and latest
#   --debug          Show verbose debug output to stderr
#   app_root_path    defaults to /home/site/wwwroot
#
# Data sources:
#   - Installed packages:  parsed from .deps.json in the app root
#   - Available versions:  Optimizely NuGet feed (nuget.optimizely.com)
#   - Known issues:        scraped at runtime from world.optimizely.com
#                          (frozen May 2024 - site no longer updated)

set -euo pipefail

# -- Parse arguments -----------------------------------------------------------
SHOW_NOTES=false
DEBUG=false
APP_ROOT="/home/site/wwwroot"
for arg in "$@"; do
  case "$arg" in
    --notes|-n)   SHOW_NOTES=true ;;
    --debug|-d)   DEBUG=true ;;
    *)            APP_ROOT="$arg" ;;
  esac
done
OPTI_NUGET_REG="https://nuget.optimizely.com/v3/registration"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWN_ISSUES_FILE="$SCRIPT_DIR/known_issues.json"
REPORT_FILE="$SCRIPT_DIR/nugetchk_report.json"

# Keywords that flag memory / performance problems (case-insensitive)
KEYWORDS=(
  "memory leak"
  "out of memory"
  "high memory"
  "performance"
  "slow"
  "timeout"
  "deadlock"
  "thread"
  "cpu"
)

# -- Helpers -------------------------------------------------------------------

log()  { printf '[nugetchk] %s\n' "$*" >&2; }
dbg()  { [[ "$DEBUG" == "true" ]] && printf '[nugetchk] DEBUG: %s\n' "$*" >&2 || true; }
warn() { printf '[nugetchk] WARNING: %s\n' "$*" >&2; }
die()  { printf '[nugetchk] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found."
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  log "jq not found, downloading static binary ..."
  local jq_url jq_path
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe"
      jq_path="$SCRIPT_DIR/jq.exe"
      ;;
    *)
      jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
      jq_path="$SCRIPT_DIR/jq"
      ;;
  esac
  curl -sfL --max-time 30 -o "$jq_path" "$jq_url" || die "Failed to download jq"
  chmod +x "$jq_path"
  export PATH="$SCRIPT_DIR:$PATH"
  command -v jq >/dev/null 2>&1 || die "jq download succeeded but still not usable"
  log "jq installed to $jq_path"
}

# Returns 0 if $1 > $2 (semver numeric comparison), 1 otherwise
semver_gt() {
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2)
  local i
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    local ai="${a[i]:-0}" bi="${b[i]:-0}"
    ai="${ai%%-*}"; bi="${bi%%-*}"
    if ((10#$ai > 10#$bi)); then return 0; fi
    if ((10#$ai < 10#$bi)); then return 1; fi
  done
  return 1
}

# Returns 0 if $1 >= $2
semver_gte() {
  [[ "$1" == "$2" ]] && return 0
  semver_gt "$1" "$2"
}

# Compute human-readable version delta
version_delta() {
  local inst="$1" latest="$2"
  [[ "$latest" == "unknown" || -z "$latest" ]] && { echo "?"; return; }
  [[ "$inst" == "$latest" ]] && { echo "up to date"; return; }

  local IFS=.
  # shellcheck disable=SC2206
  local a=($inst) b=($latest)
  local ai="${a[0]:-0}" bi="${b[0]:-0}"
  local am="${a[1]:-0}" bm="${b[1]:-0}"
  local ap="${a[2]:-0}" bp="${b[2]:-0}"
  ai="${ai%%-*}"; bi="${bi%%-*}"
  am="${am%%-*}"; bm="${bm%%-*}"
  ap="${ap%%-*}"; bp="${bp%%-*}"

  local dmaj=$((10#$bi - 10#$ai))
  local dmin=$((10#$bm - 10#$am))
  local dpat=$((10#$bp - 10#$ap))

  local parts=()
  if ((dmaj != 0)); then parts+=("${dmaj}maj"); fi
  if ((dmin != 0)); then parts+=("${dmin}min"); fi
  if ((dpat != 0)); then parts+=("${dpat}pat"); fi

  if [[ ${#parts[@]} -eq 0 ]]; then
    echo "up to date"
  else
    local result="${parts[0]}"
    local idx
    for ((idx = 1; idx < ${#parts[@]}; idx++)); do
      result+=", ${parts[$idx]}"
    done
    echo "+${result}"
  fi
}

# Extract product family: first two dot-segments of a package name
# e.g. EPiServer.CMS.Core → EPiServer.CMS, EPiServer.Find.Commerce → EPiServer.Find
pkg_family() {
  local IFS=.
  # shellcheck disable=SC2206
  local parts=($1)
  echo "${parts[0]}.${parts[1]}"
}

# Highlight all KEYWORDS occurrences in text with bright-yellow background.
# Operates on plain text: collects all match positions first (on lowercased
# copy), then applies ANSI codes in a single pass so escape sequences never
# affect position arithmetic.
highlight_kw() {
  local text="$1"
  local yon=$'\033[30;103m'   # black text, bright-yellow background
  local yoff=$'\033[0m'
  local lower_text="${text,,}"

  # Collect "start:len" for every keyword occurrence
  local matches=()
  local kw
  for kw in "${KEYWORDS[@]}"; do
    local lower_kw="${kw,,}" kwlen=${#kw} pos=0
    while true; do
      local rest="${lower_text:$pos}"
      local before="${rest%%"$lower_kw"*}"
      [[ "$before" == "$rest" ]] && break
      matches+=("$((pos + ${#before})):${kwlen}")
      pos=$((pos + ${#before} + kwlen))
    done
  done

  if [[ ${#matches[@]} -eq 0 ]]; then
    printf '%s' "$text"
    return
  fi

  # Sort by start position, then apply non-overlapping highlights
  local IFS=$'\n'
  local sorted
  sorted=($(printf '%s\n' "${matches[@]}" | sort -t: -k1,1n))

  local out="" cur=0
  for m in "${sorted[@]}"; do
    local ms="${m%%:*}" ml="${m##*:}" me=$((${m%%:*} + ${m##*:}))
    if [[ $ms -ge $cur ]]; then
      out+="${text:$cur:$((ms - cur))}${yon}${text:$ms:$ml}${yoff}"
      cur=$me
    fi
  done
  out+="${text:$cur}"
  printf '%s' "$out"
}

# -- Runtime release notes scraper ---------------------------------------------
# Fetches release notes from world.optimizely.com/documentation/Release-Notes/
# Uses ?packageFilter=<PackageName>&typeFilter=All for per-package results.
# (frozen May 2024 - site no longer updated)

WORLD_RELEASE_NOTES_URL="https://world.optimizely.com/documentation/Release-Notes/"

# Map an EPiServer/Optimizely package name to a world.optimizely.com group
pkg_to_world_group() {
  case "$1" in
    EPiServer.CMS*|EPiServer.Forms*)  echo "CMS" ;;
    EPiServer.Commerce*)              echo "Commerce" ;;
    EPiServer.Find*)                  echo "Find" ;;
    EPiServer.Profiles*|Optimizely.Personalization*) echo "Personalization" ;;
    *)                                echo "" ;;
  esac
}

# Scrape release notes HTML into a TSV file
# Args: output_file package_name1 [package_name2 ...]
# Output format: ID<TAB>PACKAGE<TAB>VERSION<TAB>DESCRIPTION
scrape_world_release_notes() {
  local output_file="$1"
  shift
  local packages=("$@")
  local seen_ids=""
  local fetched_filters=""

  # Disable errexit for HTML parsing - individual failures shouldn't crash
  set +e

  dbg "scraper: ${#packages[@]} packages to process"

  local pkg_idx=0
  local total_extracted=0

  for pkg_name in "${packages[@]}"; do
    pkg_idx=$((pkg_idx + 1))
    local page=1
    local max_pages=10
    local filter_name="$pkg_name"

    # Progress indicator (non-debug): overwrite same line
    printf '\r  Scraping release notes ... [%d/%d] %s\033[K' "$pkg_idx" "${#packages[@]}" "$pkg_name" >&2

    while [[ $page -le $max_pages ]]; do
      # Skip if we already fetched this filter_name (dedup across packages)
      if [[ $page -eq 1 && "$fetched_filters" == *"|${filter_name}|"* ]]; then
        dbg "scraper: skipping ${filter_name} (already fetched)"
        break
      fi

      local url="${WORLD_RELEASE_NOTES_URL}?packageFilter=${filter_name}&typeFilter=All"
      if [[ $page -eq 1 ]]; then
        dbg "scraper: fetching ${url}"
      else
        dbg "scraper: fetching page ${page}, filter=${filter_name}"
      fi

      local html=""
      if [[ $page -eq 1 ]]; then
        html=$(curl -sf --max-time 30 "${url}" 2>/dev/null) || {
          warn "curl FAILED for ${filter_name} (exit $?)"
          break
        }
      else
        # Pagination uses form POST
        html=$(curl -sf --max-time 30 \
          -d "packageFilter=${filter_name}" \
          -d "typeFilter=All" \
          -d "PageIndex=${page}" \
          "${WORLD_RELEASE_NOTES_URL}" 2>/dev/null) || {
          dbg "scraper: curl POST failed for page ${page} (exit $?)"
          break
        }
      fi

      dbg "scraper: curl OK, html length=${#html}"

      # Write html to temp file to avoid echo/printf issues with large content
      local html_file="$output_file.html"
      printf '%s\n' "$html" > "$html_file"
      local file_size
      file_size=$(wc -c < "$html_file" | tr -d ' ')
      dbg "scraper: wrote html_file, size=${file_size} bytes"

      # Stop if page has no release note entries
      local grep_count
      grep_count=$(grep -c 'releaseNoteId=' "$html_file" || true)
      dbg "scraper: grep releaseNoteId= count=${grep_count}"

      if [[ "$grep_count" -eq 0 ]]; then
        rm -f "$html_file"
        # On first page, try parent package name (e.g. EPiServer.Forms.Core → EPiServer.Forms)
        if [[ $page -eq 1 && "$filter_name" == *.*.* ]]; then
          local parent_name="${filter_name%.*}"
          dbg "scraper: no results for ${filter_name}, falling back to ${parent_name}"
          filter_name="$parent_name"
          printf '\r  Scraping release notes ... [%d/%d] %s\033[K' "$pkg_idx" "${#packages[@]}" "$parent_name" >&2
          continue
        fi
        dbg "scraper: no releaseNoteId found, no more fallbacks, stopping"
        break
      fi

      # Mark this filter as fetched (only after confirming results exist)
      if [[ $page -eq 1 ]]; then
        fetched_filters="${fetched_filters}|${filter_name}|"
        dbg "scraper: marked ${filter_name} as fetched"
      fi

      # Parse: collapse HTML to single line, split on releaseNoteId boundaries
      local flat page_count=0
      flat=$(tr '\n' ' ' < "$html_file" | tr -s ' ')
      rm -f "$html_file"

      # Split on releaseNoteId= boundaries using awk record separator (portable)
      local segments_file="$output_file.segments"
      printf '%s\n' "$flat" | awk 'BEGIN{RS="releaseNoteId="} NR>1{print "releaseNoteId=" $0}' > "$segments_file" 2>/dev/null || true

      local seg_count
      seg_count=$(wc -l < "$segments_file" | tr -d ' ')
      dbg "scraper: ${filter_name} page ${page}: ${seg_count} segments found"

      while IFS= read -r segment; do
        # --- Extract release note ID ---
        local nid
        nid=$(echo "$segment" | grep -o '^releaseNoteId=[A-Za-z]*-[0-9]*' | head -1)
        nid="${nid#releaseNoteId=}"
        [[ -z "$nid" ]] && continue

        # Skip duplicates (across pages)
        if [[ "$seen_ids" == *"|${nid}|"* ]]; then continue; fi
        seen_ids="${seen_ids}|${nid}|"

        # Strip HTML tags for text extraction
        local text
        text=$(echo "$segment" | sed 's/<[^>]*>//g' | tr -s ' ')

        # Description: text after the ID, before "Fix Version/s:"
        local desc
        desc=$(echo "$text" | sed "s/.*${nid}//" | sed 's/Fix Version.*//' | tr -s ' ' | sed 's/^ *//' | sed 's/ *$//')

        # Parse "Fix Version/s: Package Version; Package2 Version2;"
        local fix_raw
        fix_raw=$(echo "$text" | sed 's/.*Fix Version\/ *s: *//' | sed 's/[A-Z][a-z][a-z]* [0-9][0-9]*, [0-9][0-9][0-9][0-9].*//')

        # Split by ; and emit one TSV line per package/version pair
        local old_ifs="$IFS"
        IFS=';'
        local pairs
        read -ra pairs <<< "$fix_raw"
        IFS="$old_ifs"
        for pair in "${pairs[@]}"; do
          pair=$(echo "$pair" | sed 's/^ *//' | sed 's/ *$//')
          local p v
          p=$(echo "$pair" | awk '{print $1}')
          v=$(echo "$pair" | awk '{print $2}')
          if [[ -n "$p" && "$p" == *"."* && -n "$v" && "$v" =~ ^[0-9] ]]; then
            printf '%s\t%s\t%s\t%s\n' "$nid" "$p" "$v" "$desc" >> "$output_file"
            page_count=$((page_count + 1))
          else
            dbg "scraper: SKIPPED pair p=[${p}] v=[${v}] from nid=${nid}"
          fi
        done
      done < "$segments_file"
      rm -f "$segments_file"
      total_extracted=$((total_extracted + page_count))
      dbg "scraper: ${filter_name} page ${page}: ${page_count} entries extracted"

      # If this page had no new entries, stop paginating
      [[ $page_count -eq 0 ]] && break
      page=$((page + 1))
    done
  done

  # Clear the progress line
  printf '\r  Scraping release notes ... done. %d entries extracted.\033[K\n' "$total_extracted" >&2

  local total_lines
  total_lines=$(wc -l < "$output_file" | tr -d ' ')
  dbg "scraper: DONE. Total TSV lines written: ${total_lines}"

  set -e  # Restore errexit
}

# -- Step 1: Locate deps.json --------------------------------------------------

find_deps_json() {
  local found=""
  local search_dirs=("." "$SCRIPT_DIR" "$APP_ROOT")

  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    log "Searching for .deps.json in $dir ..."
    found=$(find "$dir" -maxdepth 2 -name '*.deps.json' -type f 2>/dev/null | head -1)
    [[ -n "$found" ]] && break
  done

  if [[ -z "$found" ]]; then
    die "No .deps.json file found in: ${search_dirs[*]}"
  fi
  log "Found: $found"
  echo "$found"
}

# -- Step 2: Extract installed EPiServer/Optimizely packages -------------------

extract_packages() {
  local deps_file="$1"
  log "Extracting EPiServer/Optimizely packages from $(basename "$deps_file") ..."
  jq -r '
    .libraries // {} | keys[] |
    select(test("^(EPiServer|Optimizely)"; "i")) |
    split("/") |
    { name: .[0], version: .[1] }
  ' "$deps_file" | jq -s '.'
}

# -- Step 3: Get latest available version from Optimizely NuGet feed -----------

get_latest_version() {
  local pkg_name="$1"
  local inst_version="${2:-0.0.0}"
  local lower_name
  lower_name=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]')
  local reg_url="$OPTI_NUGET_REG/$lower_name/index.json"
  local json
  json=$(curl -sf --max-time 15 "$reg_url" 2>/dev/null) || { echo "|"; return; }

  local inst_major="${inst_version%%.*}"

  # Return "same_major_latest|absolute_latest"
  echo "$json" | jq -r --arg maj "$inst_major" '
    [ .items[]?.items[]? |
      .catalogEntry | select(.listed == true) | .version
    ] as $all |
    ($all | last // "") as $absolute |
    ([ $all[] | select(split(".")[0] == $maj) ] | last // "") as $same_major |
    "\($same_major)|\($absolute)"
  ' 2>/dev/null || echo "|"
}

# Export functions/vars needed by background subshells
export -f get_latest_version semver_gt semver_gte version_delta log warn
export OPTI_NUGET_REG

# -- Main ----------------------------------------------------------------------

main() {
  require_cmd curl
  ensure_jq

  echo ""
  echo "======================================================================"
  echo "  EPiServer/Optimizely NuGet Package Health Checker"
  echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "======================================================================"

  local deps_file
  deps_file=$(find_deps_json)

  # Step 2: Extract installed packages
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "${tmp_dir:-}"' EXIT

  local packages_file="$tmp_dir/_packages.json"
  extract_packages "$deps_file" > "$packages_file"

  local pkg_count
  pkg_count=$(jq 'length' < "$packages_file")

  if [[ "$pkg_count" -eq 0 ]]; then
    echo ""
    echo "  No EPiServer/Optimizely packages found. Nothing to check."
    exit 0
  fi

  echo ""
  echo "  Found $pkg_count EPiServer/Optimizely packages in $(basename "$deps_file")"
  echo ""

  # -- Step 3: Get latest versions from Optimizely NuGet feed ------------------

  local latest_versions_file="$tmp_dir/_latest_versions.json"
  local latest_samemaj_file="$tmp_dir/_latest_samemaj.json"
  echo '{}' > "$latest_versions_file"
  echo '{}' > "$latest_samemaj_file"

  local pkg_list_file="$tmp_dir/_packages.jsonl"
  jq -c '.[]' < "$packages_file" > "$pkg_list_file"

  printf "  Querying nuget.optimizely.com for latest versions ...\n"

  local i=0
  local newer_major_notes=()
  while IFS= read -r pkg_entry; do
    local name version
    name=$(echo "$pkg_entry" | jq -r '.name')
    version=$(echo "$pkg_entry" | jq -r '.version')
    i=$((i + 1))

    local result latest_samemaj latest_abs
    result=$(get_latest_version "$name" "$version")
    latest_samemaj="${result%%|*}"
    latest_abs="${result##*|}"

    [[ -z "$latest_samemaj" ]] && latest_samemaj="$latest_abs"

    if [[ -n "$latest_abs" ]]; then
      jq --arg n "$name" --arg v "$latest_abs" '. + {($n): $v}' < "$latest_versions_file" > "$latest_versions_file.tmp" && mv "$latest_versions_file.tmp" "$latest_versions_file"
    fi

    if [[ -n "$latest_samemaj" ]]; then
      jq --arg n "$name" --arg v "$latest_samemaj" '. + {($n): $v}' < "$latest_samemaj_file" > "$latest_samemaj_file.tmp" && mv "$latest_samemaj_file.tmp" "$latest_samemaj_file"
    else
      latest_samemaj="unknown"
    fi

    if [[ -n "$latest_abs" && -n "$latest_samemaj" && "$latest_abs" != "$latest_samemaj" ]]; then
      newer_major_notes+=("    * $name: v$latest_abs available (current major: ${version%%.*})")
    fi
  done < "$pkg_list_file"

  echo ""

  # -- Step 4: Scrape release notes from world.optimizely.com -----------------

  # Collect unique package names to fetch release notes for
  local packages_needed=()
  local seen_pkgs=""
  while IFS= read -r pkg_entry; do
    local pname
    pname=$(echo "$pkg_entry" | jq -r '.name')
    if [[ -n "$pname" && "$seen_pkgs" != *"|${pname}|"* ]]; then
      packages_needed+=("$pname")
      seen_pkgs="${seen_pkgs}|${pname}|"
    fi
  done < "$pkg_list_file"

  local db_file="$tmp_dir/_release_notes.tsv"
  : > "$db_file"

  if [[ ${#packages_needed[@]} -gt 0 ]]; then
    scrape_world_release_notes "$db_file" "${packages_needed[@]}"
  else
    warn "No EPiServer/Optimizely packages found for release note lookup"
  fi

  local note_total
  note_total=$(wc -l < "$db_file" | tr -d ' ')
  printf "  Fetched %s release notes from world.optimizely.com\n" "$note_total"

  # Debug: show the TSV contents
  dbg "Step 4: TSV file has ${note_total} lines"
  if [[ "$note_total" -gt 0 ]]; then
    if [[ "$DEBUG" == "true" ]]; then
      dbg "Step 4: unique packages in TSV:"
      cut -f2 "$db_file" | sort -u | while read -r p; do
        local cnt
        cnt=$(grep -c "	${p}	" "$db_file" || true)
        dbg "  - ${p} (${cnt} entries)"
      done
      dbg "Step 4: first 5 TSV lines:"
      head -5 "$db_file" | while IFS=$'\t' read -r a b c d; do
        dbg "  ${a} | ${b} | ${c} | ${d:0:60}"
      done
    fi
  else
    dbg "Step 4: TSV is EMPTY - no release notes were scraped!"
  fi

  # Convert to JSON for keyword matching (write to file to avoid echo corruption)
  local all_notes_file="$tmp_dir/_all_notes.json"
  while IFS=$'\t' read -r nid pkg ver desc; do
    [[ -z "$nid" ]] && continue
    printf '%s\n' "$nid"$'\t'"$pkg"$'\t'"$ver"$'\t'"$desc"
  done < "$db_file" | jq -R 'split("\t") | {id: .[0], pkg: .[1], ver: .[2], desc: .[3]}' | jq -s '.' > "$all_notes_file"

  local notes_json_count
  notes_json_count=$(jq 'length' < "$all_notes_file")
  dbg "Step 4→5: converted ${notes_json_count} TSV lines to JSON"

  echo ""

  # -- Step 5: Build known_issues.json (keyword-matched entries) ---------------

  local kw_json
  kw_json=$(printf '%s\n' "${KEYWORDS[@]}" | jq -R '.' | jq -s '.')

  local all_issues_file="$tmp_dir/_all_issues.json"
  jq --argjson kws "$kw_json" '
    [.[] | objects |
      select(.pkg != null) | select(.desc != null) |
      . as $entry |
      [$kws[] | . as $kw | select(($entry.desc // "") | ascii_downcase | contains($kw))] as $matched |
      select(($matched | length) > 0) |
      {
        package: .pkg,
        release_note_id: .id,
        fix_version: (.ver // "unknown"),
        matched_keywords: $matched,
        release_notes_snippet: .desc
      }
    ]
  ' < "$all_notes_file" > "$all_issues_file"

  cp "$all_issues_file" "$KNOWN_ISSUES_FILE"
  local issue_count
  issue_count=$(jq 'length' < "$all_issues_file")

  dbg "Step 5: ${issue_count} entries matched keywords out of ${notes_json_count} total"
  if [[ "$issue_count" -gt 0 && "$DEBUG" == "true" ]]; then
    dbg "Step 5: matched issues:"
    jq -r '.[] | objects | "  \(.release_note_id // "?") | \(.package // "?") \(.fix_version // "?") | kw: \(.matched_keywords | join(", ")) | \((.release_notes_snippet // "")[:80])"' < "$all_issues_file" 2>/dev/null | while read -r line; do
      dbg "$line"
    done
  fi

  # -- Step 6: Build recommendations -------------------------------------------

  # Validate all_issues_file before processing
  local issues_type
  issues_type=$(jq -r 'type' < "$all_issues_file" 2>/dev/null) || issues_type="invalid"
  if [[ "$issues_type" != "array" ]]; then
    warn "all_issues_file has unexpected type: ${issues_type} (expected array)"
    echo '[]' > "$all_issues_file"
  fi
  local issues_file_lines
  issues_file_lines=$(wc -l < "$all_issues_file" | tr -d ' ')
  dbg "Step 6: all_issues_file validated: type=${issues_type}, lines=${issues_file_lines}, issues=${issue_count}"

  local recommendations_file="$tmp_dir/_recommendations.json"
  echo '[]' > "$recommendations_file"

  while IFS= read -r pkg_entry; do
    local name version
    name=$(echo "$pkg_entry" | jq -r '.name')
    version=$(echo "$pkg_entry" | jq -r '.version')

    # Match by product family (first two dot-segments)
    # e.g. EPiServer.CMS.Core notes match EPiServer.CMS.AspNetCore.HtmlHelpers
    dbg "Step 6: processing ${name} v${version} ..."
    local name_family
    name_family=$(pkg_family "$name")
    local pkg_issues_file="$tmp_dir/_pkg_issues.json"
    if ! jq --arg pkg "$name" --arg fam "$name_family" '
      [ .[] | objects | select(has("package")) |
        (.package // "") as $p |
        (($p | split("."))[:2] | join(".")) as $pfam |
        select($p == $pkg or $pfam == $fam)
      ]
    ' < "$all_issues_file" > "$pkg_issues_file" 2>/dev/null; then
      warn "jq family-match failed for ${name}, using empty result"
      echo '[]' > "$pkg_issues_file"
    fi

    local family_match_count
    family_match_count=$(jq 'length' < "$pkg_issues_file")
    dbg "Step 6: ${name} v${version} → ${family_match_count} family-matched keyword issues"

    # Get latest versions early so we can filter by reachable fix versions
    local latest_samemaj_ver latest_abs_ver
    latest_samemaj_ver=$(jq -r --arg n "$name" '.[$n] // "unknown"' < "$latest_samemaj_file")
    latest_abs_ver=$(jq -r --arg n "$name" '.[$n] // "unknown"' < "$latest_versions_file")

    local relevant_file="$tmp_dir/_relevant.jsonl"
    : > "$relevant_file"
    while IFS= read -r issue; do
      [[ -z "$issue" || "$issue" == "null" ]] && continue
      local fix_ver issue_id
      fix_ver=$(echo "$issue" | jq -r '.fix_version')
      issue_id=$(echo "$issue" | jq -r '.release_note_id')
      [[ "$fix_ver" == "unknown" ]] && continue
      # Fix must be newer than installed AND reachable by upgrading to latest
      if semver_gt "$fix_ver" "$version"; then
        if [[ "$latest_samemaj_ver" != "unknown" ]] && ! semver_gte "$latest_samemaj_ver" "$fix_ver"; then
          dbg "Step 6: ${issue_id} fix=${fix_ver} > latest=${latest_samemaj_ver} → unreachable, skipped"
          continue
        fi
        dbg "Step 6: ${issue_id} fix=${fix_ver} > installed=${version} → RELEVANT"
        printf '%s\n' "$issue" >> "$relevant_file"
      else
        dbg "Step 6: ${issue_id} fix=${fix_ver} <= installed=${version} → skipped"
      fi
    done < <(jq -c '.[]' < "$pkg_issues_file" 2>/dev/null)

    local relevant_issues_file="$tmp_dir/_relevant_issues.json"
    jq -s '.' < "$relevant_file" > "$relevant_issues_file"
    local rel_count
    rel_count=$(jq 'length' < "$relevant_issues_file")
    if [[ "$rel_count" -gt 0 ]]; then

      if ! jq \
        --arg pkg "$name" \
        --arg inst "$version" \
        --arg latest "$latest_samemaj_ver" \
        --arg abs_latest "$latest_abs_ver" \
        --slurpfile issues "$relevant_issues_file" \
        '. + [{
          package: $pkg,
          installed_version: $inst,
          latest_available: $latest,
          absolute_latest: $abs_latest,
          issues_fixed_in_newer: ($issues[0] | length),
          matched_keywords: ([ $issues[0][].matched_keywords[] ] | unique),
          details: [ $issues[0][] | {
            release_note_id: .release_note_id,
            fix_version: .fix_version,
            keywords: .matched_keywords,
            snippet: .release_notes_snippet
          }]
        }]' < "$recommendations_file" > "$recommendations_file.tmp" 2>/dev/null; then
        warn "jq recommendation-append failed for ${name}"
      else
        mv "$recommendations_file.tmp" "$recommendations_file"
      fi
    fi
  done < "$pkg_list_file"

  if ! jq '[.[] | objects | select(has("package"))] | sort_by(.package)' < "$recommendations_file" > "$recommendations_file.tmp" 2>/dev/null; then
    warn "jq sort recommendations failed, using unsorted"
  else
    mv "$recommendations_file.tmp" "$recommendations_file"
  fi
  local rec_count
  rec_count=$(jq 'length' < "$recommendations_file")

  # -- Step 7: Build full report JSON -------------------------------------------
  jq -n \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg root "$APP_ROOT" \
    --arg deps "$(basename "$deps_file")" \
    --slurpfile installed "$packages_file" \
    --slurpfile latest_same_major "$latest_samemaj_file" \
    --slurpfile latest_absolute "$latest_versions_file" \
    --slurpfile recommendations "$recommendations_file" \
    --argjson total_issues "$issue_count" \
    '{
      generated_at: $date,
      app_root: $root,
      deps_file: $deps,
      installed_package_count: ($installed[0] | length),
      packages_with_issues: ($recommendations[0] | length),
      total_issue_entries: $total_issues,
      installed_packages: $installed[0],
      latest_versions_same_major: $latest_same_major[0],
      latest_versions_absolute: $latest_absolute[0],
      recommendations: $recommendations[0]
    }' > "$REPORT_FILE"

  # -- Final results table -----------------------------------------------------
  echo "  RESULTS: $issue_count release notes matched keywords"
  echo ""

  printf "  %-40s %-14s %-14s %-16s %s\n" \
    "PACKAGE" "INSTALLED" "LATEST" "DELTA" "ISSUES FOUND"
  printf "  %-40s %-14s %-14s %-16s %s\n" \
    "-------" "---------" "------" "-----" "------------"

  while IFS= read -r pkg_entry; do
    local name version
    name=$(echo "$pkg_entry" | jq -r '.name')
    version=$(echo "$pkg_entry" | jq -r '.version')

    local latest_ver
    latest_ver=$(jq -r --arg n "$name" '.[$n] // "unknown"' < "$latest_samemaj_file")

    local delta
    delta=$(version_delta "$version" "$latest_ver")

    local kws
    kws=$(jq -r --arg n "$name" '
      [.[] | objects | select((.package // "") == $n)] |
      if length > 0 then .[0].matched_keywords | join(", ") else "" end
    ' < "$recommendations_file" 2>/dev/null) || kws=""
    [[ -z "$kws" ]] && kws="(none)"

    printf "  %-40s %-14s %-14s %-16s %s\n" "$name" "$version" "$latest_ver" "$delta" "$(highlight_kw "$kws")"

    # -- NuGet feed link (--notes only) ------------------------------------
    if [[ "$SHOW_NOTES" == "true" ]]; then
      local lower_pkg
      lower_pkg=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
      printf "    Url: %s\n\n" "https://nuget.optimizely.com/packages/${lower_pkg}/${latest_ver}"
    fi

    # -- Inline notes: all release notes between installed and latest (--notes only)
    if [[ "$SHOW_NOTES" == "true" && "$latest_ver" != "unknown" && "$version" != "$latest_ver" ]]; then
      local found_notes=false
      local name_fam
      name_fam=$(pkg_family "$name")
      while IFS=$'\t' read -r nid pkg ver desc; do
        # Match by product family (first two dot-segments)
        local pkg_fam
        pkg_fam=$(pkg_family "$pkg")
        if [[ "$pkg" != "$name" && "$pkg_fam" != "$name_fam" ]]; then
          continue
        fi
        [[ -z "$ver" ]] && continue
        # Show entries where: fix_version > installed AND fix_version <= latest
        if semver_gt "$ver" "$version" && semver_gte "$latest_ver" "$ver"; then
          local line="    [${ver}] ${nid} ${desc}"
          local width=100
          while [[ ${#line} -gt $width ]]; do
            local chunk="${line:0:$width}"
            local brk=${#chunk}
            local tmp="${chunk% *}"
            [[ "$tmp" != "$chunk" ]] && brk=${#tmp}
            printf '%s\n' "$(highlight_kw "${line:0:$brk}")"
            line="      ${line:$brk}"
            line="${line#"${line%%[! ]*}"}"
            line="      $line"
          done
          printf '%s\n' "$(highlight_kw "$line")"
          printf "    Url: %s\n\n" "https://world.optimizely.com/documentation/Release-Notes/ReleaseNote/?releaseNoteId=$nid"
          found_notes=true
        fi
      done < "$db_file"
      [[ "$found_notes" == "true" ]] && echo ""
    fi
  done < "$pkg_list_file"

  echo ""
  echo "  ----------------------------------------------------------------------"
  echo "  Total packages scanned:       $pkg_count"
  echo "  Packages with issues:         $rec_count"
  echo "  Release notes matched:        $issue_count"

  if [[ ${#newer_major_notes[@]} -gt 0 ]]; then
    echo ""
    echo "  Newer major versions available:"
    for note in "${newer_major_notes[@]}"; do
      echo "$note"
    done
  fi

  echo ""
  echo "  Report:       $REPORT_FILE"
  echo "  Known issues: $KNOWN_ISSUES_FILE"
  echo "======================================================================"
}

[[ "${__TESTING:-}" == "1" ]] || main
