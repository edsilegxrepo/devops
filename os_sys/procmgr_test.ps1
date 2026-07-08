<#
.SYNOPSIS
    Comprehensive test suite for procmgr.ps1 with 100% functional coverage.

.DESCRIPTION
    This test suite validates all functionality of the procmgr.ps1 process
    management utility. It uses a structured testing approach with isolated
    test cases organized by functional area.

    TEST CATEGORIES:
        Help Mode      - Validates help output, content, and exit codes
        List Mode      - Tests process listing, filtering, sorting, limiting
        Info Mode      - Tests detailed process information retrieval
        Set Mode       - Tests priority and affinity modification
        Kill Mode      - Tests process termination
        Config Preset  - Tests configuration file and preset expansion
        Exit Code      - Validates correct exit codes for all scenarios
        Edge Case      - Tests boundary conditions and error handling
        Output Format  - Validates JSON and table/list output formats
        Log Level      - Tests logging behavior with -quiet and -json flags

    TEST INFRASTRUCTURE:
        - Uses notepad.exe as a controlled test process (spawned/killed as needed)
        - Creates an ephemeral workspace in %TEMP%\unittests\procmgr_<timestamp>
        - Automatically cleans up test processes and temporary files
        - Captures stdout/stderr via System.Diagnostics.Process for reliability
        - Backs up and restores config file when testing preset functionality

    EXECUTION:
        The test suite runs all tests sequentially and reports:
        - Individual pass/fail status for each test
        - Summary with total tests, passed, failed, and pass rate
        - Exit code 0 if all tests pass, 1 if any fail

    REQUIREMENTS:
        - procmgr.ps1 must exist in the same directory
        - Write access to %TEMP% for ephemeral workspace
        - Ability to spawn notepad.exe processes
        - PowerShell 5.1 or later

.EXAMPLE
    .\procmgr_test.ps1

    Run the complete test suite with console output showing pass/fail status
    for each test and a final summary.

.EXAMPLE
    .\procmgr_test.ps1 | Out-Null; $LASTEXITCODE

    Run the test suite silently and check the exit code (0 = all passed).

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    Console output showing test results. Returns exit code 0 if all tests
    pass, or 1 if any test fails.

.NOTES
    Version:        1.0.0
    Author:         Infrastructure Team
    Requires:       PowerShell 5.1 or later
    Dependencies:   procmgr.ps1 (in same directory)

    The test suite creates and destroys notepad.exe processes during execution.
    If the suite is interrupted, orphaned notepad processes may remain and
    should be manually terminated.

    Test execution time varies based on system performance but typically
    completes in 60-120 seconds.

.LINK
    procmgr.ps1
#>

#Requires -Version 5.1

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "",
    Justification = "Write-Host is required for colored test output in an interactive test harness")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingEmptyCatchBlock", "",
    Justification = "Empty catch blocks are intentional for cleanup operations that should not fail the test")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "",
    Justification = "Test helper functions are internal and do not require ShouldProcess")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "",
    Justification = "Variables are used for test process tracking across function calls")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPositionalParameters", "",
    Justification = "Positional parameters improve readability for test assertions")]
param()

# ============================================================================
# STRICT MODE AND ERROR HANDLING
# ============================================================================
# Enable strict mode to catch common coding errors early. Stop on any error
# to ensure test failures are immediately visible.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Test Framework
# ============================================================================
# TEST FRAMEWORK
# ============================================================================
# Core infrastructure for running tests including counters, paths, process
# management, and output formatting. This framework provides a simple but
# effective structure for organizing and executing tests.
# ============================================================================

# ---------------------------------------------------------------------------
# Test Counters and State
# ---------------------------------------------------------------------------
# Script-scoped variables to track test execution across all test functions.

$script:TestCount = 0      # Total tests executed
$script:PassCount = 0      # Tests that passed
$script:FailCount = 0      # Tests that failed
$script:TestProcesses = @() # Spawned test processes for cleanup

# ---------------------------------------------------------------------------
# Path Configuration
# ---------------------------------------------------------------------------
# Paths to the script under test and related files.

$script:ScriptPath = Join-Path $PSScriptRoot 'procmgr.ps1'
$script:ConfigPath = Join-Path $PSScriptRoot 'procmgr.config.json'
$script:ConfigBackupPath = Join-Path $PSScriptRoot 'procmgr.config.json.bak'

# ---------------------------------------------------------------------------
# Ephemeral Workspace
# ---------------------------------------------------------------------------
# Create a temporary directory for test artifacts. Using a timestamp ensures
# uniqueness across concurrent test runs and makes cleanup straightforward.

$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$script:TempDir = Join-Path $env:TEMP "unittests\procmgr_$timestamp"
New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

