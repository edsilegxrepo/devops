#Requires -Version 5.1
<#
.SYNOPSIS
    Process Control Module - Framework for managing user-space services on Windows
.DESCRIPTION
    This module provides functions for starting, stopping, and monitoring user-space
    services without requiring administrator privileges. It uses Task Scheduler for
    auto-start at logon and PID files for process tracking.

    Suppressed warnings:
    - PSAvoidUsingWriteHost: CLI tools require colored console output for user feedback
    - PSUseShouldProcessForStateChangingFunctions: Low-level service functions are called
      by higher-level wrappers that handle confirmation; adding -WhatIf here would break
      the control flow and provide no user benefit
.VERSION
    1.1.0
#>

# Module-level suppressions for intentional design decisions
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "Get-AllServiceConfigs",
    Justification = "Returns multiple configs; plural noun is semantically correct")]
param()

$script:ModuleRoot = $PSScriptRoot
$script:ScriptRoot = Split-Path $ModuleRoot -Parent
$script:ServicesPath = Join-Path $script:ScriptRoot "services"
$script:PluginsPath = Join-Path $script:ScriptRoot "plugins"

#region Configuration

function Get-ServiceConfig {
    <#
    .SYNOPSIS
        Load service configuration from JSON file.
    .DESCRIPTION
        Parses the service JSON configuration, validates required fields,
        expands placeholders ({home}, {data}, {name}), and adds computed properties.
    .PARAMETER Name
        Service name (matches services/<name>.json filename).
    .OUTPUTS
        PSCustomObject with service configuration including computed ExePath.
    .EXAMPLE
        $config = Get-ServiceConfig -Name "nginx"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $configFile = Join-Path $script:ServicesPath "$Name.json"
    if (-not (Test-Path $configFile)) {
        throw "Service config not found: $configFile"
    }

    try {
        $config = Get-Content $configFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Failed to parse config file $configFile`: $_"
    }

    # Validate required fields
    $requiredFields = @('name', 'exe', 'home')
    foreach ($field in $requiredFields) {
        if (-not $config.$field) {
            throw "Missing required field '$field' in $configFile"
        }
    }

    # Expand placeholders like {data}, {home}
    $config = Expand-ConfigPlaceholder $config

    # Add computed properties
    $config | Add-Member -NotePropertyName 'ExePath' -NotePropertyValue (Join-Path $config.home $config.exe) -Force
    $config | Add-Member -NotePropertyName 'ConfigFile' -NotePropertyValue $configFile -Force

    return $config
}

function Expand-ConfigPlaceholder {
    <#
    .SYNOPSIS
        Replace {placeholder} tokens in config values (recursive)
    #>
    param($Config)

    $placeholders = @{
        '{home}' = $Config.home
        '{data}' = $Config.data
        '{name}' = $Config.name
    }

    foreach ($prop in $Config.PSObject.Properties) {
        if ($prop.Value -is [string]) {
            foreach ($key in $placeholders.Keys) {
                if ($placeholders[$key]) {
                    # Use string Replace to avoid regex interpretation of $ and \
                    $prop.Value = $prop.Value.Replace($key, $placeholders[$key])
                }
            }
        } elseif ($prop.Value -is [PSCustomObject]) {
            # Recurse into nested objects
            $prop.Value = Expand-ConfigPlaceholder $prop.Value
        }
    }

    return $Config
}

function Get-AllServiceConfigs {
    <#
    .SYNOPSIS
        Load all service configurations
    #>
    [CmdletBinding()]
    param()

    $configs = [System.Collections.ArrayList]::new()
    Get-ChildItem $script:ServicesPath -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.BaseName
        try {
            [void]$configs.Add((Get-ServiceConfig -Name $name))
        } catch {
            Write-Warning "Failed to load config for $name`: $_"
        }
    }
    return $configs.ToArray()
}

#endregion

#region Process Management

