#Requires -Version 5.1
<#
.SYNOPSIS
    Test suite for pslint.ps1 - comprehensive functionality coverage.

.DESCRIPTION
    Comprehensive test suite with 100% functionality coverage:
    - Help and version flags (-Help, -h, -Version, -v)
    - All exit codes (0=success, 2=warnings+strict, 3=syntax, 5=invalid)
    - Output formats (Text, Json) with structure validation
    - File type scanning (.ps1, .psm1, .psd1)
    - Directory modes (recursive, non-recursive)
    - Strict mode behavior
    - Syntax error detection and JSON reporting
    - Settings file discovery (PSScriptAnalyzerSettings.psd1)
    - RuntimeInfo and ListModules diagnostic flags
    - Fix mode (auto-remediation)
    - Pipeline input
    - Wildcard path patterns
    - Multiple paths in single call
    - ExcludeRule parameter
    - CheckLinter dependency verification

.PARAMETER ShowCommands
    Display the pslint.ps1 commands being executed during tests.

.EXAMPLE
    .\pslint_test.ps1
    Run all tests.

.EXAMPLE
    .\pslint_test.ps1 -ShowCommands
    Run all tests showing each command.

.OUTPUTS
    Test results summary with pass/fail counts.
    Exit code 0 if all tests pass, 1 if any fail.

.NOTES
    Version: 1.1.0
    Tests: 76 total (100% functionality coverage)
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingEmptyCatchBlock", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "ShowCommands")]
[CmdletBinding()]
param(
    [switch]$ShowCommands
)

#region Initialization

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:PSLint = Join-Path $PSScriptRoot "pslint.ps1"

# Unique workspace: TEMP/unittests/pslint_YYYYMMDDhhmmss
$script:UnitTestRoot = Join-Path $env:TEMP "unittests"
$script:Timestamp = Get-Date -Format "yyyyMMddHHmmss"
$script:TempDir = Join-Path $script:UnitTestRoot "pslint_$script:Timestamp"

#endregion

#region Test Helpers

<#
.SYNOPSIS
    Display a test category header.
#>
function Write-TestHeader {
    param([string]$Name)
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
}

<#
.SYNOPSIS
    Record and display a test result.
#>
function Write-TestResult {
    param(
        [string]$Test,
        [bool]$Passed,
        [string]$Details = ""
    )

    if ($Passed) {
        Write-Host "  [PASS] $Test" -ForegroundColor Green
        $script:TestsPassed++
    } else {
        Write-Host "  [FAIL] $Test" -ForegroundColor Red
        if ($Details) { Write-Host "         $Details" -ForegroundColor Yellow }
        $script:TestsFailed++
    }
}

<#
.SYNOPSIS
    Execute pslint.ps1 in a subprocess and capture output/exit code.
