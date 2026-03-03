#!/usr/bin/env bash
# test_nugetchk.sh - Functional tests for nugetchk.sh
# Usage: bash test/test_nugetchk.sh

set -uo pipefail

# =============================================================================
# Test Harness
# =============================================================================
PASS=0
FAIL=0
TOTAL=0
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    printf "${GREEN}  PASS${RESET} %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "${RED}  FAIL${RESET} %s\n" "$label"
    printf "       expected: %s\n" "$expected"
    printf "       actual:   %s\n" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local expected="$1" label="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local actual=$?
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq "$expected" ]]; then
    printf "${GREEN}  PASS${RESET} %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "${RED}  FAIL${RESET} %s\n" "$label"
    printf "       expected exit: %s\n" "$expected"
    printf "       actual exit:   %s\n" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf "${GREEN}  PASS${RESET} %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "${RED}  FAIL${RESET} %s\n" "$label"
    printf "       expected to contain: %s\n" "$needle"
    printf "       actual: %s\n" "${haystack:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

# =============================================================================
# Setup: source nugetchk.sh in test mode (loads functions, skips main)
# =============================================================================
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"

export __TESTING=1
export APP_ROOT="/dev/null"

# Source the script — this loads all functions without running main()
# shellcheck source=../nugetchk.sh
source "$SCRIPT_DIR/nugetchk.sh"

# Disable errexit that nugetchk.sh activated — tests need to capture exit codes
set +e

# Ensure jq is available (the script's own ensure_jq will handle it)
ensure_jq

echo ""
echo "======================================================================"
echo "  nugetchk.sh - Functional Tests"
echo "======================================================================"

# =============================================================================
# 1. semver_gt
# =============================================================================
echo ""
echo "--- semver_gt ---"

assert_exit 0 "gt: 12.22.9 > 12.10.0" semver_gt "12.22.9" "12.10.0"
assert_exit 1 "gt: 12.10.0 > 12.22.9 is false" semver_gt "12.10.0" "12.22.9"
assert_exit 0 "gt: 13.0.0 > 12.99.99 (major wins)" semver_gt "13.0.0" "12.99.99"
assert_exit 1 "gt: 1.2.3 > 1.2.3 is false (equal)" semver_gt "1.2.3" "1.2.3"
assert_exit 1 "gt: 1.2.3-beta > 1.2.3-alpha is false (pre-release stripped, equal)" semver_gt "1.2.3-beta" "1.2.3-alpha"

# =============================================================================
# 2. semver_gte
# =============================================================================
echo ""
echo "--- semver_gte ---"

assert_exit 0 "gte: 12.10.0 >= 12.10.0 (equal)" semver_gte "12.10.0" "12.10.0"
assert_exit 0 "gte: 12.11.0 >= 12.10.0 (greater)" semver_gte "12.11.0" "12.10.0"
assert_exit 1 "gte: 12.9.0 >= 12.10.0 is false" semver_gte "12.9.0" "12.10.0"

# =============================================================================
# 3. version_delta
# =============================================================================
echo ""
echo "--- version_delta ---"

assert_eq "$(version_delta "12.10.0" "12.22.9")" "+12min, 9pat" "delta: 12.10.0 → 12.22.9"
assert_eq "$(version_delta "12.0.0" "13.0.0")" "+1maj" "delta: 12.0.0 → 13.0.0 (major only)"
assert_eq "$(version_delta "1.0.0" "1.0.0")" "up to date" "delta: equal versions"
assert_eq "$(version_delta "1.0.0" "unknown")" "?" "delta: unknown latest"
assert_eq "$(version_delta "1.0.0" "1.0.5")" "+5pat" "delta: patch only"

# =============================================================================
# 4. pkg_to_world_group
# =============================================================================
echo ""
echo "--- pkg_to_world_group ---"

assert_eq "$(pkg_to_world_group "EPiServer.CMS.Core")" "CMS" "group: EPiServer.CMS.Core → CMS"
assert_eq "$(pkg_to_world_group "EPiServer.Forms")" "CMS" "group: EPiServer.Forms → CMS"
assert_eq "$(pkg_to_world_group "EPiServer.Find")" "Find" "group: EPiServer.Find → Find"
assert_eq "$(pkg_to_world_group "EPiServer.Commerce.Core")" "Commerce" "group: EPiServer.Commerce.Core → Commerce"
assert_eq "$(pkg_to_world_group "Optimizely.Personalization")" "Personalization" "group: Optimizely.Personalization"
assert_eq "$(pkg_to_world_group "Microsoft.Extensions.Logging")" "" "group: non-EPiServer → empty"

