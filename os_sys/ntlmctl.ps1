<#
.SYNOPSIS
    Disables NTLMv1 and enforces NTLMv2 and Kerberos authentication across Windows systems.

.DESCRIPTION
    OBJECTIVES:
    1. Hardens LSA authentication by setting LmCompatibilityLevel to 5 under HKLM:\SYSTEM\CurrentControlSet\Control\Lsa.
    2. Enables incoming NTLM authentication auditing by setting AuditReceiptEvents to 2 under HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0.
    3. Enables the Windows NTLM Operational event log channel (Microsoft-Windows-NTLM/Operational).
    4. Performs non-destructive pre-execution inspection and exports prior state to a JSON backup artifact.
    5. Executes post-execution compliance verification and emits a structured PSCustomObject to the pipeline.

    CORE COMPONENTS:
    - Privilege Enforcement: Requires elevated administrative context (#requires -RunAsAdministrator).
    - Logging Subsystem: Write-Log helper providing formatted, color-coded console output and file logging with ISO timestamps.
    - Backup Engine: Captures pre-modification registry settings to JSON for rollback readiness.
    - Registry Mutator: Applies target security configurations guarded by WhatIf/Confirm ($PSCmdlet.ShouldProcess).
    - Compliance Verifier: Re-reads registry state post-mutation and validates target compliance.

    DATA FLOWS:
    1. Parameters -> Resolve $LogPath and $BackupPath under $env:TEMP\ntlmctl\.
    2. HKLM Registry -> Read prior LmCompatibilityLevel & AuditReceiptEvents -> Save to JSON Backup.
    3. HKLM Registry & Windows Event Log -> Apply AuditReceiptEvents = 2 & enable NTLM Operational log channel (or AuditReceiptEvents = 0 & disable channel).
    4. HKLM Registry -> Set LmCompatibilityLevel = 5 (when -DisableV1 specified).
    5. HKLM Registry -> Re-read post-execution state -> Verify values -> Emit PSCustomObject to pipeline.

.NOTES
    File Name : ntlmctl.ps1
    Version   : 2.1.0
    Date      : 2026-07-23
    Requires  : PowerShell 5.1 or higher (Run as Administrator)
#>

# Enforce elevated administrative execution privileges
#requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    # Switch parameter to display usage and help documentation
    [Parameter(Mandatory = $false)]
    [Alias('h', '?')]
    [switch]$Help,

    # Switch parameter to run in non-interactive batch mode without confirmation prompts
    [Parameter(Mandatory = $false)]
    [Alias('b')]
    [switch]$Batch,

    # Switch parameter to inspect current system compliance state without applying changes
    [Parameter(Mandatory = $false)]
    [Alias('d')]
    [switch]$Detect,

    # Switch parameter to disable NTLMv1 and enforce NTLMv2 (sets LmCompatibilityLevel = 5)
    [Parameter(Mandatory = $false)]
    [Alias('dv1')]
    [switch]$DisableV1,

    # Switch parameter to enable incoming NTLM auditing without modifying LmCompatibilityLevel
    [Parameter(Mandatory = $false)]
    [Alias('a')]
    [switch]$EnableAudit,

    # Switch parameter to disable incoming NTLM auditing (sets AuditReceiptEvents = 0)
    [Parameter(Mandatory = $false)]
    [Alias('da')]
    [switch]$DisableAudit,

    # File path for script execution logs; defaults to %TEMP%\ntlmctl\NTLM_Hardening.log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "$env:TEMP\ntlmctl\NTLM_Hardening.log",

    # File path for pre-execution registry state backup; defaults to %TEMP%\ntlmctl\NTLM_Registry_Backup.json
    [Parameter(Mandatory = $false)]
    [string]$BackupPath = "$env:TEMP\ntlmctl\NTLM_Registry_Backup.json"
)

# Region: Helper & Logging Setup
<#
    Function: Show-Help
    Description: Displays command-line usage and detailed parameter description for ntlmctl.ps1.