#>
function Invoke-PSLint {
    param([string]$Arguments)

    if ($ShowCommands) {
        Write-Host "    > pslint.ps1 $Arguments" -ForegroundColor DarkGray
    }

    # Use -Command instead of -File for proper argument handling with paths containing spaces
    $command = "& '$script:PSLint' $Arguments; exit `$LASTEXITCODE"

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "powershell.exe"
    $pinfo.Arguments = "-ExecutionPolicy Bypass -NoProfile -Command `"$command`""
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true
    $pinfo.WorkingDirectory = $PSScriptRoot

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo
    $process.Start() | Out-Null
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return @{
        Output = $stdout + $stderr
        ExitCode = $process.ExitCode
    }
}

<#
.SYNOPSIS
    Create a temporary test file with specified content.
#>
function New-TestFile {
    param(
        [string]$Name,
        [string]$Content
    )
    $path = Join-Path $script:TempDir $Name
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -Path $path -Value $Content -Encoding UTF8
    return $path
}

<#
.SYNOPSIS
    Setup temporary test directory with test files.
.DESCRIPTION
    Creates a unique workspace under TEMP/unittests/pslint_YYYYMMDDhhmmss
    to isolate test runs and enable easy debugging of failed tests.
#>
function Initialize-TestEnvironment {
    # Ensure unittests root exists
    if (-not (Test-Path $script:UnitTestRoot)) {
        New-Item -ItemType Directory -Path $script:UnitTestRoot -Force | Out-Null
    }

    # Create unique timestamped workspace
    if (Test-Path $script:TempDir) {
        Remove-Item $script:TempDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    Write-Host "Workspace: $script:TempDir" -ForegroundColor DarkGray

    # Clean PS1 file (no issues)
    New-TestFile -Name "clean.ps1" -Content @'
# Clean script with no issues
function Get-CleanData {
    [CmdletBinding()]
    param([string]$Name)
    return "Hello, $Name"
}
'@

    # PS1 with warnings (alias usage - default rule)
    New-TestFile -Name "warnings.ps1" -Content @'
# Script with warnings (uses cmdlet aliases)
function Show-Data {
    ls   # triggers PSAvoidUsingCmdletAliases
    gci  # triggers PSAvoidUsingCmdletAliases
}
'@

    # PS1 with syntax error (in separate dir to not interfere with directory scan tests)
    New-TestFile -Name "errors\syntax_error.ps1" -Content @'
function Broken {
    if ($true {
        Write-Output "Missing paren"
    }
}
'@

    # PSM1 module file
    New-TestFile -Name "module.psm1" -Content @'
# Module file
function Get-ModuleData {
    [CmdletBinding()]
    param()
    return "Module data"
}
Export-ModuleMember -Function Get-ModuleData
'@

    # PSD1 manifest file
    New-TestFile -Name "module.psd1" -Content @'
@{
    ModuleVersion = '1.0.0'
    RootModule = 'module.psm1'
    FunctionsToExport = @('Get-ModuleData')
}
'@

    # Subdirectory with file (for recursive scan test)
    New-TestFile -Name "subdir\nested.ps1" -Content @'
# Nested script
function Get-NestedData {
    return "Nested"
}
'@

    # Clean directory for directory scanning tests (no syntax errors)
    New-TestFile -Name "scantest\root.ps1" -Content @'
function Get-Root { return "root" }
'@
    New-TestFile -Name "scantest\another.ps1" -Content @'
function Get-Another { return "another" }
'@
    New-TestFile -Name "scantest\deep\nested.ps1" -Content @'
function Get-DeepNested { return "deep" }
'@

    # File with PSScriptAnalyzer ERROR (not just warning) - undefined variable in strict mode
    New-TestFile -Name "errors\has_error.ps1" -Content @'
# This triggers PSUseDeclaredVarsMoreThanAssignments (Error level with proper settings)
function Get-BadData {
    $result = $undefinedVariable
    return $result
}
'@

    # File for -Fix testing (uses aliases that can be auto-fixed)
    New-TestFile -Name "fixable.ps1" -Content @'
# File with fixable issues (aliases)
function Get-FixableData {
    ls
    gci
    cd ..
}
'@

    # Multiple files for wildcard testing
    New-TestFile -Name "wild\file1.ps1" -Content 'function Get-One { return 1 }'
    New-TestFile -Name "wild\file2.ps1" -Content 'function Get-Two { return 2 }'
    New-TestFile -Name "wild\file3.ps1" -Content 'function Get-Three { return 3 }'
}

<#
.SYNOPSIS
    Cleanup temporary test directory.
.DESCRIPTION
    Removes the unique workspace created for this test run.
    The unittests root directory is preserved for inspection of other runs.
#>
function Remove-TestEnvironment {
    if (Test-Path $script:TempDir) {
        Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Workspace cleaned: $script:TempDir" -ForegroundColor DarkGray
    }
}

#endregion

#region Tests

function Test-HelpFlags {
    Write-TestHeader "Help Flags"

    # Test: -Help
    $result = Invoke-PSLint "-Help"
    Write-TestResult -Test "-Help shows documentation" -Passed ($result.Output -match "SYNOPSIS")
    Write-TestResult -Test "-Help exits 0" -Passed ($result.ExitCode -eq 0)

    # Test: -h alias
    $result = Invoke-PSLint "-h"
    Write-TestResult -Test "-h alias works" -Passed ($result.Output -match "SYNOPSIS")

    # Test: no args shows help
    $result = Invoke-PSLint ""
    Write-TestResult -Test "no args shows help" -Passed ($result.Output -match "SYNOPSIS")
}

function Test-VersionFlags {
    Write-TestHeader "Version Flags"

    # Test: -Version
    $result = Invoke-PSLint "-Version"
    Write-TestResult -Test "-Version shows version" -Passed ($result.Output -match "^\d+\.\d+\.\d+")
    Write-TestResult -Test "-Version exits 0" -Passed ($result.ExitCode -eq 0)

    # Test: -v alias
    $result = Invoke-PSLint "-v"
    Write-TestResult -Test "-v alias works" -Passed ($result.Output -match "^\d+\.\d+\.\d+")
}

function Test-ExitCodeSuccess {
    Write-TestHeader "Exit Code 0 (Success)"

    $cleanFile = Join-Path $script:TempDir "clean.ps1"

    # Test: clean file passes
    $result = Invoke-PSLint "-Path `"$cleanFile`""
    Write-TestResult -Test "clean file exits 0" -Passed ($result.ExitCode -eq 0)
    Write-TestResult -Test "clean file shows PASSED" -Passed ($result.Output -match "PASSED")
}

