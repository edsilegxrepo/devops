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
    1. Parameters -> Resolve $LogPath and $BackupPath under $env:TEMP\disable_ntlmv1\.
    2. HKLM Registry -> Read prior LmCompatibilityLevel & AuditReceiptEvents -> Save to JSON Backup.
    3. HKLM Registry & Windows Event Log -> Apply AuditReceiptEvents = 2 & enable NTLM Operational log channel.
    4. HKLM Registry -> Set LmCompatibilityLevel = 5 (unless -EnableAuditOnly).
    5. HKLM Registry -> Re-read post-execution state -> Verify values -> Emit PSCustomObject to pipeline.

.NOTES
    File Name : disable_ntlmv1.ps1
    Version   : 2.0.0
    Date      : 2026-07-23
    Requires  : PowerShell 5.1 or higher (Run as Administrator)
#>

# Enforce elevated administrative execution privileges
#requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    # Switch parameter to run in audit-only mode without modifying LmCompatibilityLevel
    [Parameter(Mandatory = $false)]
    [switch]$EnableAuditOnly,

    # File path for script execution logs; defaults to %TEMP%\disable_ntlmv1\NTLM_Hardening.log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "$env:TEMP\disable_ntlmv1\NTLM_Hardening.log",

    # File path for pre-execution registry state backup; defaults to %TEMP%\disable_ntlmv1\NTLM_Registry_Backup.json
    [Parameter(Mandatory = $false)]
    [string]$BackupPath = "$env:TEMP\disable_ntlmv1\NTLM_Registry_Backup.json"
)

# Region: Helper & Logging Setup
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
    Description: Writes timestamped log messages to stdout with level-based color highlighting
                 and appends formatted log records to the designated log file.
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

    # Write colorized output to console host based on log severity level
    switch ($Level) {
        "INFO" { Write-Host $FormattedMessage -ForegroundColor Cyan }
        "WARN" { Write-Host $FormattedMessage -ForegroundColor Yellow }
        "ERROR" { Write-Host $FormattedMessage -ForegroundColor Red }
        "SUCCESS" { Write-Host $FormattedMessage -ForegroundColor Green }
    }

    # Append formatted message entry to target log file
    try {
        Add-Content -Path $script:LogPath -Value $FormattedMessage -ErrorAction Stop
    } catch {
        Write-Warning "[$TimeStamp] [$ComputerName] Failed to write to log file: $_"
    }
}
# EndRegion

# Region: Main Script Execution
Write-Log "Initializing NTLM Hardening Script (disable_ntlmv1.ps1)..." "INFO"

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

    # Step 2: Ensure registry target paths exist
    # Verify MSV1_0 subkey exists under Lsa; create if missing
    if (-not (Test-Path -Path $MsvPath)) {
        if ($PSCmdlet.ShouldProcess($MsvPath, "Create Registry Key")) {
            New-Item -Path $MsvPath -Force | Out-Null
            Write-Log "Created registry key: $MsvPath" "INFO"
        }
    }

    # Step 3: Enable NTLM Operational Event Log Channel
    # Verify and enable the Microsoft-Windows-NTLM/Operational event log channel for NTLM audit logging
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

    # Step 4: Audit mode check / NTLM Auditing Activation
    # Set AuditReceiptEvents = 2 (Audit all incoming NTLM traffic)
    Write-Log "Enabling NTLM incoming authentication auditing (AuditReceiptEvents = 2)..." "INFO"
    if ($PSCmdlet.ShouldProcess($MsvPath, "Set AuditReceiptEvents = 2")) {
        Set-ItemProperty -Path $MsvPath -Name "AuditReceiptEvents" -Value 2 -Type DWord -Force -ErrorAction Stop
        Write-Log "NTLM Auditing (AuditReceiptEvents) enabled successfully." "SUCCESS"
    }

    # Exit early if -EnableAuditOnly flag is set, returning audit status object
    if ($EnableAuditOnly) {
        Write-Log "-EnableAuditOnly flag specified. Skipping LmCompatibilityLevel registry modification." "WARN"

        if (-not $WhatIfPreference) {
            $VerifiedAuditReceipt = (Get-ItemProperty -Path $MsvPath -Name "AuditReceiptEvents" -ErrorAction Stop).AuditReceiptEvents
            Write-Log "POST INSPECTION -> AuditReceiptEvents verified as: $VerifiedAuditReceipt" "SUCCESS"

            # Emit structured result object for audit-only execution
            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                PriorLmLevel = $PriorLmStr
                AppliedLmLevel = "Skipped (-EnableAuditOnly)"
                PriorAuditEvents = $PriorAuditStr
                AppliedAuditEvents = $VerifiedAuditReceipt
                Status = "AUDIT_ONLY"
                Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                OutputDir = $LogDir
                LogPath = $LogPath
                BackupPath = $BackupPath
            }
        }
        return
    }

    # Step 5: Apply Hardening Policy (LmCompatibilityLevel = 5)
    # Set LmCompatibilityLevel = 5 (Send NTLMv2 response only. Refuse LM & NTLMv1)
    Write-Log "Applying LmCompatibilityLevel = 5 (Send NTLMv2 response only. Refuse LM & NTLMv1)..." "INFO"
    if ($PSCmdlet.ShouldProcess($LsaPath, "Set LmCompatibilityLevel = 5")) {
        Set-ItemProperty -Path $LsaPath -Name "LmCompatibilityLevel" -Value 5 -Type DWord -Force -ErrorAction Stop
    }

    # Step 6: Post-Execution Inspection & Compliance Verification
    # Re-inspect registry values to confirm target settings were successfully applied
    if (-not $WhatIfPreference) {
        $VerifiedLmLevel = (Get-ItemProperty -Path $LsaPath -Name "LmCompatibilityLevel" -ErrorAction Stop).LmCompatibilityLevel
        $VerifiedAuditReceipt = (Get-ItemProperty -Path $MsvPath -Name "AuditReceiptEvents" -ErrorAction Stop).AuditReceiptEvents

        Write-Log "POST INSPECTION -> LmCompatibilityLevel: $VerifiedLmLevel | AuditReceiptEvents: $VerifiedAuditReceipt" "INFO"

        # Verify compliance criteria: LmCompatibilityLevel must equal 5 and AuditReceiptEvents must equal 2
        if ($VerifiedLmLevel -eq 5 -and $VerifiedAuditReceipt -eq 2) {
            Write-Log "COMPLIANCE VERIFIED: LmCompatibilityLevel=5 and AuditReceiptEvents=2." "SUCCESS"

            # Emit structured compliance object to pipeline
            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                PriorLmLevel = $PriorLmStr
                AppliedLmLevel = $VerifiedLmLevel
                PriorAuditEvents = $PriorAuditStr
                AppliedAuditEvents = $VerifiedAuditReceipt
                Status = "COMPLIANT"
                Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                OutputDir = $LogDir
                LogPath = $LogPath
                BackupPath = $BackupPath
            }
        } else {
            Write-Log "VERIFICATION FAILED: LmCompatibilityLevel=$VerifiedLmLevel, AuditReceiptEvents=$VerifiedAuditReceipt." "ERROR"
            throw "Verification failed: Target states were not applied properly."
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