# =============================================================================
# 5. extract_packages
# =============================================================================
echo ""
echo "--- extract_packages ---"

SAMPLE_DEPS="$TEST_DIR/sample.deps.json"
if [[ -f "$SAMPLE_DEPS" ]]; then
  pkgs_json=$(extract_packages "$SAMPLE_DEPS" 2>/dev/null)
  pkg_count=$(echo "$pkgs_json" | jq 'length')

  assert_eq "$pkg_count" "4" "extract: finds 4 EPiServer/Optimizely packages"

  has_cms_core=$(echo "$pkgs_json" | jq '[.[] | select(.name == "EPiServer.CMS.Core" and .version == "12.10.0")] | length')
  assert_eq "$has_cms_core" "1" "extract: contains EPiServer.CMS.Core 12.10.0"

  has_msft=$(echo "$pkgs_json" | jq '[.[] | select(.name | test("Microsoft"; "i"))] | length')
  assert_eq "$has_msft" "0" "extract: excludes Microsoft packages"
else
  echo "  SKIP: $SAMPLE_DEPS not found"
fi

# =============================================================================
# 6. scrape_world_release_notes (HTML parser with mocked curl)
# =============================================================================
echo ""
echo "--- scrape_world_release_notes (HTML parser) ---"

SAMPLE_HTML="$TEST_DIR/opti_rn.html"
if [[ -f "$SAMPLE_HTML" ]]; then
  # Mock curl to return local HTML file instead of fetching from web
  curl() {
    # Only intercept the release notes URL, pass everything else through
    local url=""
    for arg in "$@"; do
      if [[ "$arg" == http* ]]; then
        url="$arg"
      fi
    done
    if [[ "$url" == *"world.optimizely.com"* ]]; then
      cat "$SAMPLE_HTML"
      return 0
    fi
    command curl "$@"
  }

  tmp_tsv=$(mktemp)
  trap 'rm -f "$tmp_tsv" "${tmp_tsv}.segments"' EXIT

  scrape_world_release_notes "$tmp_tsv" "EPiServer.CMS.Core" 2>/dev/null

  line_count=$(wc -l < "$tmp_tsv" | tr -d ' ')
  assert_eq "$line_count" "10" "parser: produces 10 TSV entries from fixture"

  # Check first entry has CMS-* ID pattern
  first_id=$(head -1 "$tmp_tsv" | cut -f1)
  if [[ "$first_id" == CMS-* ]]; then
    assert_eq "CMS-prefix" "CMS-prefix" "parser: first entry ID starts with CMS-"
  else
    assert_eq "$first_id" "CMS-*" "parser: first entry ID starts with CMS-"
  fi

  # All entries should have EPiServer.CMS.Core as the package
  pkg_names=$(cut -f2 "$tmp_tsv" | sort -u)
  assert_eq "$pkg_names" "EPiServer.CMS.Core" "parser: all packages are EPiServer.CMS.Core"

  # All versions should start with a digit
  bad_versions=$(cut -f3 "$tmp_tsv" | grep -cv '^[0-9]' || true)
  assert_eq "$bad_versions" "0" "parser: all versions start with a digit"

  # Check specific known IDs are present
  all_ids=$(cut -f1 "$tmp_tsv" | sort)
  assert_contains "$all_ids" "CMS-25731" "parser: contains CMS-25731"
  assert_contains "$all_ids" "CMS-32880" "parser: contains CMS-32880"
  assert_contains "$all_ids" "CMS-32491" "parser: contains CMS-32491"

  # Check specific versions
  v_25731=$(grep "^CMS-25731" "$tmp_tsv" | cut -f3)
  assert_eq "$v_25731" "12.12.0" "parser: CMS-25731 fix version is 12.12.0"

  v_32880=$(grep "^CMS-32880" "$tmp_tsv" | cut -f3)
  assert_eq "$v_32880" "12.21.0" "parser: CMS-32880 fix version is 12.21.0"

  # Remove curl mock
  unset -f curl