#>
function Show-Help {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
    param()

    Write-Host "NTLM Protocol & Audit Manager (ntlmctl.ps1)"
    Write-Host ""
    Write-Host "USAGE:"
    Write-Host "    .\ntlmctl.ps1 -DisableV1 [-Batch] [-LogPath <String>] [-BackupPath <String>] [-WhatIf]"
    Write-Host "    .\ntlmctl.ps1 -EnableAudit [-Batch] [-LogPath <String>] [-BackupPath <String>] [-WhatIf]"
    Write-Host "    .\ntlmctl.ps1 -DisableAudit [-Batch] [-LogPath <String>] [-BackupPath <String>] [-WhatIf]"
    Write-Host "    .\ntlmctl.ps1 -Detect"
    Write-Host "    .\ntlmctl.ps1 -Help"
    Write-Host ""
    Write-Host "DESCRIPTION:"
    Write-Host "    Disables NTLMv1 and enforces NTLMv2 and Kerberos authentication across Windows host systems."
    Write-Host "    Hardens LSA authentication by setting LmCompatibilityLevel = 5 (-DisableV1), or manages incoming NTLM"
    Write-Host "    audit logging (-EnableAudit to set AuditReceiptEvents = 2, -DisableAudit to set AuditReceiptEvents = 0),"
    Write-Host "    and generates pre-execution JSON registry backups."
    Write-Host "    (Interactive confirmation prompts are active by default; use -Batch for non-interactive execution.)"
    Write-Host ""
    Write-Host "PARAMETERS / FLAGS:"
    Write-Host "    -Help, -h, -?        Display this usage and help information."
    Write-Host "    -DisableV1, -dv1     Disables NTLMv1 and enforces NTLMv2 (sets LmCompatibilityLevel = 5)."
    Write-Host "    -EnableAudit, -a     Enables incoming NTLM auditing (AuditReceiptEvents = 2) without modifying LmCompatibilityLevel."
    Write-Host "    -DisableAudit, -da   Disables incoming NTLM auditing (AuditReceiptEvents = 0) without modifying LmCompatibilityLevel."
    Write-Host "    -Batch, -b           Executes in non-interactive mode without confirmation prompts."
    Write-Host "    -Detect, -d          Inspects and displays current NTLM security state without modifying settings."
    Write-Host "    -LogPath <Path>      Target path for script execution log file."
    Write-Host "                         Default: %TEMP%\ntlmctl\NTLM_Hardening.log"
    Write-Host "    -BackupPath <Path>   Target path for saving pre-execution registry JSON backup."
    Write-Host "                         Default: %TEMP%\ntlmctl\NTLM_Registry_Backup.json"
    Write-Host "    -WhatIf              Previews changes without performing registry or file modifications."
    Write-Host ""
    Write-Host "EXAMPLES:"
    Write-Host "    .\ntlmctl.ps1"
    Write-Host "    .\ntlmctl.ps1 -DisableV1 -Batch"
    Write-Host "    .\ntlmctl.ps1 -EnableAudit -Batch"
    Write-Host "    .\ntlmctl.ps1 -DisableAudit -Batch"
    Write-Host "    .\ntlmctl.ps1 -Detect"
    Write-Host "    .\ntlmctl.ps1 -WhatIf"
    Write-Host ""
}

# Validate parameter compatibility constraints
if ($Help) {
    if ($DisableV1 -or $EnableAudit -or $DisableAudit -or $Detect -or $Batch) {
        throw "Invalid parameter combination: -Help (-h) is an exclusive switch and cannot be combined with other parameters."
    }
    Show-Help
    return
}

if ($Detect) {
    if ($DisableV1 -or $EnableAudit -or $DisableAudit -or $Batch) {
        throw "Invalid parameter combination: -Detect (-d) is an exclusive read-only switch and cannot be combined with other parameters."
    }
}

if ($EnableAudit -and $DisableAudit) {
    throw "Invalid parameter combination: -EnableAudit (-a) and -DisableAudit (-da) are mutually exclusive."
}

$HasMutatingAction = $DisableV1 -or $EnableAudit -or $DisableAudit

