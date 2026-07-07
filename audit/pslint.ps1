<#
.SYNOPSIS
    PowerShell Linter Wrapper for PSScriptAnalyzer.

.DESCRIPTION
    A utility to provide an interface for PSScriptAnalyzer, centralizing configuration,
    managing dependencies, and supporting both interactive and pipeline-based usage.

    CORE COMPONENTS:
    1. Parameter Initialization: Flexible input handling for files and directories.
    2. Dependency Tier (begin block): Self-healing logic that verifies and installs PSScriptAnalyzer.
    3. Configuration Tier (begin block): Dynamic discovery of repository settings (PSScriptAnalyzerSettings.psd1).
    4. Execution Tier (process block): Orchestration of Audit and Auto-Fix passes with detailed reporting.

    FUNCTIONALITY & DATA FLOW:
    - Input: Accepts paths via -Path parameter or pipeline.
    - Setup: Verifies environment once per execution.
    - Execution: Iterates over resolved paths, applies repo-wide rules, and generates diagnostics.
    - Output: Streams results to console and returns standardized exit codes for CI/CD.

    DEPENDENCY INSTALLATION:
    PSScriptAnalyzer and NuGet provider are installed automatically if missing.
    Installation scope depends on execution context:
    - Administrator: Installs to AllUsers (C:\Program Files\...) - available to all users
    - Non-Administrator: Installs to CurrentUser (%LOCALAPPDATA%\...) - current user only

    For global installation, run once as Administrator:
        .\pslint.ps1 -CheckLinter

    EXIT CODES:
    0 - Success: No issues found, or only warnings/info (without -Strict)
    1 - Errors: PSScriptAnalyzer detected Error-severity issues
    2 - Warnings: PSScriptAnalyzer detected warnings (with -Strict mode)
    3 - Syntax: PowerShell syntax errors prevented analysis
    4 - Dependency: PSScriptAnalyzer installation or import failed
    5 - Input: Invalid path, no files found, or execution error

    SUPPORTED FILE TYPES:
    - .ps1  - PowerShell scripts
    - .psm1 - PowerShell modules
    - .psd1 - PowerShell module manifests

.PARAMETER Path
    The path to a PowerShell script (.ps1), module (.psm1), manifest (.psd1), or directory to be analyzed.
    Supports string arrays, pipeline input, and wildcards. When a directory is specified, all supported
    file types in that directory are scanned (use -Recursive to include subdirectories).

.PARAMETER Recursive
    If specified, recursively processes all PowerShell files (.ps1, .psm1, .psd1) in the target directory
    and all subdirectories.

.PARAMETER Strict
    If specified, treats Warnings as Errors. The script exits with code 1 if any warnings are found.
    Recommended for PR gates and build pipelines to enforce zero-warning policy.

.PARAMETER Fix
    Enables Auto-Fix Mode. Attempts to automatically remediate common issues (formatting, aliases) in-place.
    WARNING: This modifies files directly. Review changes with version control after running.

.PARAMETER ExcludeRule
    A list of specific PSScriptAnalyzer rule names to exclude from this run.
    Example: -ExcludeRule PSAvoidUsingWriteHost, PSUseSingularNouns

.PARAMETER RuntimeInfo
    Displays diagnostic information about the current PowerShell runtime including:
    PSVersion, PSEdition, OS, executable path, process ID, host info, and execution policy.
    Useful for debugging environment issues.

.PARAMETER ListModules
    Lists all PowerShell modules available in the current environment.
    Useful for verifying PSScriptAnalyzer installation and version.

.PARAMETER CheckLinter
    Standalone action to verify and install PSScriptAnalyzer without running analysis.
    Useful for CI/CD setup steps or initial environment provisioning.

.PARAMETER Version
    Displays the current version of the PSLint utility and exits. Alias: -v

.PARAMETER Help
    Displays this help documentation and exits. Aliases: -h, -?

.PARAMETER OutputFormat
    Output format: 'Text' (default) for human-readable console output with colors,
    or 'Json' for machine-readable JSON output suitable for CI/CD pipelines and tooling.
    When using Json, all informational messages are suppressed - only the JSON result is written.

.PARAMETER Quiet
    Suppress all informational messages (INFO, settings path). Only shows results and errors.
    Useful for cleaner CI/CD output. Alias: -q

.PARAMETER IncludeRule
    A list of specific PSScriptAnalyzer rule names to include. When specified, ONLY these rules
    are run, ignoring all others. Useful for focused checks (e.g., security-only scan).

