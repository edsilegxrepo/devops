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

.PARAMETER Path
    The path to the PowerShell script (.ps1) or directory to be analyzed. Supports string arrays and pipeline input.

.PARAMETER Recursive
    If specified, recursively processes all PowerShell scripts in the target directory.

.PARAMETER Strict
    If specified, treats Warnings as Errors. Recommended for PR gates and build pipelines.

.PARAMETER Fix
    Enables Auto-Fix Mode. Attempts to automatically remediate common issues (formatting, aliases) in-place.

.PARAMETER ExcludeRule
    A list of specific rule names to exclude from this run for granular control.

.PARAMETER RuntimeInfo
    Displays information about the current PowerShell runtime (Version, Path, Executable) for debugging.

.PARAMETER ListModules
    Lists all PowerShell modules available in the current environment to verify dependencies.

.PARAMETER CheckLinter
    Standalone action to only check for the presence of PSScriptAnalyzer and install/update it as needed.

.PARAMETER Version
    Displays the current version of the PSLint utility and exits.

.EXAMPLE
    .\pslint.ps1 -CheckLinter
    .\pslint.ps1 -Path .\os_sys\ -Recursive -Strict
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
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
    [switch]$Version,

    [Parameter(Mandatory = $false)]
    [switch]$Help
)