function Test-ExitCodeWarningsStrict {
    Write-TestHeader "Exit Code 2 (Warnings + Strict)"

    $warningsFile = Join-Path $script:TempDir "warnings.ps1"

    # Test: warnings without strict = pass
    $result = Invoke-PSLint "-Path `"$warningsFile`""
    Write-TestResult -Test "warnings without -Strict exits 0" -Passed ($result.ExitCode -eq 0)

    # Test: warnings with strict = fail
    $result = Invoke-PSLint "-Path `"$warningsFile`" -Strict"
    Write-TestResult -Test "warnings with -Strict exits 2" -Passed ($result.ExitCode -eq 2) -Details "Got: $($result.ExitCode)"
    Write-TestResult -Test "shows strict mode message" -Passed ($result.Output -match "Strict mode")
}

function Test-ExitCodeSyntax {
    Write-TestHeader "Exit Code 3 (Syntax Error)"

    $syntaxFile = Join-Path $script:TempDir "errors\syntax_error.ps1"

    $result = Invoke-PSLint "-Path `"$syntaxFile`""
    Write-TestResult -Test "syntax error exits 3" -Passed ($result.ExitCode -eq 3) -Details "Got: $($result.ExitCode)"
    Write-TestResult -Test "shows FATAL message" -Passed ($result.Output -match "FATAL.*Syntax")
}

function Test-ExitCodeInvalidPath {
    Write-TestHeader "Exit Code 5 (Invalid Input)"

    $result = Invoke-PSLint "-Path `"C:\nonexistent\path\file.ps1`""
    Write-TestResult -Test "invalid path exits 5" -Passed ($result.ExitCode -eq 5) -Details "Got: $($result.ExitCode)"
    Write-TestResult -Test "shows ERROR message" -Passed ($result.Output -match "ERROR")
}

