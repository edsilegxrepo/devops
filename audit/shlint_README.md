# shlint.sh - Bash Hygiene & Static Analysis Orchestrator

## Application Overview and Objectives

`shlint.sh` is a utility designed to enforce coding standards, format consistency, and structural integrity across shell-based automation ecosystems.

### Core Objectives:
*   **Structural Standardization:** Enforce a uniform indentation and formatting style using `shfmt`, ensuring codebase consistency.
*   **Defensive Static Analysis:** Utilize `shellcheck` to identify semantic errors, logical bugs, and POSIX/Bash-specific antipatterns.
*   **Workflow & CI/CD Integration:** Provide explicit, non-destructive check modes (`--check`) for continuous integration pipelines and automated in-place formatting (`--write`) for local development.
*   **Strict Long-Flag Hygiene:** Disables ambiguous single-character short flags across CLI controls to prevent syntax errors and ensure transparent scripting.
*   **Broad Shell Scoping:** Inspects `.sh`, `.bash`, and `.inc` libraries, as well as extensionless scripts with shell shebangs.

---

## Architecture and Design Choices

The utility follows a **Fail-Fast Wrapper Architecture**, prioritizing prerequisite validation and directory pruning before performing formatting or static analysis.

### Design Principles:
1.  **Idempotency:** The script can be run repeatedly on the same target without unintended side effects.
2.  **Modular Dependency Integration:** Leverages industry-standard binaries (`shfmt` and `shellcheck`), focusing on orchestration, safe discovery, and telemetry aggregation.
3.  **Strict Long-Form CLI Controls:** Rejects short options (e.g. `-c`, `-w`, `-h`) with a usage diagnostic to prevent syntax ambiguity in automated pipelines.
4.  **Flexible Shell Scoping:** Validates scripts ending in `.sh`, `.bash`, and `.inc`, and falls back to inspecting shebang headers (`#!/bin/bash` or `#!/bin/sh`) for extensionless executables.
5.  **VCS & Dependency Pruning:** Automatically excludes `.git`, `vendor`, `node_modules`, and `.cache` directories during recursive directory scans.
6.  **Interpreter Safety:** Resolves physical canonical paths (`readlink -f` / `realpath`) to ensure `shlint.sh` safely skips itself and avoids interpreter byte-offset mutation errors.
7.  **Fail-Fast Toolchain Checks:** Audits the availability of both `shfmt` and `shellcheck` in `$PATH` upfront before processing files.

---

## Data Flow and Control Logic

```mermaid
graph TD
    A([Start]) --> B[Check Dependencies: shfmt & shellcheck]
    B -- Missing --> C[[Log Error & Exit 4]]
    B -- Present --> D{Parse CLI Flags}
    
    D -- Short Flag Used --> E[[Log Error & Exit 1]]
    D -- --help --> F[[Display Usage & Exit 0]]
    D -- No Targets --> G[[Display Usage & Exit 1]]
    D -- Valid Options & Targets --> H[Resolve Real SCRIPT_REAL]
    
    H --> I[Iterate Targets]
    I --> J{Is Target a Directory?}
    
    J -- Yes --> K[Find .sh, .bash, .inc - Prune .git, vendor, node_modules]
    K --> L[Process each file]
    
    J -- No --> M{Is Target a File?}
    M -- Yes --> L
    M -- No --> N[Log Warning & Skip]
    
    L --> O{Is Shell Script? .sh, .bash, .inc, or shebang}
    O -- No --> N
    O -- Yes --> P{Is File Self shlint.sh?}
    
    P -- Yes --> Q[Log Warning & Skip]
    P -- No --> R{Mode == --check?}
    
    R -- Yes --> S[Execute shfmt --diff]
    R -- No --> T[Execute shfmt --write]
    
    S -- Drift Detected --> U[Set GLOBAL_EXIT=2]
    T -- Format Error --> U
    S -- Clean --> V[Execute shellcheck --external-sources]
    T -- Formatted --> V
    
    V -- Lint Errors --> U
    V -- Compliant --> W[Log OK Progress]
    
    U --> X{More targets/files?}
    W --> X
    N --> X
    Q --> X
    
    X -- Yes --> I
    X -- No --> Y([Exit GLOBAL_EXIT: 0 or 2])
```

