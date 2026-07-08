#Requires -Version 5.1
<#
.SYNOPSIS
    Unified service control CLI for managing user-space Windows services.

.DESCRIPTION
    svcmgr.ps1 provides a unified interface to manage multiple user-space services
    (nginx, gitea, sftpgo, etc.) without requiring administrator privileges.

    Features:
    - Start, stop, restart, and check status of services
    - Enable/disable auto-start at user logon via Task Scheduler
    - Plugin architecture for service-specific commands (reload, test, ping)
    - Quiet mode for scripting and automation
    - JSON output for CI/CD pipelines and monitoring tools
    - Proper exit codes for CI/CD integration

.PARAMETER Service
    The service name to manage (e.g., nginx, gitea, sftpgo).
    Special values: 'all' (all services), 'list' (show services), 'rotate' (rotate logs).

.PARAMETER Command
    The command to execute: start, stop, restart, status, enable, disable, is-enabled, help.
    Plugin commands are also available (e.g., nginx reload, sftpgo ping).

.PARAMETER Quiet
    Suppress all output. Useful for scripting. Exit codes still indicate success/failure.

.PARAMETER Json
    Output in JSON format for automation and CI/CD pipelines.
    Works with: list, status, start, stop, restart, enable, disable, is-enabled.

.PARAMETER Version
    Display version information and exit.

.EXAMPLE
    .\svcmgr.ps1 nginx start
    Start the nginx service.

.EXAMPLE
    .\svcmgr.ps1 all status
    Check status of all configured services.

.EXAMPLE
    .\svcmgr.ps1 nginx reload
    Reload nginx configuration without restart (plugin command).

.EXAMPLE
    .\svcmgr.ps1 -q nginx status; echo $LASTEXITCODE
    Check nginx status silently, using exit code (0=running, 1=stopped).

.EXAMPLE
    .\svcmgr.ps1 nginx enable
    Enable nginx to start automatically at user logon.

.EXAMPLE
    .\svcmgr.ps1 all status -Json
    Get status of all services in JSON format for automation.

.EXAMPLE
    .\svcmgr.ps1 list -Json | ConvertFrom-Json
    Parse service list as PowerShell object.

.NOTES
    Version: 1.1.0
    Author:  System Administrator
    Requires: PowerShell 5.1+, no administrator privileges needed

.LINK
    See README.md for full documentation.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
param(
    [Parameter(Position = 0, HelpMessage = "Service name, 'all', 'list', or 'rotate'")]
    [string]$Service,

    [Parameter(Position = 1, HelpMessage = "Command to execute (default: help)")]
    [string]$Command = "help",

    [Parameter(HelpMessage = "Suppress all output for scripting")]
    [Alias('q')]
    [switch]$Quiet,

    [Parameter(HelpMessage = "Show version information")]
    [Alias('v')]
    [switch]$Version,

    [Parameter(HelpMessage = "Output in JSON format for automation")]
    [switch]$Json
)

#region Initialization

$script:SvcMgrVersion = "1.1.0"
$ErrorActionPreference = "Stop"
$scriptName = $MyInvocation.MyCommand.Name
$script:ExitCode = 0
$script:JsonResults = @()

# Import the core ProcessControl module
$modulePath = Join-Path $PSScriptRoot "lib\ProcessControl.psm1"
Import-Module $modulePath -Force

#endregion

#region Helper Functions

<#
.SYNOPSIS
    Write output only when not in quiet mode.
.DESCRIPTION
    Respects the -Quiet flag to suppress output for scripting use cases.
#>
function Write-Output-Conditional {
    param(
        [string]$Message,
        [string]$Color
    )
    if (-not $Quiet) {
        if ($Color) {
            Write-Host $Message -ForegroundColor $Color
        } else {
            Write-Host $Message
        }
    }
}

<#
.SYNOPSIS
    Display usage information.
