# optinugetchk

EPiServer/Optimizely NuGet Package Health Checker — a self-contained bash script designed to run directly on **Azure App Service Linux** via Kudu SSH. It scans your deployed application's installed packages, compares them against the Optimizely NuGet feed, and surfaces release notes that mention memory, performance, or stability issues.

---

## Features

- **Zero install** — only requires `bash` and `curl` (both present on Azure App Service Linux); downloads `jq` automatically if missing
- **Installed version detection** — reads directly from your app's `.deps.json`; no build tools required
- **Latest version lookup** — queries `nuget.optimizely.com` for the latest same-major and absolute-latest versions per package
- **Release notes scraping** — fetches release notes from `world.optimizely.com` at runtime and scans for keywords related to memory leaks, performance, timeouts, deadlocks, and more
- **Release notes cache** — scraped notes are saved to a zip file named after your app; subsequent runs prompt to reuse the cache or refresh, making re-runs fast
- **Keyword highlighting** — matched keywords are highlighted in bright yellow in the terminal output
- **Word-wrapped notes** (`--notes`) — shows every release note between your installed version and latest, with URLs, word-wrapped at 100 columns
- **JSON report** — writes `nugetchk_report.json` and `known_issues.json` next to the script for further processing

---

## Quick Start (Azure App Service Linux — Kudu SSH)

One-liner to download and run directly on your App Service:

```bash
curl -fsSL https://raw.githubusercontent.com/jeff-fischer-optimizely/optinugetchk/master/nugetchk.sh | bash
```

To also show all release notes between your installed and latest versions:

```bash
curl -fsSL https://raw.githubusercontent.com/jeff-fischer-optimizely/optinugetchk/master/nugetchk.sh | bash -s -- --notes
```

---

## Usage

```
bash nugetchk.sh [--notes] [--debug] [app_root_path]
```

| Option | Short | Description |
|---|---|---|
| `--notes` | `-n` | Show all release note summaries between installed and latest version |
| `--debug` | `-d` | Emit verbose diagnostic output to stderr |
| `app_root_path` | | Path to your app root (default: `/home/site/wwwroot`) |

### Examples

```bash
# Basic scan — results table with keyword-matched issues
bash nugetchk.sh

# Full notes — every release note between installed and latest
bash nugetchk.sh --notes

# Scan a specific app directory
bash nugetchk.sh /home/site/wwwroot/myapp

# Full notes for a specific path
bash nugetchk.sh --notes /home/site/wwwroot/myapp

# Verbose diagnostic output
bash nugetchk.sh --debug 2>debug.log
```

---

## Output

### Results table (always shown)

```
  PACKAGE                                  INSTALLED      LATEST         DELTA            ISSUES FOUND
  -------                                  ---------      ------         -----            ------------
  EPiServer.CMS.Core                       12.22.1        12.23.1        +1min            slow, thread
  EPiServer.CMS.AspNetCore                 12.22.1        12.23.1        +1min            (none)
  EPiServer.Commerce.Core                  14.34.0        14.45.1        +11min           (none)
```

- **DELTA** — version distance from installed to latest same-major (`+Nmaj`, `+Nmin`, `+Npat`, or `up to date`)
- **ISSUES FOUND** — keywords matched in release notes; highlighted in yellow when a match is found

### Release notes (`--notes`)

When `--notes` is specified, each package entry also shows:

```
  EPiServer.CMS.Core                       12.22.1        12.23.1        +1min            slow, thread
    Url: https://nuget.optimizely.com/packages/episerver.cms.core/12.23.1

    [12.23.0] CMS-29994 Fixed slow query performance when loading content
    Url: https://world.optimizely.com/documentation/Release-Notes/ReleaseNote/?releaseNoteId=CMS-29994

    [12.22.8] CMS-30098 Resolved thread contention issue under high load
    Url: https://world.optimizely.com/documentation/Release-Notes/ReleaseNote/?releaseNoteId=CMS-30098
```

### Summary footer

```
  Total packages scanned:       62
  Packages with issues:         3
  Release notes matched:        7

  Newer major versions available:
    * EPiServer.Find: v17.0.1 available (current major: 16)

  Report:       /path/to/nugetchk_report.json
  Known issues: /path/to/known_issues.json
```

---

## How It Works

1. **Locate** — finds the first `*.deps.json` in the current directory, script directory, or app root
2. **Extract** — parses all `EPiServer.*` and `Optimizely.*` package names and versions from the deps file
3. **Query** — fetches latest same-major and absolute-latest versions from `nuget.optimizely.com` for each package
4. **Scrape** — fetches release notes from `world.optimizely.com` using `?packageFilter=<PackageName>` per package, with automatic parent-name fallback (e.g. `EPiServer.Forms.Core` → `EPiServer.Forms`) and deduplication across related packages in the same product family; results are cached to a zip file for fast re-runs
5. **Match** — scans each release note description for keywords (memory leak, performance, timeout, deadlock, etc.)
6. **Report** — renders the results table and writes JSON report files

## Release Notes Cache

After scraping, the raw release notes are saved to a zip file next to the script, named after your application:

```
MyApp_nugetchk_notes.zip
```

On subsequent runs, if the zip exists you are prompted:

```
  Cached release notes found: MyApp_nugetchk_notes.zip (2026-03-02 14:35)
  Refresh? [y/N]
```

- Press **Enter** or **N** — loads from the zip instantly (no network calls for scraping)
- Press **Y** — re-scrapes from `world.optimizely.com` and overwrites the cache

When run non-interactively (e.g. from a script), the cache is used silently without prompting. Requires `zip`/`unzip` to be available; gracefully falls back to scraping every time if they are not.

### Keywords scanned

| Keyword |
|---|
| memory leak |
| out of memory |
| high memory |
| performance |
| slow |
| timeout |
| deadlock |
| thread |
| cpu |

> **Note:** The `world.optimizely.com` release notes site was frozen in May 2024 and is no longer updated. Packages on versions released after that date will not have release notes available from this source.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| `bash` 4+ | Pre-installed on Azure App Service Linux |
| `curl` | Pre-installed on Azure App Service Linux |
| `jq` | Downloaded automatically if not found |

---

## Output Files

Both files are written next to the script:

| File | Description |
|---|---|
| `nugetchk_report.json` | Full report: all installed packages, latest versions, and recommendations |
| `known_issues.json` | Keyword-matched release note entries only |
| `<AppName>_nugetchk_notes.zip` | Cached release notes TSV; reused on subsequent runs to skip scraping |

---

## Running Tests

The test suite requires `bash` and `jq`:

```bash
bash test/test_nugetchk.sh
```

37 functional tests covering semver comparison, version delta, HTML parsing, and keyword matching.

---

## License

MIT
