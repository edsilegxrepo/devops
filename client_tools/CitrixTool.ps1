<#
.SYNOPSIS
    Citrix Workspace Backup & Restore CLI Utility
.DESCRIPTION
    A production-ready utility to backup and restore Citrix Workspace configuration.
    It captures:
    - Registry settings (HKCU\Software\Citrix\Receiver)
    - AuthManager tokens and identity cache (%AppData%\Citrix\AuthManager)

    The tool ensures Citrix processes are terminated before restoration to prevent file locks.
.PARAMETER Backup
    Switch to initiate the backup process. Must be used with -Path or defaults to Desktop.
.PARAMETER Restore
    Switch to initiate the restore process. Requires -Path to a valid backup ZIP.
.PARAMETER Path
    The filesystem path used for backup destination or restore source.
.EXAMPLE
    .\CitrixTool.ps1 -Backup
    Backs up Citrix settings to a ZIP file on the current user's Desktop.
.EXAMPLE
    .\CitrixTool.ps1 -Restore -Path "C:\Backups\MYPC_citrixbackup_20260114-104000.zip"
    Restores Citrix settings from the specified ZIP file.
.NOTES
    Version: v1.0.1xg
    Author: XdG / MIS Center
    Release Date: 2026/01/14
#>

[CmdletBinding(DefaultParameterSetName = "Help")]
param (
    [Parameter(ParameterSetName = "Backup", Mandatory = $true)]
    [Alias("b")]
    [switch]$Backup,

    [Parameter(ParameterSetName = "Restore", Mandatory = $true)]
    [Alias("r")]
    [switch]$Restore,

    [Parameter(ParameterSetName = "Backup", Mandatory = $false)]
    [Parameter(ParameterSetName = "Restore", Mandatory = $false)]
    [string]$Path
)

# --- Initialize Environment & Global Variables ---
# Purpose: Set up paths and metadata used throughout the script.
$Computer = $env:COMPUTERNAME
$DateStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupFileName = "${Computer}_citrixbackup_${DateStamp}.zip"
$AppDataCitrix = Join-Path $env:AppData "Citrix"
$AuthPath = Join-Path $AppDataCitrix "AuthManager"
$RegPath = "HKCU\Software\Citrix\Receiver"

# --- Privilege Check ---
# Objective: Verify if the script has sufficient permissions to stop services and write to system-protected areas.
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warning "Running without Administrator privileges. Citrix process termination might fail."
}

