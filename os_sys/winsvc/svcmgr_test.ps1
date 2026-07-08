#Requires -Version 5.1
<#
.SYNOPSIS
    Test suite for svcmgr.ps1 - 100% functionality coverage.

.DESCRIPTION
    Comprehensive test suite that validates all svcmgr.ps1 functionality:
    - Help and version commands
    - Service list display
    - Start, stop, restart operations
    - Status checking with exit codes
    - Quiet mode behavior
    - Plugin commands (reload, test, ping)
    - Auto-start enable/disable/query
    - Log rotation
    - Error handling

    Prerequisites:
    - Services (nginx, gitea, sftpgo) should be configured in services/*.json
    - All services must be running for full test coverage
    - The test suite will start any stopped services before running

.PARAMETER ShowCommands
    Display the svcmgr.ps1 commands being executed during tests.
    Useful for debugging test failures.

.EXAMPLE
    .\svcmgr_test.ps1
    Run all tests with standard output.

.EXAMPLE
    .\svcmgr_test.ps1 -ShowCommands
    Run all tests showing each command being executed.

.OUTPUTS
    Test results summary with pass/fail counts.
    Exit code 0 if all tests pass, 1 if any fail.

.NOTES
    Version: 1.2.0
    Tests: 63 total
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "")]
[CmdletBinding()]
param(
    [switch]$ShowCommands
)

#region Initialization

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:SvcMgr = Join-Path $PSScriptRoot "svcmgr.ps1"

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
    Execute svcmgr.ps1 in a subprocess and capture output/exit code.
.DESCRIPTION
    Runs svcmgr.ps1 via powershell.exe to get accurate exit codes
    and isolated execution environment for each test.
#>
function Invoke-SvcMgr {
    param([string]$Arguments)

    if ($ShowCommands) {
        Write-Host "    > svcmgr.ps1 $Arguments" -ForegroundColor DarkGray
    }

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "powershell.exe"
    $pinfo.Arguments = "-ExecutionPolicy Bypass -File `"$script:SvcMgr`" $Arguments"
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

    if ($VerboseOutput -and $stdout) {
        Write-Host $stdout -ForegroundColor DarkGray
    }

    return @{
        Output = $stdout + $stderr
        ExitCode = $process.ExitCode
    }
}

#endregion

#region Prerequisites

<#
.SYNOPSIS
    Check prerequisites and ensure all services are running.
.DESCRIPTION
    Verifies service configs exist and starts any stopped services.
    Tests require live services for full coverage.
#>
function Test-Prerequisites {
    Write-Host "`n=== Checking Prerequisites ===" -ForegroundColor Cyan

    $allGood = $true

    # Check service configs exist
    $servicesDir = Join-Path $PSScriptRoot "services"
    foreach ($svc in @('nginx', 'gitea', 'sftpgo')) {
        $configPath = Join-Path $servicesDir "$svc.json"
        if (Test-Path $configPath) {
            Write-Host "  [OK] $svc.json config found" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] $svc.json config not found" -ForegroundColor Red
            $allGood = $false
        }
    }

    if (-not $allGood) {
        Write-Host "`n  ERROR: Missing service configs. Cannot run tests." -ForegroundColor Red
        exit 1
    }

    # Check and start services
    Write-Host ""
    foreach ($svc in @('nginx', 'gitea', 'sftpgo')) {
        $result = Invoke-SvcMgr "-q $svc status"
        if ($result.ExitCode -eq 0) {
            Write-Host "  [OK] $svc is running" -ForegroundColor Green
        } else {
            Write-Host "  [....] $svc is stopped - starting..." -ForegroundColor Yellow -NoNewline
            $startResult = Invoke-SvcMgr "$svc start"
            Start-Sleep -Milliseconds 1500  # Wait for process to start

            $checkResult = Invoke-SvcMgr "-q $svc status"
            if ($checkResult.ExitCode -eq 0) {
                Write-Host "`r  [OK] $svc started successfully     " -ForegroundColor Green
            } else {
                Write-Host "`r  [FAIL] $svc failed to start        " -ForegroundColor Red
                Write-Host "         $($startResult.Output)" -ForegroundColor Yellow
                $allGood = $false
            }
        }
    }

    if (-not $allGood) {
        Write-Host "`n  ERROR: Not all services could be started. Cannot run tests." -ForegroundColor Red
        Write-Host "  Please start services manually and retry." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "`n  All prerequisites met." -ForegroundColor Green
    return $true
}

#endregion

#region Tests

function Test-Help {
    Write-TestHeader "Help Command"

    # Test: help command
    $result = Invoke-SvcMgr "help"
    Write-TestResult -Test "help shows usage" -Passed ($result.Output -match "Usage:")

    # Test: no args shows help
    $result = Invoke-SvcMgr ""
    Write-TestResult -Test "no args shows help" -Passed ($result.Output -match "Usage:")

    # Test: service help shows help
    $result = Invoke-SvcMgr "nginx help"
    Write-TestResult -Test "service help shows usage" -Passed ($result.Output -match "Usage:")
}

function Test-Version {
    Write-TestHeader "Version Command"

    # Test: -Version flag
    $result = Invoke-SvcMgr "-Version"
    Write-TestResult -Test "-Version shows version" -Passed ($result.Output -match "svcmgr version \d+\.\d+\.\d+")
    Write-TestResult -Test "-Version exits 0" -Passed ($result.ExitCode -eq 0)

    # Test: -v alias
    $result = Invoke-SvcMgr "-v"
    Write-TestResult -Test "-v alias works" -Passed ($result.Output -match "svcmgr version")

    # Test: version command
    $result = Invoke-SvcMgr "version"
    Write-TestResult -Test "version command works" -Passed ($result.Output -match "svcmgr version")
}

function Test-List {
    Write-TestHeader "List Command"

    $result = Invoke-SvcMgr "list"

    Write-TestResult -Test "shows header" -Passed ($result.Output -match "Available services")
    Write-TestResult -Test "lists nginx" -Passed ($result.Output -match "nginx")
    Write-TestResult -Test "lists gitea" -Passed ($result.Output -match "gitea")
    Write-TestResult -Test "lists sftpgo" -Passed ($result.Output -match "sftpgo")
    Write-TestResult -Test "shows status indicators" -Passed ($result.Output -match "\[running\]|\[stopped\]")
    Write-TestResult -Test "exit code 0" -Passed ($result.ExitCode -eq 0)
}

function Test-Status {
    Write-TestHeader "Status Command"

    # Test: single service status
    $result = Invoke-SvcMgr "nginx status"
    Write-TestResult -Test "nginx status output" -Passed ($result.Output -match "nginx is (running|not running)")
    Write-TestResult -Test "shows PID when running" -Passed ($result.Output -match "PID: \d+")

    # Test: all status
    $result = Invoke-SvcMgr "all status"
    $hasAll = ($result.Output -match "nginx") -and ($result.Output -match "gitea") -and ($result.Output -match "sftpgo")
    Write-TestResult -Test "all status shows all services" -Passed $hasAll
}

function Test-QuietMode {
    Write-TestHeader "Quiet Mode"

    # Test: -Quiet suppresses output
    $result = Invoke-SvcMgr "-Quiet nginx status"
    $noOutput = [string]::IsNullOrWhiteSpace($result.Output)
    Write-TestResult -Test "-Quiet suppresses output" -Passed $noOutput

    # Test: -q alias works
    $result = Invoke-SvcMgr "-q nginx status"
    $noOutput = [string]::IsNullOrWhiteSpace($result.Output)
    Write-TestResult -Test "-q alias works" -Passed $noOutput

    # Test: exit code still set in quiet mode
    Write-TestResult -Test "exit code set in quiet mode" -Passed ($result.ExitCode -eq 0 -or $result.ExitCode -eq 1)
}

function Test-ExitCodes {
    Write-TestHeader "Exit Codes"

    # Test: running service status = 0
    $result = Invoke-SvcMgr "-q nginx status"
    Write-TestResult -Test "running service exits 0" -Passed ($result.ExitCode -eq 0) -Details "Got: $($result.ExitCode)"

    # Test: invalid service = error
    $result = Invoke-SvcMgr "nonexistent status"
    Write-TestResult -Test "invalid service exits non-zero" -Passed ($result.ExitCode -ne 0)

    # Test: invalid command = error
    $result = Invoke-SvcMgr "nginx invalidcmd"
    Write-TestResult -Test "invalid command exits non-zero" -Passed ($result.ExitCode -ne 0)
}

function Test-PluginCommands {
    Write-TestHeader "Plugin Commands"

    # Test: nginx test
    $result = Invoke-SvcMgr "nginx test"
    Write-TestResult -Test "nginx test command" -Passed ($result.Output -match "Testing|syntax is ok")

    # Test: nginx reload (only if running)
    $statusResult = Invoke-SvcMgr "-q nginx status"
    if ($statusResult.ExitCode -eq 0) {
        $result = Invoke-SvcMgr "nginx reload"
        Write-TestResult -Test "nginx reload command" -Passed ($result.Output -match "reloaded|Reloading")
    } else {
        Write-Host "  [SKIP] nginx reload (not running)" -ForegroundColor Yellow
    }

    # Test: sftpgo ping
    $result = Invoke-SvcMgr "sftpgo ping"
    Write-TestResult -Test "sftpgo ping command" -Passed ($result.Output -match "Pinging|healthy|not responding")

    # Test: gitea doctor
    $result = Invoke-SvcMgr "gitea doctor"
    Write-TestResult -Test "gitea doctor command" -Passed ($result.Output -match "doctor|Diagnostic|check")

    # Test: case insensitivity
    $result = Invoke-SvcMgr "nginx TEST"
    Write-TestResult -Test "plugin commands case-insensitive" -Passed ($result.Output -match "Testing|syntax")
}

function Test-JsonOutput {
    Write-TestHeader "JSON Output"

    # Test: list -Json produces valid JSON
    $result = Invoke-SvcMgr "list -Json"
    $validJson = $false
    $parsed = $null
    try {
        $parsed = $result.Output | ConvertFrom-Json
        $validJson = $true
    } catch {
        $validJson = $false  # JSON parse failed
    }
    Write-TestResult -Test "list -Json is valid JSON" -Passed $validJson

    # Test: list -Json has required fields
    Write-TestResult -Test "list -Json has version" -Passed ($parsed.version -match "\d+\.\d+\.\d+")
    Write-TestResult -Test "list -Json has timestamp" -Passed ($null -ne $parsed.timestamp)
    Write-TestResult -Test "list -Json has services array" -Passed ($parsed.services -is [array])

    # Test: service status -Json
    $result = Invoke-SvcMgr "nginx status -Json"
    $validJson = $false
    $parsed = $null
    try {
        $parsed = $result.Output | ConvertFrom-Json
        $validJson = $true
    } catch {
        $validJson = $false  # JSON parse failed
    }
    Write-TestResult -Test "status -Json is valid JSON" -Passed $validJson
    Write-TestResult -Test "status -Json has results" -Passed ($parsed.results -is [array])
    Write-TestResult -Test "status -Json has exitCode" -Passed ($null -ne $parsed.exitCode)

    # Test: all status -Json
    $result = Invoke-SvcMgr "all status -Json"
    $validJson = $false
    $parsed = $null
    try {
        $parsed = $result.Output | ConvertFrom-Json
        $validJson = $true
    } catch {
        $validJson = $false  # JSON parse failed
    }
    Write-TestResult -Test "all status -Json is valid JSON" -Passed $validJson
    Write-TestResult -Test "all status -Json has multiple results" -Passed ($parsed.results.Count -ge 3)
}

function Test-LogRotation {
    Write-TestHeader "Log Rotation"

    $result = Invoke-SvcMgr "rotate"

    Write-TestResult -Test "rotate command runs" -Passed ($result.Output -match "Rotat")
    Write-TestResult -Test "rotate exits 0" -Passed ($result.ExitCode -eq 0)
}

function Test-AutoStart {
    Write-TestHeader "Auto-Start (Enable/Disable/Is-Enabled)"

    $testService = "nginx"

    # Test: is-enabled shows status
    $result = Invoke-SvcMgr "$testService is-enabled"
    Write-TestResult -Test "is-enabled shows status" -Passed ($result.Output -match "auto-start: (enabled|disabled)")

    # Save initial state
    $wasEnabled = $result.Output -match "auto-start: enabled"

    # Test: enable creates task
    $result = Invoke-SvcMgr "$testService enable"
    Write-TestResult -Test "enable command" -Passed ($result.Output -match "enabled|already enabled")

    # Verify enabled
    $result = Invoke-SvcMgr "$testService is-enabled"
    Write-TestResult -Test "is-enabled confirms enabled" -Passed ($result.Output -match "auto-start: enabled")

    # Test: is-enabled shows task details
    Write-TestResult -Test "is-enabled shows task details" -Passed ($result.Output -match "Task:|Trigger:|State:")

    # Test: disable removes task
    $result = Invoke-SvcMgr "$testService disable"
    Write-TestResult -Test "disable command" -Passed ($result.Output -match "disabled|not enabled")

    # Verify disabled
    $result = Invoke-SvcMgr "$testService is-enabled"
    Write-TestResult -Test "is-enabled confirms disabled" -Passed ($result.Output -match "auto-start: disabled")

    # Restore initial state if was enabled
    if ($wasEnabled) {
        Invoke-SvcMgr "$testService enable" | Out-Null
    }
}

function Test-StartStopRestart {
    Write-TestHeader "Start/Stop/Restart (gitea)"

    $testService = "gitea"

    # Save initial state
    $initialResult = Invoke-SvcMgr "-q $testService status"
    $wasRunning = $initialResult.ExitCode -eq 0

    # Test: stop
    $result = Invoke-SvcMgr "$testService stop"
    Write-TestResult -Test "stop command" -Passed ($result.Output -match "stopped|not running")

    # Verify stopped
    Start-Sleep -Milliseconds 500
    $result = Invoke-SvcMgr "-q $testService status"
    Write-TestResult -Test "service is stopped" -Passed ($result.ExitCode -eq 1)

    # Test: start
    $result = Invoke-SvcMgr "$testService start"
    Write-TestResult -Test "start command" -Passed ($result.Output -match "started|already running")

    # Verify running
    Start-Sleep -Milliseconds 1000
    $result = Invoke-SvcMgr "-q $testService status"
    Write-TestResult -Test "service is running" -Passed ($result.ExitCode -eq 0)

    # Test: restart
    $result = Invoke-SvcMgr "$testService restart"
    Write-TestResult -Test "restart command" -Passed ($result.Output -match "Restarting|started")

    # Verify still running after restart
    Start-Sleep -Milliseconds 1000
    $result = Invoke-SvcMgr "-q $testService status"
    Write-TestResult -Test "service running after restart" -Passed ($result.ExitCode -eq 0)

    # Restore initial state if was stopped
    if (-not $wasRunning) {
        Invoke-SvcMgr "$testService stop" | Out-Null
    }
}

function Test-AllCommand {
    Write-TestHeader "All Command"

    # Test: all status
    $result = Invoke-SvcMgr "all status"
    $hasAllSections = ($result.Output -match "=== nginx ===") -and
    ($result.Output -match "=== gitea ===") -and
    ($result.Output -match "=== sftpgo ===")
    Write-TestResult -Test "all status shows sections" -Passed $hasAllSections

    # Test: all is-enabled
    $result = Invoke-SvcMgr "all is-enabled"
    $hasAllEnabled = ($result.Output -match "nginx auto-start") -and
    ($result.Output -match "gitea auto-start") -and
    ($result.Output -match "sftpgo auto-start")
    Write-TestResult -Test "all is-enabled shows all" -Passed $hasAllEnabled

    # Test: all stop
    $result = Invoke-SvcMgr "all stop"
    $hasAllStop = ($result.Output -match "=== nginx ===") -and
    ($result.Output -match "=== gitea ===") -and
    ($result.Output -match "=== sftpgo ===")
    Write-TestResult -Test "all stop shows sections" -Passed $hasAllStop

    # Verify all stopped
    Start-Sleep -Milliseconds 1000
    $allStopped = $true
    foreach ($svc in @('nginx', 'gitea', 'sftpgo')) {
        $check = Invoke-SvcMgr "-q $svc status"
        if ($check.ExitCode -eq 0) { $allStopped = $false }
    }
    Write-TestResult -Test "all services stopped" -Passed $allStopped

    # Test: all start
    $result = Invoke-SvcMgr "all start"
    $hasAllStart = ($result.Output -match "=== nginx ===") -and
    ($result.Output -match "=== gitea ===") -and
    ($result.Output -match "=== sftpgo ===")
    Write-TestResult -Test "all start shows sections" -Passed $hasAllStart

    # Verify all running
    Start-Sleep -Milliseconds 1500
    $allRunning = $true
    foreach ($svc in @('nginx', 'gitea', 'sftpgo')) {
        $check = Invoke-SvcMgr "-q $svc status"
        if ($check.ExitCode -ne 0) { $allRunning = $false }
    }
    Write-TestResult -Test "all services running" -Passed $allRunning

    # Test: all restart
    $result = Invoke-SvcMgr "all restart"
    $hasAllRestart = ($result.Output -match "=== nginx ===") -and
    ($result.Output -match "=== gitea ===") -and
    ($result.Output -match "=== sftpgo ===")
    Write-TestResult -Test "all restart shows sections" -Passed $hasAllRestart

    # Verify all still running after restart
    Start-Sleep -Milliseconds 1500
    $allRunningAfter = $true
    foreach ($svc in @('nginx', 'gitea', 'sftpgo')) {
        $check = Invoke-SvcMgr "-q $svc status"
        if ($check.ExitCode -ne 0) { $allRunningAfter = $false }
    }
    Write-TestResult -Test "all services running after restart" -Passed $allRunningAfter
}

function Test-ErrorHandling {
    Write-TestHeader "Error Handling"

    # Test: nonexistent service
    $result = Invoke-SvcMgr "fakeservice status"
    Write-TestResult -Test "invalid service shows error" -Passed ($result.Output -match "ERROR|not found")

    # Test: invalid command returns error
    $result = Invoke-SvcMgr "nginx fakecommand"
    Write-TestResult -Test "invalid command returns error" -Passed ($result.ExitCode -ne 0)
}

function Test-ConfigLoading {
    Write-TestHeader "Config Loading"

    # Test each service config loads correctly by checking status
    $result = Invoke-SvcMgr "nginx status"
    Write-TestResult -Test "nginx config loads" -Passed ($result.ExitCode -eq 0 -or $result.ExitCode -eq 1)

    $result = Invoke-SvcMgr "gitea status"
    Write-TestResult -Test "gitea config loads" -Passed ($result.ExitCode -eq 0 -or $result.ExitCode -eq 1)

    $result = Invoke-SvcMgr "sftpgo status"
    Write-TestResult -Test "sftpgo config loads" -Passed ($result.ExitCode -eq 0 -or $result.ExitCode -eq 1)
}

#endregion

#region Main

Write-Host "========================================" -ForegroundColor White
Write-Host "  svcmgr.ps1 Test Suite" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Check prerequisites and start services if needed
Test-Prerequisites

# Run all tests
Test-Help
Test-Version
Test-List
Test-Status
Test-QuietMode
Test-ExitCodes
Test-ConfigLoading
Test-PluginCommands
Test-JsonOutput
Test-LogRotation
Test-AutoStart
Test-StartStopRestart
Test-AllCommand
Test-ErrorHandling

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