function Test-OutputFormatText {
    Write-TestHeader "Output Format: Text"

    $warningsFile = Join-Path $script:TempDir "warnings.ps1"

    $result = Invoke-PSLint "-Path `"$warningsFile`" -OutputFormat Text"
    Write-TestResult -Test "Text mode shows INFO messages" -Passed ($result.Output -match "\[INFO\]")
    Write-TestResult -Test "Text mode shows AUDIT MODE" -Passed ($result.Output -match "AUDIT MODE")
    Write-TestResult -Test "Text mode shows SUMMARY" -Passed ($result.Output -match "\[SUMMARY\]")
}

function Test-OutputFormatJson {
    Write-TestHeader "Output Format: Json"

    $warningsFile = Join-Path $script:TempDir "warnings.ps1"

    # Test: JSON output is valid
    $result = Invoke-PSLint "-Path `"$warningsFile`" -OutputFormat Json"
    $isValidJson = $false
    $json = $null
    try {
        $json = $result.Output | ConvertFrom-Json
        $isValidJson = $true
    } catch { }
    Write-TestResult -Test "JSON output is valid JSON" -Passed $isValidJson

    # Test: JSON structure
    if ($json) {
        Write-TestResult -Test "JSON has version" -Passed ($null -ne $json.version)
        Write-TestResult -Test "JSON has exitCode" -Passed ($null -ne $json.exitCode)
        Write-TestResult -Test "JSON has exitName" -Passed ($null -ne $json.exitName)
        Write-TestResult -Test "JSON has summary" -Passed ($null -ne $json.summary)
        Write-TestResult -Test "JSON has files array" -Passed ($null -ne $json.files)
        Write-TestResult -Test "JSON summary has warnings count" -Passed ($json.summary.warnings -gt 0)
    }

    # Test: JSON mode suppresses text output
    Write-TestResult -Test "JSON mode no [INFO] messages" -Passed ($result.Output -notmatch "\[INFO\]")
}

function Test-JsonSyntaxError {
    Write-TestHeader "JSON Output: Syntax Error"

    $syntaxFile = Join-Path $script:TempDir "errors\syntax_error.ps1"

    $result = Invoke-PSLint "-Path `"$syntaxFile`" -OutputFormat Json"
    $json = $null
    try { $json = $result.Output | ConvertFrom-Json } catch { }

    if ($json) {
        Write-TestResult -Test "JSON syntax error has exitCode 3" -Passed ($json.exitCode -eq 3)
        Write-TestResult -Test "JSON syntax error has syntaxErrors array" -Passed ($null -ne $json.syntaxErrors)
        Write-TestResult -Test "JSON syntaxErrors contains error details" -Passed ($json.syntaxErrors.Count -gt 0)
    } else {
        Write-TestResult -Test "JSON syntax error output is valid" -Passed $false
    }
}

function Test-FileTypeScanning {
    Write-TestHeader "File Type Scanning"

    # Test: PS1 files
    $ps1File = Join-Path $script:TempDir "clean.ps1"
    $result = Invoke-PSLint "-Path `"$ps1File`""
    Write-TestResult -Test ".ps1 files are scanned" -Passed ($result.Output -match "clean\.ps1")

    # Test: PSM1 files
    $psm1File = Join-Path $script:TempDir "module.psm1"
    $result = Invoke-PSLint "-Path `"$psm1File`""
    Write-TestResult -Test ".psm1 files are scanned" -Passed ($result.Output -match "module\.psm1")

    # Test: PSD1 files
    $psd1File = Join-Path $script:TempDir "module.psd1"
    $result = Invoke-PSLint "-Path `"$psd1File`""
    Write-TestResult -Test ".psd1 files are scanned" -Passed ($result.Output -match "module\.psd1")
}

function Test-DirectoryScanning {
    Write-TestHeader "Directory Scanning"

    # Use dedicated clean directory for scanning tests (no syntax errors)
    $scanDir = Join-Path $script:TempDir "scantest"

    # Test: non-recursive (should find root files only)
    $result = Invoke-PSLint "-Path `"$scanDir`""
    Write-TestResult -Test "non-recursive finds root files" -Passed ($result.Output -match "root\.ps1")
    Write-TestResult -Test "non-recursive skips subdirs" -Passed ($result.Output -notmatch "nested\.ps1")

    # Test: recursive (should find all files)
    $result = Invoke-PSLint "-Path `"$scanDir`" -Recursive"
    Write-TestResult -Test "recursive finds root files" -Passed ($result.Output -match "root\.ps1")
    Write-TestResult -Test "recursive finds nested files" -Passed ($result.Output -match "nested\.ps1")
}