function Get-ServiceProcess {
    <#
    .SYNOPSIS
        Get running process for a service
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $config = Get-ServiceConfig -Name $Name

    # Try PID file first
    if ($config.pidFile -and (Test-Path $config.pidFile)) {
        $pidContent = Get-Content $config.pidFile -Raw -ErrorAction SilentlyContinue
        if ($pidContent -and $pidContent.Trim() -match '^\d+$') {
            $servicePid = [int]$pidContent.Trim()
            $proc = Get-Process -Id $servicePid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq [System.IO.Path]::GetFileNameWithoutExtension($config.exe)) {
                return $proc
            }
        }
    }

    # Fallback: find by executable name
    $exeName = [System.IO.Path]::GetFileNameWithoutExtension($config.exe)
    return Get-Process -Name $exeName -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Test-ServiceRunning {
    <#
    .SYNOPSIS
        Check if service is running.
    .PARAMETER Name
        Service name.
    .OUTPUTS
        Boolean - $true if running, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $proc = Get-ServiceProcess -Name $Name
    return $null -ne $proc
}

function Start-ServiceProcess {
    <#
    .SYNOPSIS
        Start a service.
    .DESCRIPTION
        Starts the service process using the configured executable and arguments.
        Creates log/PID directories if needed. Uses plugin Start method if available.
    .PARAMETER Name
        Service name.
    .PARAMETER TimeoutSeconds
        Seconds to wait for startup confirmation. Default: 10.
    .PARAMETER Quiet
        Suppress console output.
    .OUTPUTS
        Boolean - $true if started successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [int]$TimeoutSeconds = 10,

        [switch]$Quiet
    )

    $config = Get-ServiceConfig -Name $Name

    if (Test-ServiceRunning -Name $Name) {
        $proc = Get-ServiceProcess -Name $Name
        if (-not $Quiet) { Write-Host "$($config.name) is already running [PID: $($proc.Id)]" }
        return $true
    }

    # Validate executable
    if (-not (Test-Path $config.ExePath)) {
        throw "Executable not found: $($config.ExePath)"
    }

    # Ensure log directory exists
    if ($config.logFile) {
        $logDir = Split-Path $config.logFile -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
    }

    # Ensure PID directory exists
    if ($config.pidFile) {
        $pidDir = Split-Path $config.pidFile -Parent
        if ($pidDir -and -not (Test-Path $pidDir)) {
            New-Item -ItemType Directory -Path $pidDir -Force | Out-Null
        }
    }

    if (-not $Quiet) { Write-Host "Starting $($config.name)" }
    Write-Log -Config $config -Message "Starting $($config.name)"

    # Load plugin if exists
    $plugin = Get-ServicePlugin -Config $config

    # Start process
    if ($plugin -and $plugin.Start) {
        & $plugin.Start $config
    } else {
        Start-ServiceProcessDefault -Config $config
    }

    # Wait for startup
    $started = Wait-ServiceStart -Name $Name -TimeoutSeconds $TimeoutSeconds

    if ($started) {
        $proc = Get-ServiceProcess -Name $Name
        if (-not $Quiet) { Write-Host "$($config.name) started [PID: $($proc.Id)]" }
        return $true
    } else {
        if (-not $Quiet) { Write-Host "ERROR: $($config.name) failed to start" -ForegroundColor Red }
        Write-Log -Config $config -Message "ERROR: $($config.name) failed to start"
        return $false
    }
}

function Start-ServiceProcessDefault {
    param($Config)

    $startArgs = @{
        FilePath = $Config.ExePath
        WorkingDirectory = $Config.home
        WindowStyle = 'Minimized'
    }

    # Pass args as a single string to preserve quoting
    if ($Config.args) {
        $startArgs.ArgumentList = $Config.args
    }

    # Set environment variables if defined
    if ($Config.env) {
        foreach ($key in $Config.env.PSObject.Properties.Name) {
            [Environment]::SetEnvironmentVariable($key, $Config.env.$key, 'Process')
        }
    }

    $proc = Start-Process @startArgs -PassThru -ErrorAction Stop
    if (-not $proc) {
        throw "Failed to start process"
    }
}