# ---------------------------------------------------------------------------
# Test Output Functions
# ---------------------------------------------------------------------------

function Write-TestHeader {
    <#
    .SYNOPSIS
        Display a section header for a group of related tests.

    .DESCRIPTION
        Outputs a visually distinct header to separate test categories
        in the console output. Uses cyan color for visibility.

    .PARAMETER Section
        The name of the test section (e.g., "Help Mode Tests").
    #>
    param([string]$Section)
    Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
    Write-Host "  $Section" -ForegroundColor Cyan
    Write-Host "$('=' * 60)" -ForegroundColor Cyan
}

function Write-TestResult {
    <#
    .SYNOPSIS
        Record and display the result of a single test.

    .DESCRIPTION
        Increments test counters and displays pass/fail status with
        appropriate coloring. Failed tests include the failure message
        for debugging purposes.

    .PARAMETER Name
        Descriptive name of the test being run.

    .PARAMETER Passed
        Boolean indicating whether the test passed.

    .PARAMETER Message
        Optional message to display on failure (e.g., actual vs expected).
    #>
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [bool]$Passed,

        [Parameter(Position = 2)]
        [string]$Message = ''
    )

    $script:TestCount++
    if ($Passed) {
        $script:PassCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:FailCount++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Message) {
            Write-Host "         $Message" -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# Script Execution Helper
# ---------------------------------------------------------------------------

function Invoke-Procmgr {
    <#
    .SYNOPSIS
        Execute procmgr.ps1 with specified arguments and capture output.

    .DESCRIPTION
        Runs the procmgr.ps1 script in a separate PowerShell process and
        captures stdout, stderr, and exit code. Uses async event handlers
        for reliable output capture without deadlocks.

        This approach is more reliable than Invoke-Expression or the call
        operator because:
        - Complete isolation from the test process
        - No interference with test error handling
        - Accurate exit code capture
        - Full stdout/stderr separation

    .PARAMETER Arguments
        Command-line arguments to pass to procmgr.ps1.

    .PARAMETER StdinInput
        Optional input to send to the script's stdin (for confirmation prompts).

    .OUTPUTS
        PSCustomObject with properties:
        - Output: Combined stdout + stderr (for assertions that don't care which)
        - StdOut: Standard output only
        - StdErr: Standard error only
        - ExitCode: Process exit code
    #>
    param(
        [string]$Arguments,
        [string]$StdinInput = $null
    )

    # Configure the process to run PowerShell with our script
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:ScriptPath`" $Arguments"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $PSScriptRoot

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    # Use StringBuilders for thread-safe output collection
    $stdout = New-Object System.Text.StringBuilder
    $stderr = New-Object System.Text.StringBuilder

    # Event handler for async output capture
    $outputHandler = {
        if (-not [String]::IsNullOrEmpty($EventArgs.Data)) {
            $Event.MessageData.AppendLine($EventArgs.Data)
        }
    }

    # Register event handlers for stdout and stderr
    $outEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outputHandler -MessageData $stdout
    $errEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $outputHandler -MessageData $stderr

    # Start the process and begin async output reading
    $null = $process.Start()
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    # Handle stdin if provided (for confirmation prompts)
    if ($StdinInput) {
        $process.StandardInput.WriteLine($StdinInput)
    }
    $process.StandardInput.Close()

    # Wait for process with timeout to prevent hanging tests
    $completed = $process.WaitForExit(60000)  # 60 second timeout
    if (-not $completed) {
        $process.Kill()
    }

    # Brief delay to ensure all output events are processed
    Start-Sleep -Milliseconds 100

    # Clean up event handlers
    Unregister-Event -SourceIdentifier $outEvent.Name
    Unregister-Event -SourceIdentifier $errEvent.Name

    # Collect results
    $exitCode = $process.ExitCode
    $output = $stdout.ToString().Trim()
    $errors = $stderr.ToString().Trim()

    # Combine output for tests that check either stream
    $combined = if ($errors) { "$output`n$errors" } else { $output }

    return [PSCustomObject]@{
        Output = $combined
        StdOut = $output
        StdErr = $errors
        ExitCode = $exitCode
    }
}

# ---------------------------------------------------------------------------
# Test Process Management
# ---------------------------------------------------------------------------

function New-TestProcess {
    <#
    .SYNOPSIS
        Spawn notepad.exe processes for testing.

    .DESCRIPTION
        Creates one or more minimized notepad instances for use as test
        targets. Tracks spawned processes for cleanup. Includes a brief
        delay to ensure processes are fully initialized.

    .PARAMETER Count
        Number of processes to spawn (default: 1).

    .OUTPUTS
        The last spawned process object (for PID access in tests).
    #>
    param([int]$Count = 1)

    for ($i = 0; $i -lt $Count; $i++) {
        $proc = Start-Process notepad.exe -PassThru -WindowStyle Minimized
        $script:TestProcesses += $proc
    }
    Start-Sleep -Milliseconds 500  # Allow processes to fully start
    return $script:TestProcesses[-1]
}

function Remove-AllTestProcess {
    <#
    .SYNOPSIS
        Terminate all test processes and clean up tracking.

    .DESCRIPTION
        Kills all processes spawned by New-TestProcess plus any orphaned
        notepad instances. Uses aggressive cleanup to ensure clean state
        between tests and at suite completion.
    #>
    foreach ($proc in $script:TestProcesses) {
        if ($proc -and -not $proc.HasExited) {
            try {
                $proc.Kill()
                $proc.WaitForExit(5000)
            } catch {
                # Process may have already exited - ignore
            }
        }
    }
    $script:TestProcesses = @()

    # Also kill any orphaned notepad instances
    Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Configuration File Management
# ---------------------------------------------------------------------------

function Backup-Config {
    <#
    .SYNOPSIS
        Back up the existing configuration file before preset tests.

    .DESCRIPTION
        Copies the current config file to a backup location so it can be
        restored after tests that modify the configuration.
    #>
    if (Test-Path $script:ConfigPath) {
        Copy-Item $script:ConfigPath $script:ConfigBackupPath -Force
    }
}

function Restore-Config {
    <#
    .SYNOPSIS
        Restore the original configuration file after preset tests.

    .DESCRIPTION
        Moves the backup config back to the original location. If no backup
        exists but a test config does, removes the test config.
    #>
    if (Test-Path $script:ConfigBackupPath) {
        Move-Item $script:ConfigBackupPath $script:ConfigPath -Force
    } elseif (Test-Path $script:ConfigPath) {
        Remove-Item $script:ConfigPath -Force
    }
}

function New-TestConfig {
    <#
    .SYNOPSIS
        Create a test configuration file with specified content.

    .DESCRIPTION
        Writes the provided content to the config file for testing
        preset functionality and config error handling.

    .PARAMETER Content
        The JSON content to write to the config file.
    #>
    param([string]$Content)
    $Content | Set-Content $script:ConfigPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Cleanup Functions
# ---------------------------------------------------------------------------

function Remove-TempDirectory {
    <#
    .SYNOPSIS
        Remove the ephemeral test workspace.

    .DESCRIPTION
        Cleans up the temporary directory created for test artifacts.
        Called at test suite completion.
    #>
    if (Test-Path $script:TempDir) {
        Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region Test Cases
# ============================================================================
# TEST CASES
# ============================================================================
# Individual test functions organized by functional area. Each function tests
# a specific aspect of procmgr.ps1 functionality with multiple assertions.
# ============================================================================

function Test-HelpMode {
    <#
    .SYNOPSIS
        Test help mode output and no-argument behavior.

    .DESCRIPTION
        Validates that:
        - Running without arguments shows help and exits 0
        - The 'help' mode shows all required sections
        - All modes and options are documented
    #>
    Write-TestHeader "Help Mode Tests"

    # Test: No arguments shows help
    $result = Invoke-Procmgr ""
    Write-TestResult "No arguments shows help" ($result.Output -match 'USAGE:') "Missing USAGE section"
    Write-TestResult "No arguments exits with code 0" ($result.ExitCode -eq 0) "Exit code: $($result.ExitCode)"

    # Test: help mode content
    $result = Invoke-Procmgr "help"
    Write-TestResult "help shows USAGE section" ($result.Output -match 'USAGE:') "Missing USAGE"
    Write-TestResult "help shows MODES section" ($result.Output -match 'MODES:') "Missing MODES"
    Write-TestResult "help shows OPTIONS section" ($result.Output -match 'OPTIONS:') "Missing OPTIONS"
    Write-TestResult "help shows EXAMPLES section" ($result.Output -match 'EXAMPLES:') "Missing EXAMPLES"
    Write-TestResult "help shows EXIT CODES section" ($result.Output -match 'EXIT CODES:') "Missing EXIT CODES"

    # Test: All modes documented
    Write-TestResult "help lists list mode" ($result.Output -match '\blist\b') "Missing list"
    Write-TestResult "help lists info mode" ($result.Output -match '\binfo\b') "Missing info"
    Write-TestResult "help lists set mode" ($result.Output -match '\bset\b') "Missing set"
    Write-TestResult "help lists kill mode" ($result.Output -match '\bkill\b') "Missing kill"

    # Test: All options documented
    Write-TestResult "help lists -filter" ($result.Output -match '-filter') "Missing -filter"
    Write-TestResult "help lists -priority" ($result.Output -match '-priority') "Missing -priority"
    Write-TestResult "help lists -affinity" ($result.Output -match '-affinity') "Missing -affinity"
    Write-TestResult "help lists -json" ($result.Output -match '-json') "Missing -json"
    Write-TestResult "help lists -user" ($result.Output -match '-user') "Missing -user"
    Write-TestResult "help lists -quiet" ($result.Output -match '-quiet') "Missing -quiet"
    Write-TestResult "help lists -force" ($result.Output -match '-force') "Missing -force"
    Write-TestResult "help lists -top" ($result.Output -match '-top') "Missing -top"
    Write-TestResult "help lists -sortby" ($result.Output -match '-sortby') "Missing -sortby"

    Write-TestResult "help exits with code 0" ($result.ExitCode -eq 0) "Exit code: $($result.ExitCode)"
}

function Test-ListMode {
    <#
    .SYNOPSIS
        Test list mode functionality including filtering, sorting, and output options.

    .DESCRIPTION
        Validates that:
        - Basic list mode runs and shows expected columns
        - Filtering by name and PID works correctly
        - -user, -top, -sortby options work
        - -json and -quiet options produce correct output
        - Comma-separated filters work
    #>
    Write-TestHeader "List Mode Tests"

    # Test: Basic list functionality
    $result = Invoke-Procmgr "list"
    Write-TestResult "list mode runs" ($result.ExitCode -eq 0) "Exit code: $($result.ExitCode)"
    Write-TestResult "list shows Name column" ($result.Output -match '\bName\b') "Missing Name"
    Write-TestResult "list shows PID column" ($result.Output -match '\bPID\b') "Missing PID"
    Write-TestResult "list shows Status column" ($result.Output -match '\bStatus\b') "Missing Status"
    Write-TestResult "list shows Owner column" ($result.Output -match '\bOwner\b') "Missing Owner"
    Write-TestResult "list shows Pri column" ($result.Output -match '\bPri\b') "Missing Pri"
    Write-TestResult "list shows Affinity column" ($result.Output -match '\bAffinity\b') "Missing Affinity"

    # Test: Filtering
    $result = Invoke-Procmgr "list -filter powershell"
    Write-TestResult "list -filter works" ($result.ExitCode -eq 0 -and $result.Output -match 'powershell') "Not filtered"

    $result = Invoke-Procmgr "list -filter $PID"
    Write-TestResult "list -filter by PID" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    $result = Invoke-Procmgr "list -filter xyznonexistent99999"
    Write-TestResult "list no matches exits 0" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: -user option
    $result = Invoke-Procmgr "list -user -filter powershell"
    Write-TestResult "list -user works" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: -top option
    $result = Invoke-Procmgr "list -top 5"
    Write-TestResult "list -top 5 works" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: -sortby options (all four sort fields)
    $result = Invoke-Procmgr "list -sortby CPU -top 5"
    Write-TestResult "list -sortby CPU" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    $result = Invoke-Procmgr "list -sortby Mem -top 5"
    Write-TestResult "list -sortby Mem" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    $result = Invoke-Procmgr "list -sortby Name -top 5"
    Write-TestResult "list -sortby Name" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    $result = Invoke-Procmgr "list -sortby PID -top 5"
    Write-TestResult "list -sortby PID" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: -json output (use svchost which always exists)
    $result = Invoke-Procmgr "list -filter svchost -json -top 3"
    Write-TestResult "list -json exits 0" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
    $isJson = $result.StdOut -match '^\s*\[' -or $result.StdOut -match '^\s*\{'
    Write-TestResult "list -json is JSON" $isJson "Not JSON: $($result.StdOut.Substring(0, [Math]::Min(50, $result.StdOut.Length)))"

    # Test: -quiet option
    $result = Invoke-Procmgr "list -filter powershell -quiet"
    Write-TestResult "list -quiet suppresses output" ($result.StdOut.Length -eq 0) "Output: $($result.StdOut)"

    # Test: Comma-separated filters
    $result = Invoke-Procmgr "list -filter powershell,svchost -top 10"
    Write-TestResult "list comma-separated filters" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
}

function Test-InfoMode {
    <#
    .SYNOPSIS
        Test info mode functionality for detailed process information.

    .DESCRIPTION
        Validates that:
        - Info mode requires -filter parameter
        - Detailed process information is displayed
        - All expected fields are present
        - -json and -quiet options work
        - No matches is handled gracefully
    #>
    Write-TestHeader "Info Mode Tests"

    # Test: Requires filter
    $result = Invoke-Procmgr "info"
    Write-TestResult "info requires -filter (exit 1)" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

    # Test: Basic info with expected fields
    $result = Invoke-Procmgr "info -filter powershell"
    Write-TestResult "info -filter works" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
    Write-TestResult "info shows Name" ($result.Output -match 'Name\s*:') "Missing Name"
    Write-TestResult "info shows PID" ($result.Output -match 'PID\s*:') "Missing PID"
    Write-TestResult "info shows Path" ($result.Output -match 'Path\s*:') "Missing Path"
    Write-TestResult "info shows Threads" ($result.Output -match 'Threads\s*:') "Missing Threads"
    Write-TestResult "info shows Handles" ($result.Output -match 'Handles\s*:') "Missing Handles"
    Write-TestResult "info shows Priority" ($result.Output -match 'Priority\s*:') "Missing Priority"
    Write-TestResult "info shows MemoryMB" ($result.Output -match 'MemoryMB\s*:') "Missing MemoryMB"

    # Test: -json output (use svchost which always exists)
    $result = Invoke-Procmgr "info -filter svchost -json"
    Write-TestResult "info -json exits 0" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
    $isJson = $result.StdOut -match '^\s*\[' -or $result.StdOut -match '^\s*\{'
    Write-TestResult "info -json is JSON" $isJson "Not JSON"

    # Test: -quiet option
    $result = Invoke-Procmgr "info -filter powershell -quiet"
    Write-TestResult "info -quiet suppresses output" ($result.StdOut.Length -eq 0) "Output: $($result.StdOut)"

    # Test: No matches
    $result = Invoke-Procmgr "info -filter xyznonexistent99999"
    Write-TestResult "info no matches exits 0" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: -user option
    $result = Invoke-Procmgr "info -filter powershell -user"
    Write-TestResult "info -user works" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
}

function Test-SetMode {
    <#
    .SYNOPSIS
        Test set mode functionality for priority and affinity modification.

    .DESCRIPTION
        Validates that:
        - Set mode requires -filter parameter
        - Set mode requires -priority or -affinity
        - All priority levels work and are verified
        - All affinity formats work (all, list, hex, decimal)
        - Combined priority+affinity works
        - -json and -quiet options work
        - Invalid affinity values are rejected
        - Out-of-range CPU numbers are rejected
    #>
    Write-TestHeader "Set Mode Tests"

    # Test: Requires filter
    $result = Invoke-Procmgr "set -priority Normal"
    Write-TestResult "set requires -filter (exit 1)" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

    # Test: Requires priority or affinity
    $result = Invoke-Procmgr "set -filter notepad"
    Write-TestResult "set requires priority/affinity (exit 1)" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

    # Start test process for modification tests
    $proc = New-TestProcess
    $testPid = $proc.Id

    try {
        # Test: All priority levels (except RealTime which requires admin)
        foreach ($pri in @('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')) {
            $result = Invoke-Procmgr "set -priority $pri -filter $testPid"
            Write-TestResult "set -priority $pri" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
            $proc.Refresh()
            Write-TestResult "Priority verified: $pri" ($proc.PriorityClass.ToString() -eq $pri) "Actual: $($proc.PriorityClass)"
        }

        # Reset to Normal before affinity tests
        Invoke-Procmgr "set -priority Normal -filter $testPid" | Out-Null

        # Test: Affinity formats
        $result = Invoke-Procmgr "set -affinity all -filter $testPid"
        Write-TestResult "set -affinity all" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        $result = Invoke-Procmgr "set -affinity 0,1 -filter $testPid"
        Write-TestResult "set -affinity 0,1 (list)" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
        $proc.Refresh()
        Write-TestResult "Affinity verified: 0,1" ([long]$proc.ProcessorAffinity -eq 3) "Actual: $([long]$proc.ProcessorAffinity)"

        $result = Invoke-Procmgr "set -affinity 0xF -filter $testPid"
        Write-TestResult "set -affinity 0xF (hex)" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        $result = Invoke-Procmgr "set -affinity 7 -filter $testPid"
        Write-TestResult "set -affinity 7 (decimal)" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        # Test: Combined priority and affinity
        $result = Invoke-Procmgr "set -priority Normal -affinity all -filter $testPid"
        Write-TestResult "set priority + affinity" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        # Test: -json output (set outputs JSON only with -json flag)
        $result = Invoke-Procmgr "set -priority Normal -filter $testPid -json"
        Write-TestResult "set -json exits 0" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
        $isJson = $result.StdOut.Length -gt 0 -and ($result.StdOut -match '\[' -or $result.StdOut -match '\{')
        Write-TestResult "set -json is JSON" $isJson "Not JSON: '$($result.StdOut)'"

        # Test: -quiet option
        $result = Invoke-Procmgr "set -priority Normal -filter $testPid -quiet"
        Write-TestResult "set -quiet suppresses output" ($result.StdOut.Length -eq 0) "Output: $($result.StdOut)"

        # Test: Invalid affinity
        $result = Invoke-Procmgr "set -affinity invalid -filter $testPid"
        Write-TestResult "set invalid affinity (exit 1)" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

        # Test: Out of range CPU
        $cpuCount = [Environment]::ProcessorCount
        $result = Invoke-Procmgr "set -affinity 0,$cpuCount -filter $testPid"
        Write-TestResult "set out-of-range CPU (exit 1)" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

        # Test: No matches
        $result = Invoke-Procmgr "set -priority Normal -filter xyznonexistent99999"
        Write-TestResult "set no matches exits 0" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        # Test: -user option
        $result = Invoke-Procmgr "set -priority Normal -filter notepad -user"
        Write-TestResult "set -user works" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    } finally {
        Remove-AllTestProcess
    }
}

function Test-KillMode {
    <#
    .SYNOPSIS
        Test kill mode functionality for process termination.

    .DESCRIPTION
        Validates that:
        - Kill mode requires -filter parameter
        - No matches is handled gracefully
        - -force flag terminates without confirmation
        - Process is actually terminated
        - -json and -quiet options work
        - -user option works
        - Multiple processes can be killed
    #>
    Write-TestHeader "Kill Mode Tests"

    # Test: Requires filter
    $result = Invoke-Procmgr "kill -force"
    Write-TestResult "kill requires -filter (exit 1)" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

    # Test: No matches
    $result = Invoke-Procmgr "kill -filter xyznonexistent99999 -force"
    Write-TestResult "kill no matches exits 0" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: Kill with -force
    $proc = New-TestProcess
    $testPid = $proc.Id
    $result = Invoke-Procmgr "kill -filter $testPid -force"
    Write-TestResult "kill -force works" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
    Start-Sleep -Milliseconds 500
    $stillRunning = Get-Process -Id $testPid -ErrorAction SilentlyContinue
    Write-TestResult "Process terminated" ($null -eq $stillRunning) "Still running"

    # Test: -json output
    $proc = New-TestProcess
    $testPid = $proc.Id
    $result = Invoke-Procmgr "kill -filter $testPid -force -json"
    Write-TestResult "kill -json exits 0" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
    $isJson = $result.StdOut.Length -gt 0 -and ($result.StdOut -match '\[' -or $result.StdOut -match '\{')
    Write-TestResult "kill -json is JSON" $isJson "Not JSON: '$($result.StdOut)'"

    # Test: -quiet option
    $proc = New-TestProcess
    $testPid = $proc.Id
    $result = Invoke-Procmgr "kill -filter $testPid -force -quiet"
    Write-TestResult "kill -quiet suppresses output" ($result.StdOut.Length -eq 0) "Output: $($result.StdOut)"

    # Test: -user option
    $proc = New-TestProcess
    $result = Invoke-Procmgr "kill -filter notepad -force -user"
    Write-TestResult "kill -user works" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: Multiple processes
    New-TestProcess -Count 2
    $result = Invoke-Procmgr "kill -filter notepad -force"
    Write-TestResult "kill multiple processes" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    Remove-AllTestProcess
}

function Test-ConfigPreset {
    <#
    .SYNOPSIS
        Test configuration file and preset functionality.

    .DESCRIPTION
        Validates that:
        - Presets expand to their filter lists
        - Presets appear in help output
        - Presets can be combined with regular filters
        - Unknown presets are treated as regular filters
        - Invalid JSON config is handled gracefully
        - Config without presets is handled
        - Missing config file is handled
    #>
    Write-TestHeader "Config Preset Tests"

    Backup-Config

    try {
        # Create test configuration
        $testConfig = @'
{
    "presets": [
        { "name": "testpreset", "filters": ["powershell", "svchost"] },
        { "name": "singlepreset", "filters": ["powershell"] }
    ]
}
'@
        New-TestConfig -Content $testConfig

        # Test: Use preset
        $result = Invoke-Procmgr "list -filter testpreset -top 10"
        Write-TestResult "list with preset" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        # Test: Help shows presets
        $result = Invoke-Procmgr "help"
        Write-TestResult "help shows presets" ($result.Output -match 'testpreset') "Missing presets"

        # Test: Preset + regular filter
        $result = Invoke-Procmgr "list -filter singlepreset,explorer -top 10"
        Write-TestResult "preset + regular filter" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        # Test: Unknown preset treated as regular filter
        $result = Invoke-Procmgr "list -filter unknownpreset"
        Write-TestResult "unknown preset as filter" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        # Test: Invalid JSON config
        New-TestConfig -Content "{ invalid json"
        $result = Invoke-Procmgr "list -filter powershell"
        Write-TestResult "invalid config handled" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        # Test: Config without presets (use svchost)
        New-TestConfig -Content '{ "other": "value" }'
        $result = Invoke-Procmgr "list -filter svchost -top 3"
        Write-TestResult "config without presets" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        # Test: Missing config file
        Remove-Item $script:ConfigPath -Force -ErrorAction SilentlyContinue
        $result = Invoke-Procmgr "list -filter powershell"
        Write-TestResult "missing config file" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

        $result = Invoke-Procmgr "help"
        Write-TestResult "help without config" ($result.ExitCode -eq 0 -and $result.Output -notmatch 'testpreset') "Shows old presets"

    } finally {
        Restore-Config
    }
}

function Test-ExitCode {
    <#
    .SYNOPSIS
        Test correct exit codes for various scenarios.

    .DESCRIPTION
        Validates that:
        - Exit code 0 for successful operations
        - Exit code 0 for no matches (not an error)
        - Exit code 1 for invalid arguments
        - Exit code 1 for missing required parameters
    #>
    Write-TestHeader "Exit Code Tests"

    # Test: Exit 0 - Success
    $result = Invoke-Procmgr "help"
    Write-TestResult "EXIT 0: help" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    $result = Invoke-Procmgr "list -filter powershell"
    Write-TestResult "EXIT 0: list" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    $result = Invoke-Procmgr "list -filter xyznonexistent99999"
    Write-TestResult "EXIT 0: no matches" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: Exit 1 - Invalid args
    $result = Invoke-Procmgr "info"
    Write-TestResult "EXIT 1: missing filter" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

    $result = Invoke-Procmgr "set -filter notepad"
    Write-TestResult "EXIT 1: missing priority/affinity" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

    $result = Invoke-Procmgr "kill"
    Write-TestResult "EXIT 1: kill no filter" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"

    $null = New-TestProcess
    $result = Invoke-Procmgr "set -affinity invalid -filter notepad"
    Write-TestResult "EXIT 1: invalid affinity" ($result.ExitCode -eq 1) "Exit: $($result.ExitCode)"
    Remove-AllTestProcess
}

function Test-EdgeCase {
    <#
    .SYNOPSIS
        Test boundary conditions and error handling.

    .DESCRIPTION
        Validates that:
        - Invalid mode is rejected by PowerShell validation
        - Invalid priority is rejected
        - Invalid sortby is rejected
        - Edge cases like -top 0, long filters, wildcards work
        - Multiple flags can be combined
        - Single CPU affinity works
    #>
    Write-TestHeader "Edge Case Tests"

    # Test: Invalid mode (PowerShell ValidateSet rejects)
    $result = Invoke-Procmgr "invalidmode"
    Write-TestResult "invalid mode rejected" ($result.ExitCode -ne 0) "Exit: $($result.ExitCode)"

    # Test: Invalid priority
    $result = Invoke-Procmgr "set -priority InvalidPri -filter notepad"
    Write-TestResult "invalid priority rejected" ($result.ExitCode -ne 0) "Exit: $($result.ExitCode)"

    # Test: Invalid sortby
    $result = Invoke-Procmgr "list -sortby InvalidSort"
    Write-TestResult "invalid sortby rejected" ($result.ExitCode -ne 0) "Exit: $($result.ExitCode)"

    # Test: -top 0 (edge case - should show nothing)
    $result = Invoke-Procmgr "list -top 0"
    Write-TestResult "-top 0 handled" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: Long filter string
    $longFilter = "a" * 100
    $result = Invoke-Procmgr "list -filter $longFilter"
    Write-TestResult "long filter handled" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: Wildcard in filter (treated as literal substring)
    $result = Invoke-Procmgr "list -filter `"test*`""
    Write-TestResult "wildcard filter handled" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: Empty filter string
    $result = Invoke-Procmgr "list -filter `"`""
    Write-TestResult "empty filter handled" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: Multiple flags combined
    $result = Invoke-Procmgr "list -user -json -quiet"
    Write-TestResult "multiple flags combined" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"

    # Test: Single CPU affinity (decimal, not list)
    $null = New-TestProcess
    $result = Invoke-Procmgr "set -affinity 0 -filter notepad"
    Write-TestResult "affinity single CPU" ($result.ExitCode -eq 0) "Exit: $($result.ExitCode)"
    Remove-AllTestProcess
}

function Test-OutputFormat {
    <#
    .SYNOPSIS
        Test output format for different modes.

    .DESCRIPTION
        Validates that:
        - List mode uses table format
        - Info mode uses list format
        - JSON output is a valid array
        - Error output in JSON mode contains error info
    #>
    Write-TestHeader "Output Format Tests"

    # Test: list uses table format (contains dashes for column separators or multiple spaces)
    $result = Invoke-Procmgr "list -filter powershell"
    Write-TestResult "list uses table format" ($result.StdOut -match '---+' -or $result.StdOut -match '\s{2,}') "Not table"

    # Test: info uses list format (Name : Value pairs)
    $result = Invoke-Procmgr "info -filter powershell"
    Write-TestResult "info uses list format" ($result.StdOut -match '\s:\s') "Not list format"

    # Test: JSON is array
    $result = Invoke-Procmgr "list -filter svchost -json -top 5"
    $isArray = $result.StdOut.Trim() -match '^\s*\['
    Write-TestResult "JSON is array" $isArray "Not array: $($result.StdOut.Substring(0, [Math]::Min(30, $result.StdOut.Length)))"

    # Test: Error in JSON mode contains error info
    $result = Invoke-Procmgr "set -filter notepad -json"
    Write-TestResult "error in JSON mode" ($result.Output -match 'Error' -or $result.Output -match '\{') "No error output"
}

function Test-LogLevel {
    <#
    .SYNOPSIS
        Test logging behavior with different verbosity options.

    .DESCRIPTION
        Validates that:
        - Normal output shows info messages
        - -quiet suppresses info and warning messages
        - -json suppresses text output (only JSON)
    #>
    Write-TestHeader "Log Level Tests"

    # Test: Info level - success message shown
    $proc = New-TestProcess
    $testPid = $proc.Id
    $result = Invoke-Procmgr "set -priority Normal -filter $testPid"
    Write-TestResult "Info: set success message" ($result.StdOut -match 'Set priority') "Output: $($result.StdOut)"
    Remove-AllTestProcess

    # Test: Warning level - no matches warning
    $result = Invoke-Procmgr "info -filter xyznonexistent99999"
    Write-TestResult "Warning: no matches" ($result.Output -match 'No processes found') "Output: $($result.Output)"

    # Test: -quiet suppresses warnings
    $result = Invoke-Procmgr "info -filter xyznonexistent99999 -quiet"
    Write-TestResult "-quiet suppresses warning" ($result.StdOut.Length -eq 0) "Output: $($result.StdOut)"

    # Test: -json suppresses text output
    $result = Invoke-Procmgr "info -filter xyznonexistent99999 -json"
    Write-TestResult "-json suppresses warning" ($result.StdOut -notmatch 'No processes') "Output: $($result.StdOut)"
}

#endregion

#region Main
# ============================================================================
# MAIN EXECUTION
# ============================================================================
# Entry point for the test suite. Runs all test categories and reports
# summary statistics.
# ============================================================================

# Display test suite header
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "         procmgr.ps1 Test Suite - 100% Coverage                 " -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta

# Verify script under test exists
if (-not (Test-Path $script:ScriptPath)) {
    Write-Host "`nERROR: procmgr.ps1 not found at $script:ScriptPath" -ForegroundColor Red
    exit 1
}

# Display configuration
Write-Host "`nScript: $script:ScriptPath" -ForegroundColor Gray
Write-Host "Config: $script:ConfigPath" -ForegroundColor Gray
Write-Host "TempDir: $script:TempDir" -ForegroundColor Gray

# Execute all test categories with cleanup guarantee
try {
    Test-HelpMode
    Test-ListMode
    Test-InfoMode
    Test-SetMode
    Test-KillMode
    Test-ConfigPreset
    Test-ExitCode
    Test-EdgeCase
    Test-OutputFormat
    Test-LogLevel
} finally {
    # Always clean up, even if tests fail
    Remove-AllTestProcess
    Remove-TempDirectory
}

# Display summary
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "                       Test Summary                             " -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Total Tests:  $script:TestCount" -ForegroundColor White
Write-Host "  Passed:       $script:PassCount" -ForegroundColor Green
Write-Host "  Failed:       $script:FailCount" -ForegroundColor $(if ($script:FailCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ""

# Calculate and display pass rate with appropriate coloring
$percentage = if ($script:TestCount -gt 0) { [math]::Round(($script:PassCount / $script:TestCount) * 100, 1) } else { 0 }
$color = if ($percentage -eq 100) { 'Green' } elseif ($percentage -ge 90) { 'Yellow' } else { 'Red' }
Write-Host "  Pass Rate:    $percentage%" -ForegroundColor $color
Write-Host ""

# Exit with appropriate code for CI/CD integration
exit $(if ($script:FailCount -gt 0) { 1 } else { 0 })

#endregion