# --- Internal Helper: Cleanup ---
# Objective: Ensure temporary staging areas are removed regardless of success or failure.
function Remove-StagingDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Dir)
    if ($null -ne $Dir -and (Test-Path $Dir)) {
        if ($PSCmdlet.ShouldProcess($Dir, "Remove")) {
            Write-Verbose "Cleaning up staging directory: $Dir"
            Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Core Action: Backup ---
if ($Backup) {
    Write-Output "[*] Action: Starting Backup..."
    $TempStage = $null
    try {
        # Determine Destination
        $DestDir = if ([string]::IsNullOrWhiteSpace($Path)) { Join-Path $HOME "Desktop" } else { $Path }
        if (-not (Test-Path $DestDir)) {
            Write-Verbose "Creating destination directory: $DestDir"
            New-Item -ItemType Directory -Path $DestDir -Force -ErrorAction Stop | Out-Null
        }
        $FinalZipPath = Join-Path $DestDir $BackupFileName

        # Prepare Staging Area
        $TempStage = Join-Path $env:TEMP "Citrix_Stage_$DateStamp"
        New-Item -ItemType Directory -Path $TempStage -Force -ErrorAction Stop | Out-Null

        # 1. Export Registry Settings
        Write-Verbose "Exporting Registry from $RegPath"
        reg export "$RegPath" "$TempStage\CitrixSettings.reg" /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Registry export failed with exit code $LASTEXITCODE."
        }
        Write-Output " [+] Exported Registry Settings."

        # 2. Capture AuthManager Cache
        if (Test-Path $AuthPath) {
            Write-Verbose "Copying AuthManager from $AuthPath"
            $DestAuth = New-Item -ItemType Directory -Path (Join-Path $TempStage "AuthManager") -ErrorAction Stop
            Copy-Item -Path (Join-Path $AuthPath "*") -Destination $DestAuth -Recurse -Force -ErrorAction Stop
            Write-Output " [+] Copied AuthManager Cache."
        } else {
            Write-Warning "AuthManager cache not found at $AuthPath. Skipping."
        }

        # 3. Create Compressed Archive
        Write-Output " [+] Compressing backup..."
        Compress-Archive -Path (Join-Path $TempStage "*") -DestinationPath $FinalZipPath -Force -ErrorAction Stop

        Write-Output "[OK] Backup saved to: $FinalZipPath"
    }
    catch {
        Write-Error "Backup failed: $($_.Exception.Message)"
        exit 1
    }
    finally {
        Remove-StagingDirectory -Dir $TempStage
    }
}

# --- Core Action: Restore ---
elseif ($Restore) {
    Write-Output "[*] Action: Starting Restore from $Path"
    $TempRestore = $null
    try {
        # Input Validation
        if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path $Path -PathType Leaf)) {
            throw "A valid path to a backup .zip file is required."
        }

        # 1. Terminate Citrix Processes
        # This is critical to release file locks on the AuthManager database.
        Write-Output " [+] Terminating Citrix processes..."
        $CitrixProcs = @("Receiver", "SelfService", "AuthManager", "Citrix*")
        $RunningProcs = Get-Process -Name $CitrixProcs -ErrorAction SilentlyContinue
        if ($RunningProcs) {
            Write-Verbose "Stopping processes: $($RunningProcs.Name -join ', ')"
            $RunningProcs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        # 2. Extract Archive to Temp
        $TempRestore = Join-Path $env:TEMP "Citrix_Restore_$DateStamp"
        Write-Verbose "Extracting $Path to $TempRestore"
        Expand-Archive -Path $Path -DestinationPath $TempRestore -ErrorAction Stop

        # 3. Import Registry
        $RegFile = Join-Path $TempRestore "CitrixSettings.reg"
        if (Test-Path $RegFile) {
            Write-Verbose "Importing Registry from $RegFile"
            reg import "$RegFile" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Registry import failed with exit code $LASTEXITCODE."
            } else {
                Write-Output " [+] Registry settings imported."
            }
        }

        # 4. Restore AuthManager Cache
        $SourceAuth = Join-Path $TempRestore "AuthManager"
        if (Test-Path $SourceAuth) {
            Write-Verbose "Restoring AuthManager to $AppDataCitrix"
            if (Test-Path $AuthPath) {
                Remove-Item $AuthPath -Recurse -Force -ErrorAction Stop
            }
            if (-not (Test-Path $AppDataCitrix)) {
                New-Item -ItemType Directory -Path $AppDataCitrix -Force -ErrorAction Stop | Out-Null
            }
            Copy-Item -Path $SourceAuth -Destination $AppDataCitrix -Recurse -Force -ErrorAction Stop
            Write-Output " [+] AuthManager cache restored."
        }

        # 5. Relaunch Citrix Workspace
        $CitrixExe = "C:\Program Files (x86)\Citrix\ICA Client\SelfServicePlugin\SelfService.exe"
        if (Test-Path $CitrixExe) {
            Start-Process $CitrixExe
            Write-Output " [+] Relaunching Citrix Workspace..."
        } else {
            Write-Warning "Citrix executable not found at $CitrixExe. Manual launch required."
        }

        Write-Output "[OK] Restore Complete."
    }
    catch {
        Write-Error "Restore failed: $($_.Exception.Message)"
        exit 1
    }
    finally {
        Remove-StagingDirectory -Dir $TempRestore
    }
}

# --- Action: Help / Usage ---
else {
    Get-Help $PSCommandPath
}