function Stop-ServiceProcess {
    <#
    .SYNOPSIS
        Stop a service using three-stage shutdown.
    .DESCRIPTION
        Implements progressive shutdown:
        1. Graceful stop (plugin, signal, or CloseMainWindow)
        2. Force kill specific PID
        3. Kill all remaining processes by executable name
    .PARAMETER Name
        Service name.
    .PARAMETER GracefulWaitSeconds
        Seconds to wait after graceful stop attempt. Default: 3.
    .PARAMETER ForceWaitSeconds
        Seconds to wait after force kill. Default: 2.
    .PARAMETER Quiet
        Suppress console output.
    .OUTPUTS
        Boolean - $true if stopped successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [int]$GracefulWaitSeconds = 3,
        [int]$ForceWaitSeconds = 2,

        [switch]$Quiet
    )

    $config = Get-ServiceConfig -Name $Name

    if (-not (Test-ServiceRunning -Name $Name)) {
        if (-not $Quiet) { Write-Host "$($config.name) is not running" }
        return $true
    }

    if (-not $Quiet) { Write-Host "Stopping $($config.name)" }
    Write-Log -Config $config -Message "Stopping $($config.name)"

    $proc = Get-ServiceProcess -Name $Name
    $plugin = Get-ServicePlugin -Config $config

    # Stage 1: Graceful stop
    if ($plugin -and $plugin.Stop) {
        Write-Log -Config $config -Message "Requesting graceful stop via plugin"
        & $plugin.Stop $config
    } elseif ($config.stopMethod -eq 'signal' -and $config.stopSignal) {
        Write-Log -Config $config -Message "Requesting graceful stop via signal"
        Start-Process -FilePath $config.ExePath -ArgumentList $config.stopSignal -WorkingDirectory $config.home -NoNewWindow -Wait -ErrorAction SilentlyContinue
    } else {
        Write-Log -Config $config -Message "Requesting graceful stop for PID $($proc.Id)"
        # CloseMainWindow works for GUI apps; console apps will proceed to force kill
        $proc.CloseMainWindow() | Out-Null
    }

    # Wait for graceful stop
    $stopped = Wait-ServiceStop -Name $Name -TimeoutSeconds $GracefulWaitSeconds
    if ($stopped) {
        Remove-PidFile -Config $config
        if (-not $Quiet) { Write-Host "$($config.name) stopped" }
        return $true
    }

    # Stage 2: Force kill
    $proc = Get-ServiceProcess -Name $Name
    if ($proc) {
        Write-Log -Config $config -Message "Forcing stop for PID $($proc.Id)"
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds $ForceWaitSeconds
    }

    # Stage 3: Kill all remaining
    if (Test-ServiceRunning -Name $Name) {
        $exeName = [System.IO.Path]::GetFileNameWithoutExtension($config.exe)
        Write-Log -Config $config -Message "Forcing stop for remaining $exeName processes"
        Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Remove-PidFile -Config $config

    if (Test-ServiceRunning -Name $Name) {
        if (-not $Quiet) { Write-Host "ERROR: $($config.name) failed to stop" -ForegroundColor Red }
        Write-Log -Config $config -Message "ERROR: $($config.name) failed to stop"
        return $false
    }

    if (-not $Quiet) { Write-Host "$($config.name) stopped" }
    return $true
}

function Restart-ServiceProcess {
    <#
    .SYNOPSIS
        Restart a service (stop then start).
    .PARAMETER Name
        Service name.
    .PARAMETER Quiet
        Suppress console output.
    .OUTPUTS
        Boolean - $true if restarted successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$Quiet
    )

    $config = Get-ServiceConfig -Name $Name

    if (-not $Quiet) { Write-Host "Restarting $($config.name)" }
    Write-Log -Config $config -Message "Restarting $($config.name)"

    $stopped = Stop-ServiceProcess -Name $Name -Quiet:$Quiet
    if (-not $stopped) {
        if (-not $Quiet) { Write-Host "ERROR: $($config.name) restart aborted because stop failed" -ForegroundColor Red }
        return $false
    }

    Start-Sleep -Seconds 2
    return Start-ServiceProcess -Name $Name -Quiet:$Quiet
}

function Get-ServiceStatus {
    <#
    .SYNOPSIS
        Display and return service running status.
    .PARAMETER Name
        Service name.
    .PARAMETER Quiet
        Suppress console output.
    .OUTPUTS
        Boolean - $true if running, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$Quiet
    )

    $config = Get-ServiceConfig -Name $Name
    $proc = Get-ServiceProcess -Name $Name

    if ($proc) {
        if (-not $Quiet) { Write-Host "$($config.name) is running [PID: $($proc.Id)]" }
        return $true
    } else {
        if (-not $Quiet) { Write-Host "$($config.name) is not running" }
        return $false
    }
}