if ($Batch -and -not $HasMutatingAction) {
    throw "Invalid parameter combination: -Batch (-b) cannot be specified by itself; it must be combined with a modifying switch (-DisableV1, -EnableAudit, or -DisableAudit)."
}

# If no action parameter is specified (e.g. .\ntlmctl.ps1 alone), display usage and exit cleanly
if (-not $HasMutatingAction) {
    Show-Help
    return
}

# In non-interactive batch mode, bypass confirmation prompts by suppressing ConfirmPreference
if ($Batch) {
    $ConfirmPreference = 'None'
}

# Ensure parent log directory exists on local disk
$LogDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Ensure parent backup directory exists on local disk
$BackupDir = Split-Path -Path $BackupPath -Parent
if (-not (Test-Path -Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

<#
    Function: Write-Log
    Description: Writes timestamped log messages to stdout and appends formatted log records to the designated log file.
#>
function Write-Log {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    # Generate unified ISO-8601 formatted timestamp string and hostname
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $ComputerName = $env:COMPUTERNAME
    $FormattedMessage = "[$TimeStamp] [$ComputerName] [$Level] $Message"

    # Write plain uncolored output to console host
    Write-Host $FormattedMessage

    # Append formatted message entry to target log file
    try {
        Add-Content -Path $script:LogPath -Value $FormattedMessage -ErrorAction Stop
    } catch {
        Write-Warning "[$TimeStamp] [$ComputerName] Failed to write to log file: $_"
    }
}
# EndRegion

# Region: Main Script Execution
Write-Log "Initializing NTLM Protocol & Audit Manager (ntlmctl.ps1)..." "INFO"

# Define LSA security authority registry paths
$LsaPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
$MsvPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"

try {
    # Step 1: Pre-Execution Backup & Inspection (Captured BEFORE any modifications occur)
    Write-Log "Inspecting prior registry state..." "INFO"

    # Retrieve current LmCompatibilityLevel setting prior to modification
    $PriorLmLevel = (Get-ItemProperty -Path $LsaPath -Name "LmCompatibilityLevel" -ErrorAction SilentlyContinue).LmCompatibilityLevel

    # Retrieve current AuditReceiptEvents setting if MSV1_0 key exists
    $PriorAuditReceipt = if (Test-Path -Path $MsvPath) {
        (Get-ItemProperty -Path $MsvPath -Name "AuditReceiptEvents" -ErrorAction SilentlyContinue).AuditReceiptEvents
    } else {
        $null
    }

    # Format initial state strings for readable log output
    $PriorLmStr = if ($null -ne $PriorLmLevel) { $PriorLmLevel } else { "Not Set (Legacy System Default)" }
    $PriorAuditStr = if ($null -ne $PriorAuditReceipt) { $PriorAuditReceipt } else { "Not Set" }
    Write-Log "PRIOR STATE -> LmCompatibilityLevel: $PriorLmStr | AuditReceiptEvents: $PriorAuditStr" "INFO"

    # Handle -Detect mode execution (inspect state without making modifications)
    if ($Detect) {
        # Retrieve Microsoft-Windows-NTLM/Operational event log channel status
        $EventLogChannel = try {
            Get-WinEvent -ListLog "Microsoft-Windows-NTLM/Operational" -ErrorAction SilentlyContinue
        } catch {
            $null
        }
        $EventLogEnabled = if ($null -ne $EventLogChannel) { $EventLogChannel.IsEnabled } else { $false }

        Write-Log "-Detect flag specified. State inspection completed; no modifications applied." "WARN"
        $DetectStatus = if ($PriorLmLevel -eq 5) {
            "COMPLIANT"
        } elseif ($PriorAuditReceipt -eq 2) {
            "AUDIT_ONLY"
        } else {
            "NON_COMPLIANT"
        }

        # Emit structured compliance object for detection mode to pipeline
        [PSCustomObject]@{
            ComputerName         = $env:COMPUTERNAME
            PriorLmLevel         = $PriorLmStr
            AppliedLmLevel       = "Skipped (-Detect)"
            PriorAuditEvents     = $PriorAuditStr
            AppliedAuditEvents   = "Skipped (-Detect)"
            EventLogEnabled      = $EventLogEnabled
            Status               = $DetectStatus
            Timestamp            = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            OutputDir            = $LogDir
            LogPath              = $LogPath
            BackupPath           = $BackupPath
        }
        return
    }

    # Construct backup state dictionary for rollback reference
    $BackupState = @{
        ComputerName = $env:COMPUTERNAME
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        LmCompatibilityLevel = $PriorLmLevel
        AuditReceiptEvents = $PriorAuditReceipt
    }

    # Export pre-execution registry state to JSON backup file
    if ($PSCmdlet.ShouldProcess($BackupPath, "Save Pre-execution Registry State")) {
        $BackupState | ConvertTo-Json | Set-Content -Path $BackupPath -Force
        Write-Log "Saved pre-execution registry state backup to: $BackupPath" "INFO"
    }

    # Step 2: Handle Audit Mode Configuration (-EnableAudit / -DisableAudit)
    if ($EnableAudit) {
        Write-Log "-EnableAudit flag specified. Enabling incoming NTLM auditing..." "INFO"

        # Verify MSV1_0 subkey exists under Lsa; create if missing
        if (-not (Test-Path -Path $MsvPath)) {
            if ($PSCmdlet.ShouldProcess($MsvPath, "Create Registry Key")) {
                New-Item -Path $MsvPath -Force | Out-Null
                Write-Log "Created registry key: $MsvPath" "INFO"
            }
        }

        # Verify and enable the Microsoft-Windows-NTLM/Operational event log channel
        Write-Log "Verifying NTLM Operational Event Log channel status..." "INFO"
        if ($PSCmdlet.ShouldProcess("Microsoft-Windows-NTLM/Operational", "Enable Event Log Channel")) {
            try {
                $logChannel = Get-WinEvent -ListLog "Microsoft-Windows-NTLM/Operational" -ErrorAction SilentlyContinue
                if ($logChannel -and -not $logChannel.IsEnabled) {
                    Write-Log "Enabling Microsoft-Windows-NTLM/Operational event log channel..." "INFO"
                    & wevtutil.exe sl "Microsoft-Windows-NTLM/Operational" /e:true
                    Write-Log "Microsoft-Windows-NTLM/Operational event log channel enabled." "SUCCESS"
                }
            } catch {
                Write-Log "Warning: Unable to query or enable Microsoft-Windows-NTLM/Operational event log channel: $_" "WARN"
            }
        }

        # Set AuditReceiptEvents = 2 (Audit all incoming NTLM traffic)
        Write-Log "Enabling NTLM incoming authentication auditing (AuditReceiptEvents = 2)..." "INFO"
        if ($PSCmdlet.ShouldProcess($MsvPath, "Set AuditReceiptEvents = 2")) {
            Set-ItemProperty -Path $MsvPath -Name "AuditReceiptEvents" -Value 2 -Type DWord -Force -ErrorAction Stop
            Write-Log "NTLM Auditing (AuditReceiptEvents) enabled successfully." "SUCCESS"
        }
    } elseif ($DisableAudit) {
        Write-Log "-DisableAudit flag specified. Disabling incoming NTLM auditing..." "INFO"

        # Verify and disable the Microsoft-Windows-NTLM/Operational event log channel
        Write-Log "Verifying NTLM Operational Event Log channel status..." "INFO"
        if ($PSCmdlet.ShouldProcess("Microsoft-Windows-NTLM/Operational", "Disable Event Log Channel")) {
            try {
                $logChannel = Get-WinEvent -ListLog "Microsoft-Windows-NTLM/Operational" -ErrorAction SilentlyContinue
                if ($logChannel -and $logChannel.IsEnabled) {
                    Write-Log "Disabling Microsoft-Windows-NTLM/Operational event log channel..." "INFO"
                    & wevtutil.exe sl "Microsoft-Windows-NTLM/Operational" /e:false
                    Write-Log "Microsoft-Windows-NTLM/Operational event log channel disabled." "SUCCESS"
                }
            } catch {
                Write-Log "Warning: Unable to query or disable Microsoft-Windows-NTLM/Operational event log channel: $_" "WARN"
            }
        }

        # Set AuditReceiptEvents = 0 (Disable incoming NTLM auditing)
        if (Test-Path -Path $MsvPath) {
            if ($PSCmdlet.ShouldProcess($MsvPath, "Set AuditReceiptEvents = 0")) {
                Set-ItemProperty -Path $MsvPath -Name "AuditReceiptEvents" -Value 0 -Type DWord -Force -ErrorAction Stop
                Write-Log "NTLM Auditing (AuditReceiptEvents) disabled successfully (set to 0)." "SUCCESS"
            }
        }
    }

    # Step 3: Handle Protocol Hardening (-DisableV1)
    if ($DisableV1) {
        Write-Log "-DisableV1 flag specified. Applying LmCompatibilityLevel = 5 (Send NTLMv2 response only. Refuse LM & NTLMv1)..." "INFO"
        if ($PSCmdlet.ShouldProcess($LsaPath, "Set LmCompatibilityLevel = 5")) {
            Set-ItemProperty -Path $LsaPath -Name "LmCompatibilityLevel" -Value 5 -Type DWord -Force -ErrorAction Stop
        }
    }

    # Step 4: Post-Execution Inspection & Compliance Verification
    if (-not $WhatIfPreference) {
        $VerifiedLmLevel = (Get-ItemProperty -Path $LsaPath -Name "LmCompatibilityLevel" -ErrorAction Stop).LmCompatibilityLevel
        $VerifiedAuditReceipt = if (Test-Path -Path $MsvPath) {
            (Get-ItemProperty -Path $MsvPath -Name "AuditReceiptEvents" -ErrorAction SilentlyContinue).AuditReceiptEvents
        } else {
            "Not Set"
        }

        $AppliedLmStr = if ($DisableV1) { $VerifiedLmLevel } else { "Skipped (Not Specified)" }
        $AppliedAuditStr = if ($EnableAudit -or $DisableAudit) { $VerifiedAuditReceipt } else { "Skipped (Not Specified)" }

        # Determine execution status: System is COMPLIANT if LmCompatibilityLevel = 5
        $ExecutionStatus = if ($VerifiedLmLevel -eq 5) {
            if ($EnableAudit) { "COMPLIANT_AUDIT_ENABLED" }
            elseif ($DisableAudit) { "COMPLIANT_AUDIT_DISABLED" }
            else { "COMPLIANT" }
        } elseif ($EnableAudit) {
            "AUDIT_ENABLED"
        } elseif ($DisableAudit) {
            "AUDIT_DISABLED"
        } else {
            "NON_COMPLIANT"
        }

        Write-Log "POST INSPECTION -> LmCompatibilityLevel: $VerifiedLmLevel | AuditReceiptEvents: $VerifiedAuditReceipt" "INFO"

        if ($DisableV1 -and $VerifiedLmLevel -ne 5) {
            Write-Log "VERIFICATION FAILED: LmCompatibilityLevel=$VerifiedLmLevel." "ERROR"
            throw "Verification failed: Target LmCompatibilityLevel was not applied properly."
        }

        # Emit structured compliance object to pipeline
        [PSCustomObject]@{
            ComputerName       = $env:COMPUTERNAME
            PriorLmLevel       = $PriorLmStr
            AppliedLmLevel     = $AppliedLmStr
            PriorAuditEvents   = $PriorAuditStr
            AppliedAuditEvents = $AppliedAuditStr
            Status             = $ExecutionStatus
            Timestamp          = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            OutputDir          = $LogDir
            LogPath            = $LogPath
            BackupPath         = $BackupPath
        }
    }

} catch {
    # Log exception details and rethrow to caller
    Write-Log "An error occurred during execution: $_" "ERROR"
    throw $_
} finally {
    # Finalize execution and state log path locations
    Write-Log "Execution finished. All output artifacts stored in directory: $LogDir (Log: $LogPath, Backup: $BackupPath)" "INFO"
}
# EndRegion