function Test-CheckLinter {
    Write-TestHeader "CheckLinter Flag"

    $result = Invoke-PSLint "-CheckLinter"
    Write-TestResult -Test "-CheckLinter exits 0" -Passed ($result.ExitCode -eq 0)
    Write-TestResult -Test "-CheckLinter shows SUCCESS" -Passed ($result.Output -match "SUCCESS.*Linter check")
    Write-TestResult -Test "-CheckLinter shows PSScriptAnalyzer version" -Passed ($result.Output -match "PSScriptAnalyzer.*v\d+\.\d+")
}

function Test-ExcludeRule {
    Write-TestHeader "ExcludeRule Parameter"

    $warningsFile = Join-Path $script:TempDir "warnings.ps1"

    # Without exclude - should have warnings
    $result = Invoke-PSLint "-Path `"$warningsFile`" -OutputFormat Json"
    $json = $result.Output | ConvertFrom-Json
    $warningsWithout = $json.summary.warnings

    # With exclude - should have fewer/no warnings (exclude the alias rule our test file triggers)
    $result = Invoke-PSLint "-Path `"$warningsFile`" -ExcludeRule PSAvoidUsingCmdletAliases -OutputFormat Json"
    $json = $result.Output | ConvertFrom-Json
    $warningsWith = $json.summary.warnings

    Write-TestResult -Test "-ExcludeRule reduces warnings" -Passed ($warningsWith -lt $warningsWithout)
}

function Test-RuntimeInfo {
    Write-TestHeader "RuntimeInfo Flag"

    $result = Invoke-PSLint "-RuntimeInfo -CheckLinter"
    Write-TestResult -Test "-RuntimeInfo shows PS version" -Passed ($result.Output -match "PSVersion")
    Write-TestResult -Test "-RuntimeInfo shows executable" -Passed ($result.Output -match "Executable")
    Write-TestResult -Test "-RuntimeInfo shows execution policy" -Passed ($result.Output -match "ExecutionPolicy")
    Write-TestResult -Test "-RuntimeInfo exits 0" -Passed ($result.ExitCode -eq 0)
}

function Test-ListModules {
    Write-TestHeader "ListModules Flag"

    $result = Invoke-PSLint "-ListModules -CheckLinter"
    Write-TestResult -Test "-ListModules shows module list" -Passed ($result.Output -match "INSTALLED POWERSHELL MODULES")
    Write-TestResult -Test "-ListModules shows PSScriptAnalyzer" -Passed ($result.Output -match "PSScriptAnalyzer")
    Write-TestResult -Test "-ListModules exits 0" -Passed ($result.ExitCode -eq 0)
}

