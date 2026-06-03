# Rust Cache Manager (`rust_cachemgr.sh`)

A lightweight, robust, and safety-critical Bash utility designed to manage, inspect, and purge Rust and Cargo compiler caches. Compatible across **Linux, Cygwin, and MSYS2**.

---

## 1. Application Overview and Objectives

Compiling Rust applications builds a massive volume of cache objects, spanning:
* Downloaded `.crate` package archives.
* Extracted package source files.
* Git repository checkouts and indexing databases.
* Shared compiler cache objects (`sccache`).
* Incremental compilation and workspace-local build artifacts (`target/`).

On busy developer workstations or continuous integration (CI/CD) environments, these caches can quickly grow to tens or hundreds of gigabytes, exhausting disk space.

### Key Objectives:
* **Deep Visibility:** Provide structured reporting on size and count of cache artifacts.
* **Safety First:** Prevent compilation failures by aborting if a build is actively running.
* **Targeted Cleanup:** Avoid redundant downloads by allowing offline-safe source-only purging.
* **Automation Ready:** Native JSON output and lockfile protection for automated cron-jobs.

---

## 2. Architecture and Design Choices

* **Atomic Deletions:** Deletes directories as a unit (`rm -rf "$dir" && mkdir -p "$dir"`) instead of using wildcard parameters (`rm -rf $dir/*`). This prevents disastrous execution paths if variables resolve to empty strings.
* **POSIX Normalization:** Dynamically resolves Windows paths to standard Unix paths on Cygwin/MSYS2 using the native `cygpath` utility, failing back to standard string replacements elsewhere.
* **Self-Healing Concurrency Lock:** Writes the current process ID (`$$`) to a local lockfile. If the script detects a lock from a previous crashed run, it checks the process table to see if that PID is still active; if the process is dead, the script clears the lock automatically.
* **No-Dependency Design:** Implemented completely in pure Bash using standard GNU/POSIX system utilities (`find`, `du`, `grep`, `sed`), making it zero-dependency and fast.

---

## 3. Data Flow and Control Logic

### Data Flow Diagram

```mermaid
graph TD
    Start([Start]) --> ParseArgs[Parse CLI Arguments]
    ParseArgs --> LogRedirect{--log set?}
    
    LogRedirect -- Yes --> InitLog[Redirect stdout/stderr to Log File]
    LogRedirect -- No --> CheckAction{Action selected?}
    InitLog --> CheckAction
    
    CheckAction -- No / --help --> ShowHelp[Display Help Menu] --> ExitSuccess([Exit 0])
    CheckAction -- Yes --> AcquireLock[Acquire Lockfile]
    
    AcquireLock --> CheckLockExist{Lockfile exists & PID active?}
    CheckLockExist -- Yes --> LockAbort[Print Error / Exit 6]
    CheckLockExist -- No --> WriteLock[Write PID to Lockfile & Register Trap]
    
    WriteLock --> CheckActiveProc{Active cargo/rustc processes?}
    CheckActiveProc -- Yes --> SafetyAbort[Print Error / Exit 5]
    CheckActiveProc -- No --> ResolvePaths[Resolve Cargo & Sccache Paths]
    
    ResolvePaths --> ExecAction{Action Type}
    
    ExecAction -- --get-info --> GenStats[Calculate sizes & file counts]
    GenStats --> OutputStats{--json set?}
    OutputStats -- Yes --> PrintJSON[Output structured JSON]
    OutputStats -- No --> PrintText[Output ANSI color text]
    
    ExecAction -- --purge / --clean-src / --prune-targets --> ConfirmPrompt{Interactive Terminal?}
    ConfirmPrompt -- Yes --> PromptUser[Wait for Y/N Confirmation]
    ConfirmPrompt -- No / --json --> SkipPrompt[Proceed to execute deletions]
    
    PromptUser -- Confirmed --> SkipPrompt
    PromptUser -- Aborted --> TrapExit
    
    SkipPrompt --> DeleteCaches[Perform rm -rf / mkdir path resets]
    DeleteCaches --> LogStatus[Print execution report]
    
    PrintJSON --> TrapExit
    PrintText --> TrapExit
    LogStatus --> TrapExit
    
    TrapExit[Trap Signal Triggered] --> CleanupLock[Delete Lockfile] --> ExitSuccess
```

---

## 4. Dependencies