else
  echo "  SKIP: $SAMPLE_HTML not found"
fi

# =============================================================================
# 7. Keyword matching (jq logic)
# =============================================================================
echo ""
echo "--- keyword matching ---"

test_notes='[
  {"id": "TEST-001", "pkg": "Pkg.A", "ver": "1.0", "desc": "Fixed a memory leak in the cache layer"},
  {"id": "TEST-002", "pkg": "Pkg.B", "ver": "2.0", "desc": "Fixed performance regression in query engine"},
  {"id": "TEST-003", "pkg": "Pkg.C", "ver": "3.0", "desc": "Fixed a typo in the error message"}
]'

kw_json=$(printf '%s\n' "${KEYWORDS[@]}" | jq -R '.' | jq -s '.')

matched=$(echo "$test_notes" | jq --argjson kws "$kw_json" '
  [.[] |
    . as $entry |
    [$kws[] | . as $kw | select($entry.desc | ascii_downcase | contains($kw))] as $matched |
    select(($matched | length) > 0) |
    {
      package: .pkg,
      release_note_id: .id,
      fix_version: .ver,
      matched_keywords: $matched,
      release_notes_snippet: .desc
    }
  ]
')

match_count=$(echo "$matched" | jq 'length')
assert_eq "$match_count" "2" "keywords: 2 of 3 entries match"

kw_001=$(echo "$matched" | jq -r '[.[] | select(.release_note_id == "TEST-001")][0].matched_keywords | join(", ")')
assert_eq "$kw_001" "memory leak" "keywords: TEST-001 matches 'memory leak'"

kw_003=$(echo "$matched" | jq -r '[.[] | select(.release_note_id == "TEST-003")] | length')
assert_eq "$kw_003" "0" "keywords: TEST-003 (typo fix) does not match"

# =============================================================================
# 8. Integration: HTML parser → keyword matching pipeline
# =============================================================================
echo ""
echo "--- integration: parser → keyword match ---"

if [[ -f "$SAMPLE_HTML" ]]; then
  # Mock curl again
  curl() {
    local url=""
    for arg in "$@"; do
      [[ "$arg" == http* ]] && url="$arg"
    done
    if [[ "$url" == *"world.optimizely.com"* ]]; then
      cat "$SAMPLE_HTML"
      return 0
    fi
    command curl "$@"
  }

  int_tsv=$(mktemp)
  trap 'rm -f "$int_tsv" "${int_tsv}.segments"' EXIT

  scrape_world_release_notes "$int_tsv" "EPiServer.CMS.Core" 2>/dev/null

  # Convert TSV to JSON (same logic as the script)
  all_notes=$(while IFS=$'\t' read -r nid pkg ver desc; do
    [[ -z "$nid" ]] && continue
    printf '%s\n' "$nid"$'\t'"$pkg"$'\t'"$ver"$'\t'"$desc"
  done < "$int_tsv" | jq -R 'split("\t") | {id: .[0], pkg: .[1], ver: .[2], desc: .[3]}' | jq -s '.')

  all_issues=$(echo "$all_notes" | jq --argjson kws "$kw_json" '
    [.[] |
      . as $entry |
      [$kws[] | . as $kw | select($entry.desc | ascii_downcase | contains($kw))] as $matched |
      select(($matched | length) > 0) |
      {
        package: .pkg,
        release_note_id: .id,
        fix_version: .ver,
        matched_keywords: $matched,
        release_notes_snippet: .desc
      }
    ]
  ')

  issue_count=$(echo "$all_issues" | jq 'length')
  assert_eq "$issue_count" "1" "integration: exactly 1 entry matches keywords from fixture HTML"

  matched_id=$(echo "$all_issues" | jq -r '.[0].release_note_id')
  assert_eq "$matched_id" "CMS-32880" "integration: CMS-32880 (thread keyword) is the match"

  matched_kw=$(echo "$all_issues" | jq -r '.[0].matched_keywords | join(", ")')
  assert_eq "$matched_kw" "thread" "integration: matched keyword is 'thread'"

  rm -f "$int_tsv" "${int_tsv}.segments"
  unset -f curl
else
  echo "  SKIP: $SAMPLE_HTML not found"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "======================================================================"
printf "  Results: %d total, ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$TOTAL" "$PASS" "$FAIL"
echo "======================================================================"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