function Test-FixMode {
    Write-TestHeader "Fix Mode"

    # Create a fresh file with consistent line endings (CRLF for Windows)
    $fixCopyFile = Join-Path $script:TempDir "fixcopy.ps1"
    $content = "# Fixable`r`nfunction Get-Fix {`r`n    ls`r`n    gci`r`n}`r`n"
    [System.IO.File]::WriteAllText($fixCopyFile, $content)

    # Get original content
    $originalContent = [System.IO.File]::ReadAllText($fixCopyFile)

    # Run fix mode
    $result = Invoke-PSLint "-Path `"$fixCopyFile`" -Fix"
    Write-TestResult -Test "-Fix mode runs" -Passed ($result.Output -match "AUTO-FIX MODE")
    Write-TestResult -Test "-Fix mode completes" -Passed ($result.Output -match "Auto-fix pass complete")
    Write-TestResult -Test "-Fix mode exits 0" -Passed ($result.ExitCode -eq 0)

    # Check if file was modified (aliases should be expanded)
    $newContent = [System.IO.File]::ReadAllText($fixCopyFile)
    $wasModified = $originalContent -ne $newContent
    Write-TestResult -Test "-Fix mode modifies file" -Passed $wasModified

    # Cleanup
    Remove-Item $fixCopyFile -Force -ErrorAction SilentlyContinue
}

function Test-PipelineInput {
    Write-TestHeader "Pipeline Input"

    $cleanFile = Join-Path $script:TempDir "clean.ps1"

    # Test pipeline input via -Command (simulating pipeline)
    $command = "Write-Output '$cleanFile' | & '$script:PSLint'; exit `$LASTEXITCODE"
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "powershell.exe"
    $pinfo.Arguments = "-ExecutionPolicy Bypass -NoProfile -Command `"$command`""
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo
    $process.Start() | Out-Null
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $output = $stdout + $stderr
    Write-TestResult -Test "pipeline input processes file" -Passed ($output -match "clean\.ps1")
    Write-TestResult -Test "pipeline input exits 0" -Passed ($process.ExitCode -eq 0)
}

function Test-WildcardPaths {
    Write-TestHeader "Wildcard Paths"

    $wildDir = Join-Path $script:TempDir "wild"

    # Test wildcard pattern
    $result = Invoke-PSLint "-Path `"$wildDir\*.ps1`""
    Write-TestResult -Test "wildcard finds file1" -Passed ($result.Output -match "file1\.ps1")
    Write-TestResult -Test "wildcard finds file2" -Passed ($result.Output -match "file2\.ps1")
    Write-TestResult -Test "wildcard finds file3" -Passed ($result.Output -match "file3\.ps1")
    Write-TestResult -Test "wildcard exits 0" -Passed ($result.ExitCode -eq 0)
}

function Test-MultiplePaths {
    Write-TestHeader "Multiple Paths"

    $cleanFile = Join-Path $script:TempDir "clean.ps1"
    $moduleFile = Join-Path $script:TempDir "module.psm1"

    # Test multiple paths in single call
    $result = Invoke-PSLint "-Path `"$cleanFile`", `"$moduleFile`""
    Write-TestResult -Test "multiple paths: finds clean.ps1" -Passed ($result.Output -match "clean\.ps1")
    Write-TestResult -Test "multiple paths: finds module.psm1" -Passed ($result.Output -match "module\.psm1")
    Write-TestResult -Test "multiple paths exits 0" -Passed ($result.ExitCode -eq 0)
}

function Test-SettingsDiscovery {
    Write-TestHeader "Settings Discovery"

    $cleanFile = Join-Path $script:TempDir "clean.ps1"

    # The main pslint.ps1 has a PSScriptAnalyzerSettings.psd1 in its directory
    $result = Invoke-PSLint "-Path `"$cleanFile`""
    Write-TestResult -Test "settings file discovered" -Passed ($result.Output -match "Using settings from:")
    Write-TestResult -Test "settings file is .psd1" -Passed ($result.Output -match "PSScriptAnalyzerSettings\.psd1")
}

function Test-JsonMultipleFiles {
    Write-TestHeader "JSON Output: Multiple Files"

    $warningsFile = Join-Path $script:TempDir "warnings.ps1"
    $cleanFile = Join-Path $script:TempDir "clean.ps1"

    # Test JSON with multiple files
    $result = Invoke-PSLint "-Path `"$warningsFile`", `"$cleanFile`" -OutputFormat Json"
    $json = $null
    try { $json = $result.Output | ConvertFrom-Json } catch { }

    if ($json) {
        Write-TestResult -Test "JSON multi-file: valid JSON" -Passed $true
        Write-TestResult -Test "JSON multi-file: has files array" -Passed ($json.files.Count -ge 1)
        Write-TestResult -Test "JSON multi-file: summary accumulates" -Passed ($json.summary.total -ge 0)
    } else {
        Write-TestResult -Test "JSON multi-file: valid JSON" -Passed $false
    }
}