# --- INITIALIZATION TIER ---
# Set strict mode to prevent the use of uninitialized variables or invalid property references.
begin {
    Set-StrictMode -Version Latest

    # Version Information
    $PSLintVersion = "1.0.0"

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
    if ($RuntimeInfo) {
        Write-Host "`n>>> POWERSHELL RUNTIME INFORMATION"
        $info = @{
            "PSVersion" = $PSVersionTable.PSVersion
            "PSEdition" = $PSVersionTable.PSEdition
            "OS" = $PSVersionTable.OS
            "PSPath" = $PSHOME
            "Executable" = (Get-Process -Id $PID).Path
            "ProcessID" = $PID
            "HostName" = $Host.Name
            "HostVersion" = $Host.Version
            "ExecutionPolicy" = (Get-ExecutionPolicy)
        }
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
    function Install-PSLintDependency {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
        param()
        Write-Host "[INFO] Verifying PSScriptAnalyzer installation..."

        $module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1

        if (-not $module) {
            Write-Host "[INFO] PSScriptAnalyzer not found. Attempting installation..." -ForegroundColor Yellow
            try {
                if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                    Write-Host "[INFO] Installing NuGet provider..."
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
                }

                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                Write-Host "[INFO] Downloading PSScriptAnalyzer from PSGallery..."
                Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber -Confirm:$false -ErrorAction Stop

                $module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
            }
            catch {
                Write-Host "[ERROR] Failed to install PSScriptAnalyzer: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
        }

        if (-not (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
            Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
        }

        if (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) {
            $version = (Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1).Version
            Write-Host "[INFO] PSScriptAnalyzer (v$version) is ready."
            return $true
        }
        else {
            Write-Host "[ERROR] PSScriptAnalyzer command is not available." -ForegroundColor Red
            return $false
        }
    }

    if (-not (Install-PSLintDependency)) {
        Write-Host "[FATAL] Cannot proceed without PSScriptAnalyzer." -ForegroundColor Red
        exit 1
    }

    if ($CheckLinter) {
        Write-Host "[SUCCESS] Linter check complete." -ForegroundColor Green
        if (-not $Path) { exit 0 }
    }
}

# --- EXECUTION TIER ---
# Iterates over each provided path (supporting piping and arrays) to run the static analysis.
process {
    if (-not $Path) {
        if (-not ($RuntimeInfo -or $ListModules -or $CheckLinter -or $Version)) {
            Get-Help $PSCommandPath
            exit 1
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
                    $targetPath = Join-Path $targetPath "*.ps1"
                    if ($Recursive) {
                        $fullTargetFiles = @(Get-ChildItem -Path $Resolved.Path -Filter "*.ps1" -Recurse -File | Select-Object -ExpandProperty FullName)
                    } else {
                        $fullTargetFiles = @(Get-ChildItem -Path $Resolved.Path -Filter "*.ps1" -File | Select-Object -ExpandProperty FullName)
                    }
                    $targetFiles = $fullTargetFiles | Split-Path -Leaf
                } else {
                    if ($targetPath -notmatch '\.ps1$') {
                        continue # Silently skip non-ps1 files matched by wildcards
                    }
                    $fullTargetFiles = @($targetPath)
                    $targetFiles = @(Split-Path $targetPath -Leaf)
                }

                if ($targetFiles.Count -eq 0) {
                    continue
                }

                # --- SYNTAX PRE-CHECK ---
                # A file with a syntax error cannot be parsed by PSScriptAnalyzer, resulting in a false "Pass".
                $syntaxErrorFound = $false
                foreach ($file in $fullTargetFiles) {
                    $parseErrors = $null
                    $null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
                    if ($parseErrors) {
                        Write-Host "`n[FATAL] Syntax Error(s) detected in: $(Split-Path $file -Leaf)" -ForegroundColor Red
                        foreach ($err in $parseErrors) {
                            Write-Host "  Line $($err.Extent.StartLineNumber): $($err.Message)" -ForegroundColor Red
                        }
                        $syntaxErrorFound = $true
                    }
                }

                if ($syntaxErrorFound) {
                    Write-Host "`n[RESULT] FAILED: Fix syntax errors before linting." -ForegroundColor Red
                    exit 1
                }

                $analyzerParams = @{
                    Path = $targetPath
                    Recurse = $Recursive
                }

                if ($script:PSLintSettingsFile) {
                    if (-not $script:SettingsPrinted) {
                        Write-Host "[INFO] Using settings from: $script:PSLintSettingsFile"
                        $script:SettingsPrinted = $true
                    }
                    $analyzerParams.Settings = $script:PSLintSettingsFile
                }

                if ($ExcludeRule) {
                    $analyzerParams.ExcludeRule = $ExcludeRule
                }

                if ($Fix) {
                    # AUTO-FIX MODE: Directly remediates code (e.g., formatting) based on the settings.
                    Write-Host "`n>>> AUTO-FIX MODE: $($Resolved.Path)" -ForegroundColor Yellow
                    Write-Host "Target Files: $($targetFiles -join ', ')"
                    $fixResults = Invoke-ScriptAnalyzer @analyzerParams -Fix -ErrorAction Stop

                    if ($fixResults) {
                        Write-Host "[INFO] Applied fixes to the following files:"
                        $groupedFix = $fixResults | Group-Object ScriptName
                        foreach ($group in $groupedFix) {
                            Write-Host "`n--- File: $($group.Name) ---"
                            $group.Group | Select-Object RuleName, Message | Get-Unique | Format-Table -AutoSize | Out-String | Write-Host
                        }
                    }
                    Write-Host "[SUCCESS] Auto-fix pass complete." -ForegroundColor Green
                }
                else {
                    # AUDIT MODE: Scans for issues and generates a summary report.
                    Write-Host "`n>>> AUDIT MODE: $($Resolved.Path)" -ForegroundColor Green
                    Write-Host "Target Files: $($targetFiles -join ', ')"
                    if ($Strict) { Write-Host "[MODE] Strict Mode Active (Failing on Warnings)" -ForegroundColor Magenta }

                    $results = Invoke-ScriptAnalyzer @analyzerParams -ErrorAction Stop

                    if ($results) {
                        # NOTE: We wrap results in @() to ensure strict-mode compatibility with .Count
                        # when only a single finding is returned.
                        $errors = @($results | Where-Object { $_.Severity -eq 'Error' })
                        $warnings = @($results | Where-Object { $_.Severity -eq 'Warning' })
                        $info = @($results | Where-Object { $_.Severity -eq 'Information' })

                        Write-Host "[SUMMARY] Found $(@($results).Count) issue(s):" -ForegroundColor White
                        Write-Host "  - Errors: $(@($errors).Count)" -ForegroundColor Red
                        Write-Host "  - Warnings: $(@($warnings).Count)" -ForegroundColor Yellow
                        Write-Host "  - Info: $(@($info).Count)"

                        $groupedResults = $results | Group-Object ScriptName
                        foreach ($group in $groupedResults) {
                            Write-Host "`n--- File: $($group.Name) ---"
                            $group.Group | Select-Object Severity, RuleName, Line, Message | Format-Table -AutoSize | Out-String | Write-Host
                        }

                        # CI/CD LOGIC: Standardized exit codes to fail build pipelines on quality regressions.
                        if (@($errors).Count -gt 0) {
                            Write-Host "[RESULT] FAILED: Critical errors detected." -ForegroundColor Red
                            exit 1
                        }
                        elseif ($Strict -and @($warnings).Count -gt 0) {
                            Write-Host "[RESULT] FAILED: Strict mode enabled and warnings detected." -ForegroundColor Red
                            exit 1
                        }
                        else {
                            Write-Host "[RESULT] PASSED with warnings/info." -ForegroundColor Yellow
                        }
                    }
                    else {
                        Write-Host "[RESULT] PASSED: No issues found." -ForegroundColor Green
                    }
                }
            }
        }
        catch {
            Write-Host "[ERROR] Execution failed for ${SinglePath}: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }
}

end {
    # Explicitly return 0 to guarantee CI/CD pipelines register a success if no errors were hit
    exit 0
}