The script relies solely on standard POSIX and GNU system command line tools.

| Dependency | Purpose | Availability |
| :--- | :--- | :--- |
| `bash` | Core interpreter environment (v4.0+) | Standard |
| `du` | Queries disk space consumed by cache directories | GNU Coreutils |
| `find` | Recursively crawls target directories and checks `-mtime` | GNU Findutils |
| `wc` | Counts file objects | POSIX Standard |
| `cygpath` | Resolves Windows drive letter paths (Cygwin/MSYS2 only) | Cygwin / MSYS2 Core |
| `pgrep` / `ps` | Detects running `cargo` and `rustc` compiler processes | Procps-ng / POSIX |

---

## 5. Command Line Arguments

The script processes flags sequentially. Modifying options (`--json`, `--log`) can be placed in any order relative to the main action.

| Argument | Parameter | Type | Default Value | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--get-info` | None | Action Flag | N/A | Evaluates and displays cache sizes, paths, and metadata. |
| `--purge` | None | Action Flag | N/A | Fully wipes global registry caches, git db, sccache, and workspace target folders. |
| `--clean-src` | None | Action Flag | N/A | Wipes only extracted dependency files (`registry/src`). Saves network bandwidth on subsequent runs. |
| `--prune-targets` | `<days>` | Integer | N/A | Cleans local target directories untouched for more than `<days>` days. |
| `--json` | None | Modifier Flag | Disabled (`0`) | Formats output in parseable JSON. Disables interactive prompts. |
| `--log` | `<file_path>` | File Path | N/A | Redirects all output streams to the specified file while printing to console. |
| `-h`, `--help` | None | Info Flag | N/A | Prints the help menu and usage examples. |

---

## 6. Detailed Examples

### 1. Daily Cron Cleanup (Automated)
Run in a background scheduler to prune any project build folder that has been inactive for more than 30 days:
```bash
/opt/scripts/rust_cachemgr.sh --prune-targets 30 --json --log /var/log/rust_prune.log
```

### 2. Manual Crate Cache Shrinking (Without Redownloads)
Clear out extracted package sources to free up gigabytes of space, while keeping the downloaded package archives (`.crate`) so next builds remain offline-safe:
```bash
/opt/scripts/rust_cachemgr.sh --clean-src
```

### 3. Pipeline Cache Reporting
Generate a JSON footprint of the current compilation node's caches to export to telemetry systems:
```bash
/opt/scripts/rust_cachemgr.sh --get-info --json
```

---

## 7. Best Build Practices in Rust

To maximize compile speed, limit cache bloat, and manage disk consumption when compiling multiple projects with high library overlap, implement the following practices:

### 1. Disable Incremental Compilation in Release/Packaging Builds
* **Recommendation:** Set `CARGO_INCREMENTAL=0` in packaging or CI environments.
* **Why:** Incremental compilation splits crates into multiple fragments to speed up small code edits during active debugging. For release builds, packaging, or clean CI pipelines, it provides **no speedup** but generates thousands of small hash files that quickly fragment disk caches and slow down subsequent disk queries.

### 2. Force the Sparse Registry Protocol
* **Recommendation:** Ensure your toolchain utilizes the Sparse protocol. Rust 1.70+ uses it by default, but you can explicitly enforce it:
  ```bash
  export CARGO_REGISTRY_DEFAULT_PROTOCOL=sparse
  ```
* **Why:** The legacy registry system cloned a massive git repository containing metadata for all crates.io crates, bloating local `.cargo/git` databases to ~500+ MB. The Sparse protocol downloads index data over HTTP only for the specific crates in your dependency tree, reducing the index footprint to <10 MB.

### 3. Use `sccache` for Multi-Project Library Overlap
* **Recommendation:** Install and run `sccache` globally as a compiler wrapper.
  ```bash
  export RUSTC_WRAPPER=sccache
  ```
* **Why:** If multiple projects share foundational crates (e.g. `tokio`, `serde`, `axum`), standard cargo compiles them separately for each project. `sccache` intercepts the compiler call, hashes the inputs, and stores the compiled output globally. If Project B compiles a crate already built by Project A, it hits the global cache, saving up to 80% of compile time.

### 4. Optimize CI/CD Cache Boundaries (Skip Extracted Sources)
* **Recommendation:** When configuring CI runner caching, cache only `~/.cargo/registry/cache` (tarballs) and `~/.cargo/registry/index`. Explicitly exclude `~/.cargo/registry/src`.
* **Why:** The `src` directory contains extracted source directories of crates. Compiling is fast when Cargo re-extracts `.crate` tarballs locally, but compressing and uploading millions of small extracted source files during CI cache archiving dramatically slows down CI pipeline run times.

### 5. Tune Cargo Profile Optimizations for Size vs Compile Time
* **Recommendation:** Fine-tune your `Cargo.toml` release profile depending on goals:
  * For minimal size: `opt-level = "z"`, `strip = true`, `lto = true`, `codegen-units = 1`.
  * For fastest compiles: Keep `codegen-units = 16`, disable `lto`, set `opt-level = 2`.
* **Why:** LTO (Link-Time Optimization) and reducing codegen units to 1 forces the compiler to run single-threaded global optimization. It results in extremely small, optimized binaries, but significantly increases compile time.

### 6. Clean Up Stale Workspace Builds Automatically
* **Recommendation:** Automate the execution of `--prune-targets <days>` using a system scheduler to wipe `target/` directories of workspaces untouched for more than 14-30 days.
* **Why:** Workspace `target/` directories can easily swell to several gigabytes due to debug symbols and build scripts. Keeping inactive workspaces cached wastes precious SSD disk space.

### 7. Evict Unused Dependencies (`cargo-machete`)
* **Recommendation:** Run `cargo-machete` in your projects before building to detect and remove unused dependencies declared in `Cargo.toml`.
* **Why:** Unused dependencies still force Cargo to download, index, and resolve their metadata, unnecessarily growing your local registry caches and slowing down the initial resolver step.

---

## 8. Cache Management Optimizations

Detailed explanations of the benefits, design motivations, and use-cases for the selective caching modes:

### 1. Selective Crate Source Purge (`--clean-src`)

#### **The Problem It Solves:**
When Cargo builds dependencies, it downloads compressed package files (`.crate` tarballs) and stores them in `registry/cache`. It then extracts them into raw source folders under `registry/src` to compile them. Because open-source crates contain thousands of tiny files, the extracted `src` folder consumes **80% to 90% of the global Cargo cache's size and file allocation indexes (inodes)**.

#### **Design Motivation & Benefits:**
* **Wipe Boundary:** Wipes out **only** the unzipped source code folders (`registry/src`) but leaves the compressed `.crate` downloads (`registry/cache`) untouched.
* **Disk Savings:** Reclaims almost all the disk space occupied by the registry index.
* **Network Independence (Offline Safe):** Unlike a full registry purge (`--purge`), Cargo **does not need the internet** to compile on the next run. It will simply unzip the cached `.crate` files locally in milliseconds.

#### **When to Use:**
* **Developer Workstations:** Run this when your hard drive is getting full but you want to ensure your next build stays offline-safe and fast.
* **CI/CD Build Runners:** Run this at the end of a build pipeline *before* saving/uploading the runner's global cache archive. This dramatically reduces the cache size and upload/download times for the next pipeline runs.

### 2. Time-Based Project Target Pruning (`--prune-targets <N>`)

#### **The Problem It Solves:**
Local build directories (`target/`) contain compiled binaries, intermediate objects, and debug symbols. For modern Rust projects, a single `target/` directory can easily grow to **2 GB – 10 GB**. If you have dozens of Rust projects sitting on your disk, you are likely wasting 50+ GB of SSD space on projects you haven't opened in months.

#### **Design Motivation & Benefits:**
* **Recrawl Discovery:** Scans recursively under your current path to find all `target/` folders.
* **Mtime Integrity:** Analyzes the modification times (`-mtime`) of all compiled files in each folder.
* **Selective Wiping:** If a project has **not** been compiled or edited within the last `N` days (e.g., 14 days), the entire `target/` directory is wiped. Active projects are left completely alone.
* **Preserves Compilation Speed:** Active projects retain their cache, keeping recompilations instant, while dead projects release their SSD space.

#### **When to Use:**
* **Automated Cron Jobs:** Set up a cron job (or an orchestrator trigger) to run this once a week on developer machines to prevent disk space leaks from abandoned projects.
* **Shared Build Servers:** Run this on shared RPM build nodes to clear out compile artifacts for older versions of packages while keeping active release versions fast.