.EXAMPLE
    .\pslint.ps1 -CheckLinter
    Verify PSScriptAnalyzer is installed (installs if missing).

.EXAMPLE
    .\pslint.ps1 -Path .\src\
    Lint all PowerShell files in the src directory (non-recursive).

.EXAMPLE
    .\pslint.ps1 -Path .\src\ -Recursive
    Lint all PowerShell files in src and all subdirectories.

.EXAMPLE
    .\pslint.ps1 -Path .\src\ -Recursive -Strict
    Lint recursively and fail on any warnings (CI/CD gate mode).

.EXAMPLE
    .\pslint.ps1 -Path .\src\ -Fix
    Auto-fix common issues in all files in the src directory.

.EXAMPLE
    Get-ChildItem -Filter *.ps1 | .\pslint.ps1 -Strict
    Pipeline input: lint specific files from a git diff or custom filter.

.EXAMPLE
    .\pslint.ps1 -Path .\src\ -ExcludeRule PSAvoidUsingWriteHost
    Lint while ignoring a specific rule.

.EXAMPLE
    .\pslint.ps1 -RuntimeInfo -ListModules
    Display environment diagnostics without linting.

.EXAMPLE
    .\pslint.ps1 -Path .\src\ -Recursive -OutputFormat Json
    Output results as JSON for CI/CD pipeline consumption.

.EXAMPLE
    .\pslint.ps1 -Path .\src\ -OutputFormat Json | ConvertFrom-Json | Select-Object -ExpandProperty summary
    Parse JSON output in PowerShell for programmatic access.

.INPUTS
    System.String[]
    File or directory paths can be piped to the -Path parameter.

.OUTPUTS
    Text mode: Console output with colored diagnostics.
    Json mode: Single JSON object with version, exitCode, summary, and files array.
    Exit codes: 0=success, 1=errors, 2=warnings(strict), 3=syntax, 4=dependency, 5=input.

.NOTES
    Version:        1.1.0
    Author:         Infrastructure Team
    Requires:       PowerShell 5.1+
    Dependencies:   PSScriptAnalyzer (auto-installed)

    The script searches for PSScriptAnalyzerSettings.psd1 in:
    1. Script directory ($PSScriptRoot)
    2. Parent of script directory
    3. Current working directory ($PWD)

.LINK
    https://github.com/PowerShell/PSScriptAnalyzer
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "Quiet")]
param(
    [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true)]
    [Alias("FilePath")]
    [string[]]$Path,

    [Parameter(Mandatory = $false)]
    [switch]$Recursive,

    [Parameter(Mandatory = $false)]
    [switch]$Strict,

    [Parameter(Mandatory = $false)]
    [switch]$Fix,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeRule,

    [Parameter(Mandatory = $false)]
    [switch]$RuntimeInfo,

    [Parameter(Mandatory = $false)]
    [switch]$ListModules,

    [Parameter(Mandatory = $false)]
    [switch]$CheckLinter,

    [Parameter(Mandatory = $false)]
    [Alias('v')]
    [switch]$Version,

    [Parameter(Mandatory = $false)]
    [Alias('h', '?')]
    [switch]$Help,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text',

    [Parameter(Mandatory = $false)]
    [Alias('q')]
    [switch]$Quiet,

    [Parameter(Mandatory = $false)]
    [string[]]$IncludeRule
)

#region Initialization