#>
function Show-Help {
    Write-Host @"
Usage: $scriptName <service|all|list|rotate> <command>

Services:
  nginx, gitea, sftpgo, ...   (from services/*.json)
  all                          All configured services
  list                         List available services
  rotate                       Rotate all control logs

Commands:
  start     Start the service
  stop      Stop the service
  restart   Restart the service
  status    Check if service is running
  enable     Enable auto-start at user logon
  disable    Disable auto-start
  is-enabled Show auto-start status
  help      Show this help

Service-specific commands:
  nginx     reload, test
  gitea     doctor
  sftpgo    ping

Options:
  -Quiet, -q     Suppress output (for scripting)
  -Json          Output in JSON format (for automation)
  -Version, -v   Show version information

Examples:
  .\$scriptName nginx start
  .\$scriptName all status
  .\$scriptName nginx reload
  .\$scriptName nginx enable
  .\$scriptName list
  .\$scriptName rotate
  .\$scriptName -q all status
"@
}

<#
.SYNOPSIS
    Display list of all configured services with their status.
#>
function Show-ServiceList {
    if ($Json) {
        $services = @()
        Get-AllServiceConfigs | ForEach-Object {
            $proc = Get-ServiceProcess -Name $_.name
            $services += @{
                name = $_.name
                running = [bool](Test-ServiceRunning -Name $_.name)
                autoStart = [bool](Get-ServiceAutoStartStatus -Name $_.name)
                pid = if ($proc) { $proc.Id } else { $null }
                home = $_.home
            }
        }
        $output = @{
            version = $script:SvcMgrVersion
            timestamp = (Get-Date -Format "o")
            command = "list"
            services = $services
        }
        Write-Output ($output | ConvertTo-Json -Depth 4)
    } else {
        Write-Output-Conditional "Available services:"
        Write-Output-Conditional ""
        Get-AllServiceConfigs | ForEach-Object {
            $running = Test-ServiceRunning -Name $_.name
            $enabled = Get-ServiceAutoStartStatus -Name $_.name
            $status = if ($running) { "[running]" } else { "[stopped]" }
            $auto = if ($enabled) { "[enabled]" } else { "" }
            Write-Output-Conditional ("  {0,-12} {1,-10} {2}" -f $_.name, $status, $auto)
        }
    }
}

<#
.SYNOPSIS
    Get service status data for JSON output.
#>
function Get-ServiceStatusData {
    param([string]$ServiceName)

    $config = Get-ServiceConfig -Name $ServiceName
    $proc = Get-ServiceProcess -Name $ServiceName
    $running = $null -ne $proc
    $autoStart = Get-ServiceAutoStartStatus -Name $ServiceName

    return @{
        name = $ServiceName
        running = $running
        pid = if ($proc) { $proc.Id } else { $null }
        autoStart = $autoStart
        home = $config.home
        exe = $config.exe
    }
}

#endregion

#region Command Dispatch

<#
.SYNOPSIS
    Internal command dispatcher for service operations.
.DESCRIPTION
    Routes commands to the appropriate module function or plugin command.
    Sets $script:ExitCode based on operation success/failure.
#>
function Invoke-ServiceCommand-Internal {
    param(
        [string]$ServiceName,
        [string]$Cmd
    )

    if (-not $Cmd) { $Cmd = "help" }

    # Suppress output in JSON mode
    $effectiveQuiet = $Quiet -or $Json

    # Dispatch built-in commands or fall through to plugin lookup
    switch ($Cmd.ToLower()) {
        "start" {
            $result = Start-ServiceProcess -Name $ServiceName -Quiet:$effectiveQuiet
            if (-not $result) { $script:ExitCode = 1 }
            if ($Json) {
                $script:JsonResults += @{
                    service = $ServiceName
                    command = "start"
                    success = [bool]$result
                    status = Get-ServiceStatusData -ServiceName $ServiceName
                }
            }
        }
        "stop" {
            $result = Stop-ServiceProcess -Name $ServiceName -Quiet:$effectiveQuiet
            if (-not $result) { $script:ExitCode = 1 }
            if ($Json) {
                $script:JsonResults += @{
                    service = $ServiceName
                    command = "stop"
                    success = [bool]$result
                    status = Get-ServiceStatusData -ServiceName $ServiceName
                }
            }
        }
        "restart" {
            $result = Restart-ServiceProcess -Name $ServiceName -Quiet:$effectiveQuiet
            if (-not $result) { $script:ExitCode = 1 }
            if ($Json) {
                $script:JsonResults += @{
                    service = $ServiceName
                    command = "restart"
                    success = [bool]$result
                    status = Get-ServiceStatusData -ServiceName $ServiceName
                }
            }
        }
        "status" {
            if ($Json) {
                $statusData = Get-ServiceStatusData -ServiceName $ServiceName
                $script:JsonResults += @{
                    service = $ServiceName
                    command = "status"
                    success = $statusData.running
                    status = $statusData
                }
                if (-not $statusData.running) { $script:ExitCode = 1 }
            } else {
                $result = Get-ServiceStatus -Name $ServiceName -Quiet:$Quiet
                if (-not $result) { $script:ExitCode = 1 }
            }
        }
        "enable" {
            $result = Enable-ServiceAutoStart -Name $ServiceName -Quiet:$effectiveQuiet
            if (-not $result) { $script:ExitCode = 1 }
            if ($Json) {
                $script:JsonResults += @{
                    service = $ServiceName
                    command = "enable"
                    success = [bool]$result
                    autoStart = [bool](Get-ServiceAutoStartStatus -Name $ServiceName)
                }
            }
        }
        "disable" {
            $result = Disable-ServiceAutoStart -Name $ServiceName -Quiet:$effectiveQuiet
            if (-not $result) { $script:ExitCode = 1 }
            if ($Json) {
                $script:JsonResults += @{
                    service = $ServiceName
                    command = "disable"
                    success = [bool]$result
                    autoStart = [bool](Get-ServiceAutoStartStatus -Name $ServiceName)
                }
            }
        }
        "is-enabled" {
            $result = Get-ServiceAutoStartInfo -Name $ServiceName -Quiet:$effectiveQuiet
            if (-not $result) { $script:ExitCode = 1 }
            if ($Json) {
                $script:JsonResults += @{
                    service = $ServiceName
                    command = "is-enabled"
                    autoStart = [bool](Get-ServiceAutoStartStatus -Name $ServiceName)
                }
            }
        }
        "help" { Show-Help }
        default {
            # Try plugin command (convert to TitleCase for plugin lookup)
            $pluginCmd = (Get-Culture).TextInfo.ToTitleCase($Cmd)
            try {
                $result = Invoke-ServiceCommand -Name $ServiceName -Command $pluginCmd
                if ($result -eq $false) { $script:ExitCode = 1 }
                if ($Json) {
                    $script:JsonResults += @{
                        service = $ServiceName
                        command = $Cmd
                        success = ($result -ne $false)
                    }
                }
            } catch {
                # Check if it's a "command not available" error from the module
                if ($_.Exception.Message -match "not available for") {
                    Write-Output-Conditional "Unknown command: $Cmd" -Color Red
                    Write-Output-Conditional "Use '$scriptName help' for usage"
                    exit 1
                }
                # Other errors - show the actual error
                Write-Output-Conditional "ERROR: $_" -Color Red
                $script:ExitCode = 1
            }
        }
    }
}

#endregion

#region Main Entry Point

# Handle -Version flag first
if ($Version) {
    Write-Host "svcmgr version $script:SvcMgrVersion"
    exit 0
}

# Handle special service names: list, rotate, version, help
if ($Service -eq "list") {
    Show-ServiceList
    exit 0
}

if ($Service -eq "rotate") {
    try {
        $result = Invoke-LogRotation -Quiet:$Quiet
        exit 0
    } catch {
        Write-Output-Conditional "ERROR: Log rotation failed - $_" -Color Red
        exit 1
    }
}

if ($Service -eq "version" -or $Command -eq "version") {
    Write-Host "svcmgr version $script:SvcMgrVersion"
    exit 0
}

if (-not $Service -or $Service -eq "help" -or $Command -eq "help") {
    Show-Help
    exit 0
}

# Handle 'all' - apply command to every configured service
if ($Service -eq "all") {
    $services = Get-AllServiceConfigs
    foreach ($svc in $services) {
        if (-not $Json) {
            Write-Output-Conditional "=== $($svc.name) ===" -Color Cyan
        }
        Invoke-ServiceCommand-Internal -ServiceName $svc.name -Cmd $Command
        if (-not $Json) {
            Write-Output-Conditional ""
        }
    }
    if ($Json) {
        $output = @{
            version = $script:SvcMgrVersion
            timestamp = (Get-Date -Format "o")
            command = $Command
            exitCode = $script:ExitCode
            results = $script:JsonResults
        }
        Write-Output ($output | ConvertTo-Json -Depth 5)
    }
    exit $script:ExitCode
}

# Single service operation
try {
    Invoke-ServiceCommand-Internal -ServiceName $Service -Cmd $Command
    if ($Json) {
        $output = @{
            version = $script:SvcMgrVersion
            timestamp = (Get-Date -Format "o")
            command = $Command
            exitCode = $script:ExitCode
            results = $script:JsonResults
        }
        Write-Output ($output | ConvertTo-Json -Depth 5)
    }
    exit $script:ExitCode
} catch {
    Write-Output-Conditional "ERROR: $_" -Color Red
    exit 1
}

#endregion