#endregion

#region Helpers

function Wait-ServiceStart {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 10
    )

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if (Test-ServiceRunning -Name $Name) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Wait-ServiceStop {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 3
    )

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if (-not (Test-ServiceRunning -Name $Name)) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Remove-PidFile {
    param($Config)

    if ($Config.pidFile -and (Test-Path $Config.pidFile)) {
        Remove-Item $Config.pidFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-Log {
    param(
        $Config,
        [string]$Message
    )

    if (-not $Config.ctlLogFile) { return }

    try {
        $logDir = Split-Path $Config.ctlLogFile -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] $Message" | Add-Content -Path $Config.ctlLogFile -ErrorAction SilentlyContinue
    } catch {
        # Logging failures are non-fatal - write to stderr for debugging but don't crash
        Write-Verbose "Failed to write to log file: $($_.Exception.Message)"
    }
}

#endregion

#region Plugins

function Get-ServicePlugin {
    param(
        [string]$Name,
        $Config
    )

    # Use provided config or load it
    if (-not $Config) {
        $Config = Get-ServiceConfig -Name $Name
    }

    if (-not $Config.plugin) { return $null }

    $pluginFile = Join-Path $script:PluginsPath "$($Config.plugin).plugin.ps1"
    if (-not (Test-Path $pluginFile)) { return $null }

    # Source plugin in current scope and capture PluginCommands
    # Clear any previous plugin commands first
    $script:PluginCommands = $null
    . $pluginFile

    # Return the commands hashtable
    return $script:PluginCommands
}

function Invoke-ServiceCommand {
    <#
    .SYNOPSIS
        Invoke a custom plugin command (reload, test, ping, doctor, etc.).
    .PARAMETER Name
        Service name.
    .PARAMETER Command
        Plugin command name (TitleCase, e.g., "Reload", "Test").
    .OUTPUTS
        Return value from the plugin command (typically Boolean).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Command
    )

    $config = Get-ServiceConfig -Name $Name
    $plugin = Get-ServicePlugin -Config $config

    if (-not $plugin -or -not $plugin.$Command) {
        throw "Command '$Command' not available for $Name"
    }

    & $plugin.$Command $config
}

#endregion

#region Log Rotation

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Rotate control logs for all services.
    .DESCRIPTION
        Rotates *_ctl.log files when they exceed MaxSizeKB.
        Keeps KeepCount historical versions (.1, .2, .3, etc.).
    .PARAMETER Quiet
        Suppress console output.
    .PARAMETER MaxSizeKB
        Rotate logs larger than this size. Default: 1024 KB.
    .PARAMETER KeepCount
        Number of rotated logs to keep. Default: 3.
    .OUTPUTS
        Int - Number of logs rotated.
    #>
    [CmdletBinding()]
    param(
        [switch]$Quiet,
        [int]$MaxSizeKB = 1024,
        [int]$KeepCount = 3
    )

    $rotated = 0
    $configs = Get-AllServiceConfigs

    foreach ($config in $configs) {
        if (-not $config.ctlLogFile) { continue }
        if (-not (Test-Path $config.ctlLogFile)) { continue }

        $file = Get-Item $config.ctlLogFile
        $sizeKB = [math]::Round($file.Length / 1KB, 2)

        # Skip rotation if file is smaller than MaxSizeKB
        if ($sizeKB -lt $MaxSizeKB) {
            if (-not $Quiet) { Write-Host "Skipping $($config.name) log ($sizeKB KB < $MaxSizeKB KB threshold)" }
            continue
        }

        # Rotate: delete oldest, shift others, rename current
        if (-not $Quiet) { Write-Host "Rotating $($config.name) log ($sizeKB KB)" }

        for ($i = $KeepCount; $i -ge 1; $i--) {
            $old = "$($config.ctlLogFile).$i"
            $new = "$($config.ctlLogFile).$($i + 1)"
            if ($i -eq $KeepCount -and (Test-Path $old)) {
                Remove-Item $old -Force -ErrorAction SilentlyContinue
            } elseif (Test-Path $old) {
                Move-Item $old $new -Force -ErrorAction SilentlyContinue
            }
        }

        Move-Item $config.ctlLogFile "$($config.ctlLogFile).1" -Force -ErrorAction SilentlyContinue
        $rotated++
    }

    if (-not $Quiet) { Write-Host "Rotated $rotated log(s)" }
    return $rotated
}