### Control Logic Details:
*   **Dependency Audit:** Verifies `shfmt` and `shellcheck` presence in `$PATH` before filesystem discovery.
*   **Discovery Phase:** The script uses `find` to locate `*.sh`, `*.bash`, and `*.inc` files, pruning `.git/`, `vendor/`, `node_modules/`, and `.cache/`.
*   **Validation Phase:** The script validates file readability, content size (`[[ -s "$file" ]]`), shell script type, and canonical identity against `${BASH_SOURCE[0]}`.
*   **Formatting Phase:**
    *   **In-Place Mode (`--write`):** Executes `shfmt --indent 2 --case-indent --space-redirects --write "$file"`.
    *   **Check Mode (`--check`):** Executes `shfmt --indent 2 --case-indent --space-redirects --diff "$file"`, returning an error without modifying files.
*   **Analysis Phase:** Invokes `shellcheck --external-sources "$file"` to follow sourced dependencies and include files.

---

## Dependencies

To maintain its operational capabilities, `shlint.sh` requires the following modules to be present in the system's `PATH`:

| Dependency | Purpose | Source/Provider |
| :--- | :--- | :--- |
| **Bash** (4.0+) | Execution environment for the orchestrator. | GNU Project |
| **shfmt** | Lexical analysis, syntax formatting, and diff generation. | [mvdan/sh](https://github.com/mvdan/sh) |
| **shellcheck** | Deep static analysis, AST bug detection, and dependency inspection. | [koalaman/shellcheck](https://github.com/koalaman/shellcheck) |

---

## Command Line Arguments

The script enforces an explicit long-flag interface. Short options are prohibited.

| Argument | Type | Description | Default | Mandatory |
| :--- | :--- | :--- | :--- | :--- |
| `--write` | Flag | Format files in-place and run static analysis. | **Yes** (default) | No |
| `--check` | Flag | Read-only verification mode (prints format diffs, exits non-zero on drift). | No | No |
| `--help` | Flag | Displays syntax, options, and operational manual. | No | No |
| `<target...>` | `Paths` | Space-separated list of files or directories to process. | N/A | **Yes** |

### Exit Codes:
*   **0**: Success. All targeted scripts are formatted and compliant.
*   **1**: Usage Error (No targets provided, unknown options, or short flags used).
*   **2**: Validation Failure (Formatting drift or shellcheck linting failure).
*   **4**: Missing Dependency (`shfmt` or `shellcheck` not found in `PATH`).

---

## Detailed Examples

### 1. Standard In-Place Formatting & Linting (Local Development)
Automating the hygiene of a local script:
```bash
./shlint.sh my_database_backup.sh
```
*Effect: Formats `my_database_backup.sh` to 2-space indentation with case-block and redirect spacing, then runs shellcheck.*

### 2. CI/CD Pipeline Verification (Read-Only Check Mode)
Enforcing formatting and linting in continuous integration without dirtying git working trees:
```bash
./shlint.sh --check .
if [ $? -ne 0 ]; then
    echo "Hygiene check failed. Please format scripts using './shlint.sh --write <path>'."
    exit 1
fi
```
*Effect: Recursively checks all shell scripts in `.`. If formatting differences or shellcheck warnings exist, reports diffs and exits with code 2.*

### 3. Multi-File and Include File Execution
Inspecting multiple files including shared `.inc` libraries:
```bash
./shlint.sh build_go.sh build.inc deploy.sh
```

### 4. Recursive Directory Scanning with VCS Pruning
Scanning an entire project tree while automatically ignoring `.git/` and `vendor/`:
```bash
./shlint.sh --write ./scripts/
```

### 5. Short Flag Rejection
Attempting to use short flags triggers a clear diagnostic:
```bash
./shlint.sh -c build.sh
# ERROR: Short flag '-c' is not permitted. Short flags are disabled to prevent errors. Use long options: --check, --write, --help.
```
