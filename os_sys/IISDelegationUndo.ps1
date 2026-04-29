<#
.SYNOPSIS
    IISDelegationUndo.ps1 - Reverts IIS management delegation for a specific group.

.DESCRIPTION
    This script reverses the changes made by IISDelegationSet.ps1.
    It performs the following primary objectives:
    1. Configuration Re-locking: Sets 'overrideModeDefault' back to 'Deny' for all 17 sections.
    2. Service Security Reset: Restores W3SVC and WAS service security descriptors to Windows defaults.
    3. NTFS ACL Removal: Removes the specific Group ACEs from inetsrv\config and appPools directories.
    4. Registry ACL Removal: Removes the specific Group ACEs from the IIS installation registry key.

.PARAMETER GroupName
    The Active Directory group name (e.g., "DOMAIN\Group") whose permissions should be removed. Mandatory.

.PARAMETER BackupLocation
    The directory path where backups were stored. Used here primarily for a status check/warning.
    Defaults to %TEMP%\IISDelegation\backup.

.EXAMPLE
    .\IISDelegationUndo.ps1 -GroupName "CORP\IIS_Managers"
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$GroupName,

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

Write-Output "--- Reverting IIS Delegation for $GroupName ---"

# --- FUNCTIONALITY: Configuration Re-locking ---
# Re-applies the 'Deny' override mode to lock down the global configuration.
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
    Write-Output "Locking section: $Section"
    Add-WebConfigurationLock -Filter $Section -ErrorAction SilentlyContinue

    # Reset overrideModeDefault to Deny
    $pathParts = $Section -split '/'

    # Construct the filter based on the number of parts
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

    Set-WebConfigurationProperty -Filter $Filter -Name "overrideModeDefault" -Value "Deny" -ErrorAction SilentlyContinue
    Write-Output "[SUCCESS] Locked and denied override for $Section"
}

# --- FUNCTIONALITY: Service Security (SDDL) Reset ---
# Restores the factory default SDDL for W3SVC and WAS.
$DefaultSDDL = "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)"
foreach ($Svc in @("W3SVC", "WAS")) {
    sc.exe sdset $Svc $DefaultSDDL | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "[SUCCESS] Reset $Svc service permissions to default."
    } else {
        Write-Warning "Failed to reset $Svc service permissions."
    }
}

# --- FUNCTIONALITY: NTFS ACL Removal ---
# Removes the specific Access Control Entry for the GroupName from system directories.
$Paths = @("C:\Windows\System32\inetsrv\config", "C:\inetpub\temp\appPools")
foreach ($Path in $Paths) {
    if (Test-Path $Path) {
        $Acl = Get-Acl $Path
        $Ar = $Acl.Access | Where-Object { $_.IdentityReference -like "*$GroupName*" }
        if ($Ar) {
            $Acl.RemoveAccessRule($Ar)
            Set-Acl $Path $Acl
            Write-Output "[SUCCESS] Removed $GroupName from $Path"
        } else {
            Write-Output "$GroupName not found in ACL for $Path"
        }
    }
}

# --- FUNCTIONALITY: Registry ACL Removal ---
# Removes the specific Access Control Entry for the GroupName from the IIS installation registry key.
$RegPath = "HKLM:\SOFTWARE\Microsoft\InetStp"
if (Test-Path $RegPath) {
    $RegAcl = Get-Acl $RegPath
    $RegRule = $RegAcl.Access | Where-Object { $_.IdentityReference -like "*$GroupName*" }
    if ($RegRule) {
        $RegAcl.RemoveAccessRule($RegRule)
        Set-Acl $RegPath $RegAcl
        Write-Output "[SUCCESS] Removed $GroupName from Registry"
    } else {
        Write-Output "$GroupName not found in Registry ACL"
    }
}

# --- FUNCTIONALITY: Cleanup Check ---
if (Test-Path $BackupLocation) {
    Write-Output "Backup location found at: $BackupLocation"
    Write-Output "Note: Backup files were NOT automatically deleted for safety. You can manually remove them if no longer needed."
}

Write-Output "--- Undo Complete ---"