#endregion

#region Task Scheduler (Enable/Disable)

function Enable-ServiceAutoStart {
    <#
    .SYNOPSIS
        Create scheduled task to start service at user logon.
    .DESCRIPTION
        Creates a Windows Task Scheduler task that runs svcmgr.ps1 <service> start
        at user logon. Does not require administrator privileges.
    .PARAMETER Name
        Service name.
    .PARAMETER Quiet
        Suppress console output.
    .OUTPUTS
        Boolean - $true if enabled successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$Quiet
    )

    $config = Get-ServiceConfig -Name $Name
    $taskName = "SvcMgr-$($config.name)"

    # Check if already enabled
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not $Quiet) { Write-Host "$($config.name) is already enabled" }
        return $true
    }

    # Build the action - use script root stored at module load time
    $scriptPath = Join-Path $script:ScriptRoot "svcmgr.ps1"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Quiet $($config.name) start"

    # Trigger at user logon (no admin required)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Settings
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    # Register task for current user
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Auto-start $($config.name) via SvcMgr at logon" -ErrorAction Stop | Out-Null
        if (-not $Quiet) { Write-Host "$($config.name) enabled (starts at logon)" }
        Write-Log -Config $config -Message "Enabled auto-start at logon"
        return $true
    } catch {
        if (-not $Quiet) { Write-Host "ERROR: Failed to enable $($config.name): $_" -ForegroundColor Red }
        return $false
    }
}

function Disable-ServiceAutoStart {
    <#
    .SYNOPSIS
        Remove scheduled task for service auto-start.
    .PARAMETER Name
        Service name.
    .PARAMETER Quiet
        Suppress console output.
    .OUTPUTS
        Boolean - $true if disabled successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$Quiet
    )

    $config = Get-ServiceConfig -Name $Name
    $taskName = "SvcMgr-$($config.name)"

    # Check if exists
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        if (-not $Quiet) { Write-Host "$($config.name) is not enabled" }
        return $true
    }

    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        if (-not $Quiet) { Write-Host "$($config.name) disabled" }
        Write-Log -Config $config -Message "Disabled auto-start"
        return $true
    } catch {
        if (-not $Quiet) { Write-Host "ERROR: Failed to disable $($config.name): $_" -ForegroundColor Red }
        return $false
    }
}

function Get-ServiceAutoStartStatus {
    <#
    .SYNOPSIS
        Check if service has auto-start enabled.
    .PARAMETER Name
        Service name.
    .OUTPUTS
        Boolean - $true if auto-start enabled, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $config = Get-ServiceConfig -Name $Name
    $taskName = "SvcMgr-$($config.name)"

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    return $null -ne $existing
}

function Get-ServiceAutoStartInfo {
    <#
    .SYNOPSIS
        Display auto-start task details.
    .PARAMETER Name
        Service name.
    .PARAMETER Quiet
        Suppress console output.
    .OUTPUTS
        Boolean - $true if auto-start enabled, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$Quiet
    )

    $config = Get-ServiceConfig -Name $Name
    $taskName = "SvcMgr-$($config.name)"

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if (-not $task) {
        if (-not $Quiet) { Write-Host "$($config.name) auto-start: disabled" }
        return $false
    }

    if (-not $Quiet) {
        Write-Host "$($config.name) auto-start: enabled"
        Write-Host "  Task:    $taskName"
        Write-Host "  Trigger: At logon"
        Write-Host "  State:   $($task.State)"
    }
    return $true
}

#endregion

#region Exports

Export-ModuleMember -Function @(
    'Get-ServiceConfig'
    'Get-AllServiceConfigs'
    'Get-ServiceProcess'
    'Test-ServiceRunning'
    'Start-ServiceProcess'
    'Stop-ServiceProcess'
    'Restart-ServiceProcess'
    'Get-ServiceStatus'
    'Invoke-ServiceCommand'
    'Invoke-LogRotation'
    'Enable-ServiceAutoStart'
    'Disable-ServiceAutoStart'
    'Get-ServiceAutoStartStatus'
    'Get-ServiceAutoStartInfo'
)

#endregion