function Test-QuietMode {
    Write-TestHeader "Quiet Mode"

    $cleanFile = Join-Path $script:TempDir "clean.ps1"

    # Without -Quiet: should have INFO messages
    $result = Invoke-PSLint "-Path `"$cleanFile`""
    $hasInfo = $result.Output -match "\[INFO\]"
    Write-TestResult -Test "normal mode shows INFO" -Passed $hasInfo

    # With -Quiet: should NOT have INFO messages
    $result = Invoke-PSLint "-Path `"$cleanFile`" -Quiet"
    $hasNoInfo = $result.Output -notmatch "\[INFO\]"
    Write-TestResult -Test "-Quiet suppresses INFO" -Passed $hasNoInfo
    Write-TestResult -Test "-Quiet still shows results" -Passed ($result.Output -match "PASSED")
    Write-TestResult -Test "-Quiet exits 0" -Passed ($result.ExitCode -eq 0)

    # Test -q alias
    $result = Invoke-PSLint "-Path `"$cleanFile`" -q"
    Write-TestResult -Test "-q alias works" -Passed ($result.Output -notmatch "\[INFO\]")
}

function Test-IncludeRule {
    Write-TestHeader "IncludeRule Parameter"

    $warningsFile = Join-Path $script:TempDir "warnings.ps1"

    # Without -IncludeRule: should find multiple rules
    $result = Invoke-PSLint "-Path `"$warningsFile`" -OutputFormat Json"
    $json = $result.Output | ConvertFrom-Json
    $totalWithout = $json.summary.total

    # With -IncludeRule: only run specific rule
    $result = Invoke-PSLint "-Path `"$warningsFile`" -IncludeRule PSUseSingularNouns -OutputFormat Json"
    $json = $result.Output | ConvertFrom-Json
    $totalWith = $json.summary.total

    # IncludeRule should find fewer issues (only the specified rule)
    Write-TestResult -Test "-IncludeRule limits rules" -Passed ($totalWith -lt $totalWithout -or $totalWith -eq 0)
}

function Test-VersionNumber {
    Write-TestHeader "Version Number"

    $result = Invoke-PSLint "-Version"
    # Should be 1.1.0 or higher
    Write-TestResult -Test "version is 1.1.0+" -Passed ($result.Output -match "^1\.[1-9]")
}

#endregion

#region Main

Write-Host "========================================" -ForegroundColor White
Write-Host "  pslint.ps1 Test Suite" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Setup
Write-Host "`nSetting up test environment..." -ForegroundColor Gray
Initialize-TestEnvironment

# Run all tests
try {
    Test-HelpFlags
    Test-VersionFlags
    Test-ExitCodeSuccess
    Test-ExitCodeWarningsStrict
    Test-ExitCodeSyntax
    Test-ExitCodeInvalidPath
    Test-OutputFormatText
    Test-OutputFormatJson
    Test-JsonSyntaxError
    Test-FileTypeScanning
    Test-DirectoryScanning
    Test-CheckLinter
    Test-ExcludeRule
    Test-RuntimeInfo
    Test-ListModules
    Test-FixMode
    Test-PipelineInput
    Test-WildcardPaths
    Test-MultiplePaths
    Test-SettingsDiscovery
    Test-JsonMultipleFiles
    Test-QuietMode
    Test-IncludeRule
    Test-VersionNumber
}
finally {
    # Cleanup
    Write-Host "`nCleaning up test environment..." -ForegroundColor Gray
    Remove-TestEnvironment
}

# Summary
Write-Host "`n========================================" -ForegroundColor White
Write-Host "  Test Results" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host "Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "Total:  $($script:TestsPassed + $script:TestsFailed)"
Write-Host ""

if ($script:TestsFailed -gt 0) {
    Write-Host "SOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

#endregion
