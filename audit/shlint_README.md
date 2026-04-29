# shlint.sh - Bash Hygiene & Static Analysis Orchestrator

## Application Overview and Objectives

`shlint.sh` is a utility designed to enforce coding standards and maintain structural integrity across shell-based automation ecosystems.

### Core Objectives:
*   **Structural Standardization:** Enforce a uniform indentation and formatting style using `shfmt`, ensuring codebase consistency.
*   **Defensive Programming:** Utilize `shellcheck` to identify semantic errors, logical bugs, and POSIX/Bash-specific antipatterns.
*   **Workflow Integration:** Provide a simple entry point to validate script health before deployment.
*   **Transparency:** Abstract the complexity of underlying tool configurations into a simple, predictable interface.

---

## Architecture and Design Choices

The utility follows a **Fail-Fast Wrapper Architecture**, prioritizing validation before execution to prevent unnecessary processing or destructive formatting on non-target files.

### Design Principles:
1.  **Idempotency:** The script can be run multiple times on the same target without unintended side effects (outside of the initial formatting correction).
2.  **Modular Dependency Integration:** Instead of re-implementing formatting or linting logic, `shlint.sh` leverages industry-standard binaries (`shfmt` and `shellcheck`), focusing on the *orchestration* and *configuration* of these tools.
3.  **Strict File Scoping:** To prevent accidental corruption of configuration files or binaries, the script enforces a `.sh` extension requirement, ensuring it only operates on intended shell scripts.
4.  **Operational Simplicity:** Minimalist CLI design ensures zero learning curve for systems engineers while providing maximum utility.
5.  **Multi-Target and Directory Support:** Dynamically handles single files, spaced lists of files, and recursive directory scanning out-of-the-box.
6.  **Interpreter Safety:** Implements self-awareness (`shlint.sh` skips itself) to prevent runtime byte-offset crashes caused by in-place formatting during execution.

---

## Data Flow and Control Logic

The operational flow uses a robust target loop that resolves arguments into actionable files, performs the formatting/linting operations, and aggregates failures into a global exit status.

### Mermaid Flow Diagram

```mermaid
graph TD
    A([Start]) --> B{Input targets provided?}
    B -- No --> C[[Display Usage & Exit 1]]
    B -- Yes --> D[Initialize GLOBAL_EXIT=0]
    
    D --> E[Iterate Targets]
    E --> F{Is Target a Directory?}
    
    F -- Yes --> G[Find *.sh files recursively]
    G --> H[Process each file]
    
    F -- No --> I{Is Target a File?}
    I -- Yes --> H
    I -- No --> J[Log Warning & Skip]
    
    H --> K{Extension == .sh?}
    K -- No --> L[Log Warning & Skip]
    K -- Yes --> M{Is file shlint.sh?}
    
    M -- Yes --> N[Log Warning & Skip]
    M -- No --> O[Execute shfmt]
    
    O -- Fail --> P[Set GLOBAL_EXIT=2]
    O -- Success --> Q[Execute shellcheck -x]
    
    Q -- Fail --> P
    Q -- Success --> R{More targets/files?}
    
    J --> R
    L --> R
    N --> R
    P --> R
    
    R -- Yes --> E
    R -- No --> S([Exit GLOBAL_EXIT])
```

### Control Logic Details:
*   **Discovery Phase:** The script uses `find` to recursively locate `*.sh` scripts when a directory is passed, handling spaces safely via `print0`.
*   **Validation Phase:** The script verifies existence and content via `[[ -s "$file" ]]`, confirms the extension, and explicitly prevents recursive self-formatting.
*   **Mutation Phase:** `shfmt` is invoked with `-w` (write), applying specific organizational tokens:
    *   `-i 2`: 2-space indentation (Industry standard for readability).
    *   `-ci`: Indented case patterns for logical separation in switch blocks.
    *   `-sr`: Space after redirects for visual clarity in I/O operations.
*   **Analysis Phase:** `shellcheck` is run with the `-x` flag, allowing the analyzer to follow `source` and `.` commands to validate the full dependency tree of the script.

---

## Dependencies

To maintain its operational capabilities, `shlint.sh` requires the following modules to be present in the system's `PATH`:

| Dependency | Purpose | Source/Provider |
| :--- | :--- | :--- |
| **Bash** (4.0+) | Execution environment for the orchestrator. | GNU Project |
| **shfmt** | Lexical analysis and source code formatting. | [mvdan/sh](https://github.com/mvdan/sh) |
| **shellcheck** | Static analysis and bug detection. | [koalaman/shellcheck](https://github.com/koalaman/shellcheck) |

---

## Command Line Arguments

The script adheres to a standard UNIX-style multi-argument interface.

| Argument | Type | Description | Default | Mandatory |
| :--- | :--- | :--- | :--- | :--- |
| `$@` | `String (Paths)` | Space-separated list of files or directories to process. | N/A | **Yes** |

### Exit Codes:
*   **0**: Success. All targeted scripts are formatted and pass linting.
*   **1**: Usage Error (No targets provided).
*   **2**: Validation Failure (Format/Lint error on one or more files).

---

## Detailed Examples

### 1. Standard Execution (Single File)
Automating the hygiene of a local script:
```bash
./shlint.sh my_database_backup.sh
```
*Effect: `my_database_backup.sh` is reformatted to 2-space indentation and any logic errors are printed to stdout.*

### 2. Multi-File Execution
Passing multiple explicit files at once:
```bash
./shlint.sh deploy.sh build.sh test.sh
```

### 3. Directory Scanning
Recursively formatting and linting an entire directory:
```bash
./shlint.sh ./src/scripts/
```
*Effect: Automatically locates and processes every `.sh` file within the directory structure.*

### 4. CI/CD Integration (Pipeline)
Incorporating into a build pipeline to block commits with poor hygiene:
```bash
# In a shell executor block
./shlint.sh .
if [ $? -ne 0 ]; then
    echo "Hygiene check failed. Please fix script errors."
    exit 1
fi
```

### 4. Handling Sourced Dependencies
Because `shlint.sh` uses `shellcheck -x`, it will validate external includes:
```bash
# content of main.sh
source ./lib/utils.sh
check_disk_usage
```
Running `./shlint.sh main.sh` will also verify that `utils.sh` exists and contains valid code.