# --- INITIALIZATION TIER ---
# The begin block runs once before processing any pipeline input.
# Responsibilities:
#   1. Handle early-exit flags (-Version, -Help)
#   2. Initialize script-scoped state variables
#   3. Display diagnostic information if requested (-RuntimeInfo, -ListModules)
#   4. Discover PSScriptAnalyzerSettings.psd1 configuration file
#   5. Verify/install PSScriptAnalyzer dependency
begin {
    # Strict mode catches common coding errors: uninitialized variables, invalid property access
    Set-StrictMode -Version Latest

    # Version constant - update this when releasing new versions
    $PSLintVersion = "1.1.0"

    # Exit code constants for granular CI/CD feedback
    # Using script scope so they're accessible in process/end blocks
    $script:EXIT_SUCCESS = 0  # No issues, or warnings/info without -Strict
    $script:EXIT_ERRORS = 1  # PSScriptAnalyzer Error-severity findings
    $script:EXIT_WARNINGS = 2  # PSScriptAnalyzer warnings (with -Strict)
    $script:EXIT_SYNTAX = 3  # PowerShell syntax errors (unparseable)
    $script:EXIT_DEPENDENCY = 4  # PSScriptAnalyzer install/import failed
    $script:EXIT_INPUT = 5  # Invalid path, no files, or execution error

    # JSON output mode: collect all results for final output
    $script:JsonMode = ($OutputFormat -eq 'Json')
    $script:JsonResult = @{
        version = $PSLintVersion
        timestamp = (Get-Date -Format "o")
        exitCode = 0
        exitName = "Success"
        summary = @{ errors = 0; warnings = 0; info = 0; total = 0 }
        files = @()
    }

    # Helper function: Write output only in Text mode (respects -Quiet for INFO messages)
    function Write-TextOutput {
        param(
            [string]$Message,
            [string]$ForegroundColor,
            [switch]$IsInfo  # Set for INFO-level messages that -Quiet suppresses
        )
        if (-not $script:JsonMode) {
            # -Quiet suppresses INFO messages but not results/errors
            if ($IsInfo -and $Quiet) { return }
            if ($ForegroundColor) {
                Write-Host $Message -ForegroundColor $ForegroundColor
            } else {
                Write-Host $Message
            }
        }
    }

    # VERSION FLAG: Provides a standardized version string for orchestration diagnostic checks.
    if ($Version) {
        Write-Output "$PSLintVersion"
        exit 0
    }

    # HELP FLAG: Explicitly displays the script's help information.
    if ($Help) {
        Get-Help $PSCommandPath
        exit 0
    }

    # script-scoped variable to pass settings path from begin block to process block.
    $script:PSLintSettingsFile = $null
    $script:SettingsPrinted = $false

    # RUNTIME INFO AND MODULE LISTING HANDLING
    # Diagnostic Logic: Handles environment reporting before any linting begins.
    # Note: These are informational outputs, not linting results - always use Write-Host
    if ($RuntimeInfo) {
        Write-Host "`n>>> POWERSHELL RUNTIME INFORMATION"
        # Build info hashtable - some properties may not exist in PS 5.1 (OS, PSEdition)
        $info = @{
            "PSVersion" = $PSVersionTable.PSVersion
            "PSPath" = $PSHOME
            "Executable" = (Get-Process -Id $PID).Path
            "ProcessID" = $PID
            "HostName" = $Host.Name
            "HostVersion" = $Host.Version
            "ExecutionPolicy" = (Get-ExecutionPolicy)
        }
        # Add optional properties if they exist (PS Core only)
        if ($PSVersionTable.PSEdition) { $info["PSEdition"] = $PSVersionTable.PSEdition }
        if ($PSVersionTable.OS) { $info["OS"] = $PSVersionTable.OS }

        $info.GetEnumerator() | Sort-Object Name | ForEach-Object {
            Write-Host ("{0,-16}: {1}" -f $_.Key, $_.Value)
        }
        Write-Host ""
    }

    if ($ListModules) {
        Write-Host "`n>>> INSTALLED POWERSHELL MODULES"
        Get-Module -ListAvailable | Select-Object Name, Version, Path | Sort-Object Name | Format-Table -AutoSize
        Write-Host ""
    }

    # CONFIGURATION DISCOVERY:
    # Searches for PSScriptAnalyzerSettings.psd1 in a prioritized list (ScriptDir -> Parent -> CWD).
    # This ensures that the linter always uses repository-standard rules regardless of execution context.
    $SettingsFileName = "PSScriptAnalyzerSettings.psd1"
    $SearchLocations = @(
        $PSScriptRoot,
        (Split-Path $PSScriptRoot -Parent),
        $PWD.Path
    )

    foreach ($loc in $SearchLocations) {
        if ($loc) {
            $testPath = Join-Path $loc $SettingsFileName
            if (Test-Path $testPath) {
                $script:PSLintSettingsFile = $testPath
                break
            }
        }
    }

    # DEPENDENCY MANAGEMENT:
    # Automated setup of PSScriptAnalyzer to ensure the linter is portable across dev machines and CI agents.
    # Installation scope is determined by admin privileges:
    #   - Admin: AllUsers scope (C:\Program Files\...) - available system-wide
    #   - Non-Admin: CurrentUser scope (%LOCALAPPDATA%\...) - current user only
    # Run as admin once to install globally, then all users can use pslint without admin rights.
    function Install-PSLintDependency {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
        param()
        Write-TextOutput "[INFO] Verifying PSScriptAnalyzer installation..." -IsInfo

        $module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1

        if (-not $module) {
            Write-TextOutput "[INFO] PSScriptAnalyzer not found. Attempting installation..." -ForegroundColor Yellow -IsInfo
            try {
                # Determine scope: AllUsers if admin, otherwise CurrentUser
                $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                $installScope = if ($isAdmin) { "AllUsers" } else { "CurrentUser" }

                if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                    Write-TextOutput "[INFO] Installing NuGet provider (Scope: $installScope)..." -IsInfo
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope $installScope -ErrorAction Stop | Out-Null
                }

                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Write-TextOutput "[INFO] Downloading PSScriptAnalyzer from PSGallery (Scope: $installScope)..." -IsInfo
                Install-Module -Name PSScriptAnalyzer -Scope $installScope -Force -AllowClobber -Confirm:$false -ErrorAction Stop

                $module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
            }
            catch {
                Write-TextOutput "[ERROR] Failed to install PSScriptAnalyzer: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
        }

        if (-not (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
            Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
        }

        if (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) {
            $version = (Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1).Version
            Write-TextOutput "[INFO] PSScriptAnalyzer (v$version) is ready." -IsInfo
            return $true
        }
        else {
            Write-TextOutput "[ERROR] PSScriptAnalyzer command is not available." -ForegroundColor Red
            return $false
        }
    }

    if (-not (Install-PSLintDependency)) {
        Write-TextOutput "[FATAL] Cannot proceed without PSScriptAnalyzer." -ForegroundColor Red
        if ($script:JsonMode) {
            $script:JsonResult.exitCode = $script:EXIT_DEPENDENCY
            $script:JsonResult.exitName = "Dependency"
            Write-Output ($script:JsonResult | ConvertTo-Json -Depth 10)
        }
        exit $script:EXIT_DEPENDENCY
    }

    # Handle -CheckLinter flag: exit early if no paths provided, otherwise continue to lint
    if ($CheckLinter) {
        Write-TextOutput "[SUCCESS] Linter check complete." -ForegroundColor Green
        if (-not $Path) { exit 0 }
    }
}

#endregion

#region Execution

# --- EXECUTION TIER ---
# The process block runs once for each pipeline input item (or once if no pipeline).
# Responsibilities:
#   1. Resolve and validate input paths (handles wildcards, arrays, pipeline)
#   2. Enumerate PowerShell files (.ps1, .psm1, .psd1) in directories
#   3. Pre-check for syntax errors (PSScriptAnalyzer silently passes files with syntax errors)
#   4. Execute PSScriptAnalyzer in Audit or Fix mode
#   5. Generate summary report with severity counts
#   6. Return appropriate exit code for CI/CD integration
process {
    if (-not $Path) {
        if (-not ($RuntimeInfo -or $ListModules -or $CheckLinter -or $Version)) {
            Get-Help $PSCommandPath
            exit $script:EXIT_INPUT
        }
        return
    }

    foreach ($SinglePath in $Path) {
        if ([string]::IsNullOrWhiteSpace($SinglePath)) { continue }

        try {
            # Standardize the path to ensure consistent reporting. Wildcards may return an array.
            $ResolvedPaths = Resolve-Path $SinglePath -ErrorAction Stop

            foreach ($Resolved in $ResolvedPaths) {
                $targetPath = $Resolved.Path
                $targetFiles = @()
                $fullTargetFiles = @()

                if ((Get-Item $targetPath) -is [System.IO.DirectoryInfo]) {
                    # Scan for .ps1 scripts, .psm1 modules, and .psd1 manifests
                    if ($Recursive) {
                        $fullTargetFiles = @(Get-ChildItem -Path $Resolved.Path -Include "*.ps1", "*.psm1", "*.psd1" -Recurse -File | Select-Object -ExpandProperty FullName)
                    } else {
                        # -Include requires wildcard in path or -Recurse; use Join-Path to add wildcard
                        $fullTargetFiles = @(Get-ChildItem -Path (Join-Path $Resolved.Path "*") -Include "*.ps1", "*.psm1", "*.psd1" -File | Select-Object -ExpandProperty FullName)
                    }
                    # Wrap in @() to ensure array even for single file
                    $targetFiles = @($fullTargetFiles | Split-Path -Leaf)
                } else {
                    if ($targetPath -notmatch '\.(ps1|psm1|psd1)$') {
                        continue # Silently skip non-PowerShell files matched by wildcards
                    }
                    $fullTargetFiles = @($targetPath)
                    $targetFiles = @(Split-Path $targetPath -Leaf)
                }

                if ($fullTargetFiles.Count -eq 0) {
                    continue
                }

                # --- SYNTAX PRE-CHECK ---
                # CRITICAL: PSScriptAnalyzer cannot parse files with syntax errors and silently
                # reports them as "clean". This pre-check uses the PowerShell parser directly
                # to catch syntax errors before they cause false-positive passes.
                $syntaxErrorFound = $false
                $syntaxErrors = @()
                foreach ($file in $fullTargetFiles) {
                    $parseErrors = $null
                    $null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
                    if ($parseErrors) {
                        Write-TextOutput "`n[FATAL] Syntax Error(s) detected in: $(Split-Path $file -Leaf)" -ForegroundColor Red
                        foreach ($err in $parseErrors) {
                            Write-TextOutput "  Line $($err.Extent.StartLineNumber): $($err.Message)" -ForegroundColor Red
                            $syntaxErrors += @{
                                file = $file
                                line = $err.Extent.StartLineNumber
                                message = $err.Message
                            }
                        }
                        $syntaxErrorFound = $true
                    }
                }

                if ($syntaxErrorFound) {
                    Write-TextOutput "`n[RESULT] FAILED (exit 3): Fix syntax errors before linting." -ForegroundColor Red
                    if ($script:JsonMode) {
                        $script:JsonResult.exitCode = $script:EXIT_SYNTAX
                        $script:JsonResult.exitName = "Syntax"
                        $script:JsonResult.syntaxErrors = $syntaxErrors
                        Write-Output ($script:JsonResult | ConvertTo-Json -Depth 10)
                    }
                    exit $script:EXIT_SYNTAX
                }

                $analyzerParams = @{
                    Path = $targetPath
                }
                if ($Recursive) {
                    $analyzerParams.Recurse = $true
                }

                if ($script:PSLintSettingsFile) {
                    if (-not $script:SettingsPrinted) {
                        Write-TextOutput "[INFO] Using settings from: $script:PSLintSettingsFile" -IsInfo
                        $script:SettingsPrinted = $true
                    }
                    $analyzerParams.Settings = $script:PSLintSettingsFile
                }

                if ($ExcludeRule) {
                    $analyzerParams.ExcludeRule = $ExcludeRule
                }

                if ($IncludeRule) {
                    $analyzerParams.IncludeRule = $IncludeRule
                }

                if ($Fix) {
                    # AUTO-FIX MODE: Directly remediates code in-place based on the settings.
                    # Supported fixes include: alias expansion, formatting corrections, etc.
                    # WARNING: Changes are written directly to files - use version control!
                    Write-TextOutput "`n>>> AUTO-FIX MODE: $($Resolved.Path)" -ForegroundColor Yellow
                    Write-TextOutput "Target Files: $($targetFiles -join ', ')"
                    $fixResults = Invoke-ScriptAnalyzer @analyzerParams -Fix -ErrorAction Stop

                    if ($fixResults) {
                        Write-TextOutput "[INFO] Applied fixes to the following files:" -IsInfo
                        $groupedFix = $fixResults | Group-Object ScriptName
                        foreach ($group in $groupedFix) {
                            Write-TextOutput "`n--- File: $($group.Name) ---"
                            if (-not $script:JsonMode) {
                                $group.Group | Select-Object RuleName, Message | Get-Unique | Format-Table -AutoSize | Out-String | Write-Host
                            }
                            # Collect for JSON output
                            if ($script:JsonMode) {
                                $fileFindings = @($group.Group | ForEach-Object {
                                        @{
                                            rule = $_.RuleName
                                            message = $_.Message
                                            fixed = $true
                                        }
                                    })
                                $script:JsonResult.files += @{
                                    path = $group.Name
                                    findings = $fileFindings
                                }
                            }
                        }
                    }
                    Write-TextOutput "[SUCCESS] Auto-fix pass complete." -ForegroundColor Green
                }
                else {
                    # AUDIT MODE (default): Scans for issues and generates a summary report.
                    # Does not modify files - read-only analysis.
                    Write-TextOutput "`n>>> AUDIT MODE: $($Resolved.Path)" -ForegroundColor Green
                    Write-TextOutput "Target Files: $($targetFiles -join ', ')"
                    if ($Strict) { Write-TextOutput "[MODE] Strict Mode Active (Failing on Warnings)" -ForegroundColor Magenta }

                    # Wrap in @() to ensure array even for single result or null
                    $results = @(Invoke-ScriptAnalyzer @analyzerParams -ErrorAction Stop)

                    if ($results.Count -gt 0) {
                        # Categorize findings by severity
                        # Severity levels: Error (critical), Warning (should fix), Information (suggestions)
                        $errors = @($results | Where-Object { $_.Severity -eq 'Error' })
                        $warnings = @($results | Where-Object { $_.Severity -eq 'Warning' })
                        $info = @($results | Where-Object { $_.Severity -eq 'Information' })

                        # Update JSON summary counts (accumulate across multiple paths)
                        $script:JsonResult.summary.errors += $errors.Count
                        $script:JsonResult.summary.warnings += $warnings.Count
                        $script:JsonResult.summary.info += $info.Count
                        $script:JsonResult.summary.total += $results.Count

                        Write-TextOutput "[SUMMARY] Found $($results.Count) issue(s):" -ForegroundColor White
                        Write-TextOutput "  - Errors: $($errors.Count)" -ForegroundColor Red
                        Write-TextOutput "  - Warnings: $($warnings.Count)" -ForegroundColor Yellow
                        Write-TextOutput "  - Info: $($info.Count)"

                        $groupedResults = $results | Group-Object ScriptName
                        foreach ($group in $groupedResults) {
                            Write-TextOutput "`n--- File: $($group.Name) ---"
                            if (-not $script:JsonMode) {
                                $group.Group | Select-Object Severity, RuleName, Line, Message | Format-Table -AutoSize | Out-String | Write-Host
                            }
                            # Collect findings for JSON output
                            $fileFindings = @($group.Group | ForEach-Object {
                                    @{
                                        severity = $_.Severity.ToString()
                                        rule = $_.RuleName
                                        line = $_.Line
                                        column = $_.Column
                                        message = $_.Message
                                    }
                                })
                            $script:JsonResult.files += @{
                                path = $group.Name
                                findings = $fileFindings
                            }
                        }

                        # CI/CD LOGIC: Granular exit codes for different failure types
                        # Exit 1 = Errors, Exit 2 = Warnings (strict mode only)
                        if ($errors.Count -gt 0) {
                            Write-TextOutput "[RESULT] FAILED (exit 1): Critical errors detected." -ForegroundColor Red
                            $script:JsonResult.exitCode = $script:EXIT_ERRORS
                            $script:JsonResult.exitName = "Errors"
                            if ($script:JsonMode) {
                                Write-Output ($script:JsonResult | ConvertTo-Json -Depth 10)
                            }
                            exit $script:EXIT_ERRORS
                        }
                        elseif ($Strict -and $warnings.Count -gt 0) {
                            Write-TextOutput "[RESULT] FAILED (exit 2): Strict mode enabled and warnings detected." -ForegroundColor Red
                            $script:JsonResult.exitCode = $script:EXIT_WARNINGS
                            $script:JsonResult.exitName = "Warnings"
                            if ($script:JsonMode) {
                                Write-Output ($script:JsonResult | ConvertTo-Json -Depth 10)
                            }
                            exit $script:EXIT_WARNINGS
                        }
                        else {
                            Write-TextOutput "[RESULT] PASSED with warnings/info." -ForegroundColor Yellow
                        }
                    }
                    else {
                        Write-TextOutput "[RESULT] PASSED: No issues found." -ForegroundColor Green
                    }
                }
            }
        }
        catch {
            Write-TextOutput "[ERROR] Execution failed for ${SinglePath}: $($_.Exception.Message)" -ForegroundColor Red
            if ($script:JsonMode) {
                $script:JsonResult.exitCode = $script:EXIT_INPUT
                $script:JsonResult.exitName = "Input"
                $script:JsonResult.error = $_.Exception.Message
                Write-Output ($script:JsonResult | ConvertTo-Json -Depth 10)
            }
            exit $script:EXIT_INPUT
        }
    }
}

#endregion

#region Finalization

# --- FINALIZATION TIER ---
# The end block runs once after all pipeline input has been processed.
# If we reach this point without an earlier exit, all files passed linting.
end {
    # Output JSON result if in JSON mode
    if ($script:JsonMode) {
        $script:JsonResult.exitCode = $script:EXIT_SUCCESS
        $script:JsonResult.exitName = "Success"
        Write-Output ($script:JsonResult | ConvertTo-Json -Depth 10)
    }
    # Explicitly return exit code 0 to guarantee CI/CD pipelines register success.
    # Earlier exits handle failure cases with granular codes (1-5).
    exit $script:EXIT_SUCCESS
}

#endregion
