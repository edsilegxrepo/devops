<#
.SYNOPSIS
    IISDelegationSet.ps1 - Configures full IIS management delegation for a non-administrative group.

.DESCRIPTION
    This script implements "Least Privilege" delegation by injecting OS-level security permissions.
    It performs the following primary objectives:
    1. Configuration Backup: Creates a recursive, timestamped backup of IIS config files.
    2. NTFS Permissions: Grants 'Modify' access to inetsrv\config and appPools temp directories.
    3. Registry Permissions: Grants 'FullControl' to the IIS installation registry key.
    4. Service Security: Injects the group SID into W3SVC and WAS service security descriptors (SDDL).
    5. Configuration Unlocking: Unlocks 17 critical IIS configuration sections in applicationHost.config.

.PARAMETER GroupName
    The Active Directory group name (e.g., "DOMAIN\Group") to delegate permissions to. Mandatory.

.PARAMETER BackupLocation
    The directory path where IIS configuration backups will be stored.
    Defaults to %TEMP%\IISDelegation\backup.

.EXAMPLE
    .\IISDelegationSet.ps1 -GroupName "CORP\IIS_Managers"
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$GroupName, # Example: "DOMAIN\GROUPNAME"

    [Parameter(Mandatory = $false)]
    [string]$BackupLocation = "$env:TEMP\IISDelegation\backup"
)

$ErrorActionPreference = "Stop"

# --- CORE COMPONENT: Privilege Check ---
# This script modifies system-level ACLs and SDDLs, requiring full Administrator privileges.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script MUST be executed as an Administrator."
    exit 1
}

Import-Module WebAdministration

Write-Output "--- Starting Full IIS Delegation for $GroupName ---"

# --- FUNCTIONALITY: Backup Sequence ---
# Data Flow: Source (%windir%\system32\inetsrv\config) -> Destination ($TimestampedBackup)
$TimestampedBackup = Join-Path $BackupLocation "IIS_Config_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
if (!(Test-Path $TimestampedBackup)) {
    New-Item -ItemType Directory -Path $TimestampedBackup -Force | Out-Null
}
Copy-Item "C:\Windows\System32\inetsrv\config\*" $TimestampedBackup -Recurse -Force
Write-Output "[SUCCESS] Backups created at: $TimestampedBackup"

# --- FUNCTIONALITY: NTFS Permissions ---
# Grants 'Modify' rights to allow non-admins to write to the global configuration and initialize worker processes.
$Paths = @("C:\Windows\System32\inetsrv\config", "C:\inetpub\temp\appPools")
foreach ($Path in $Paths) {
    if (Test-Path $Path) {
        Write-Output "Granting Modify access to: $Path"
        $Acl = Get-Acl $Path
        $Ar = New-Object System.Security.AccessControl.FileSystemAccessRule($GroupName, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
        $Acl.SetAccessRule($Ar)
        Set-Acl $Path $Acl
        Write-Output "[SUCCESS] NTFS ACL applied to $Path"
    } else {
        Write-Warning "Path not found: $Path"
    }
}

# --- FUNCTIONALITY: Registry Permissions ---
# Unlocks the IIS installation key required by the WebAdministration module and IIS management APIs.
$RegPath = "HKLM:\SOFTWARE\Microsoft\InetStp"
if (Test-Path $RegPath) {
    Write-Output "Granting Full Control to Registry: $RegPath"
    $RegAcl = Get-Acl $RegPath
    $RegRule = New-Object System.Security.AccessControl.RegistryAccessRule($GroupName, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $RegAcl.SetAccessRule($RegRule)
    Set-Acl $RegPath $RegAcl
    Write-Output "[SUCCESS] Registry ACL applied to $RegPath"
}

# --- FUNCTIONALITY: Service Security (SDDL) ---
# Injects an Access Control Entry (ACE) into the Service Security Descriptor.
# (A;;RPWPCR;;;SID) translates to: Allow; ; ReadProperty, WriteProperty, CreateChild ; ; ; SID
# This allows the group to Start, Stop, and Query the service status.
$GroupSID = (New-Object System.Security.Principal.NTAccount($GroupName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
foreach ($Service in @("W3SVC", "WAS")) {
    $CurrentSDDL = (sc.exe sdshow $Service)[0]
    if ($CurrentSDDL -notlike "*$GroupSID*") {
        $NewSDDL = $CurrentSDDL + "(A;;RPWPCR;;;$GroupSID)"
        sc.exe sdset $Service $NewSDDL | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "[SUCCESS] Service $Service permissions updated for SID $GroupSID"
        } else {
            Write-Error "Failed to update service permissions for $Service"
        }
    } else {
        Write-Output "Service $Service already has permissions for $GroupName"
    }
}

# --- FUNCTIONALITY: Configuration Unlocking ---
# Changes 'overrideModeDefault' from 'Deny' to 'Allow' for 17 core sections.
# This permits non-admins to define and modify these settings in the global applicationHost.config.
$Sections = @(
    "system.applicationHost/applicationPools",
    "system.applicationHost/sites",
    "system.applicationHost/log",
    "system.applicationHost/configHistory",
    "system.webServer/defaultDocument",
    "system.webServer/modules",
    "system.webServer/handlers",
    "system.webServer/security/authentication/anonymousAuthentication",
    "system.webServer/security/authentication/windowsAuthentication",
    "system.webServer/security/authentication/basicAuthentication",
    "system.webServer/security/access",
    "system.webServer/security/ipSecurity",
    "system.webServer/httpCompression",
    "system.webServer/staticContent",
    "system.webServer/directoryBrowse",
    "system.webServer/httpErrors",
    "system.webServer/tracing/traceFailedRequests"
)

foreach ($Section in $Sections) {
    Write-Output "Unlocking section: $Section"
    Remove-WebConfigurationLock -Filter $Section -ErrorAction SilentlyContinue

    # Logic for constructing the XML filter for nested section groups.
    $pathParts = $Section -split '/'
    if ($pathParts.Count -eq 2) {
        $sectionGroup = $pathParts[0]
        $sectionName = $pathParts[1]
        $Filter = "/configSections/sectionGroup[@name='$sectionGroup']/section[@name='$sectionName']"
    } elseif ($pathParts.Count -eq 3) {
        $group1 = $pathParts[0]
        $group2 = $pathParts[1]
        $sectionName = $pathParts[2]
        $Filter = "/configSections/sectionGroup[@name='$group1']/sectionGroup[@name='$group2']/section[@name='$sectionName']"
    } elseif ($pathParts.Count -eq 4) {
        $group1 = $pathParts[0]
        $group2 = $pathParts[1]
        $group3 = $pathParts[2]
        $sectionName = $pathParts[3]
        $Filter = "/configSections/sectionGroup[@name='$group1']/sectionGroup[@name='$group2']/sectionGroup[@name='$group3']/section[@name='$sectionName']"
    }

    Set-WebConfigurationProperty -Filter $Filter -Name "overrideModeDefault" -Value "Allow" -ErrorAction SilentlyContinue
    Write-Output "[SUCCESS] Unlocked and allowed override for $Section"
}

Write-Output "--- Delegation Complete ---"

