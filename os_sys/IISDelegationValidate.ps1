<#
.SYNOPSIS
    IISDelegationValidate.ps1 - Verifies the IIS management delegation for a specific group.

.DESCRIPTION
    This script performs a multi-point audit to ensure that the delegation set by IISDelegationSet.ps1
    is active and functional. It is intended to be run in the context of a delegated group member.
    The script performs:
    1. Privilege Audit: Warns if run as Administrator (standard user context is preferred for validation).
    2. Group Membership Check: Proactively verifies if the current user belongs to the delegated GroupName.
    3. Service Access Test: Checks visibility and control status of W3SVC and WAS.
    4. Registry ACL Check: Verifies the presence of FullControl/Modify ACEs on the IIS registry key.
    5. NTFS ACL Check: Verifies the presence of Modify ACEs on critical filesystem paths.
    6. Functional Commit Test: Attempts non-destructive configuration changes across App Pools, Sites, and nested security sections.

.PARAMETER GroupName
    The Active Directory group name (e.g., "DOMAIN\Group") to validate. Mandatory.

.EXAMPLE
    .\IISDelegationValidate.ps1 -GroupName "CORP\IIS_Managers"
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$GroupName
)

$ErrorActionPreference = "Continue"

# --- CORE COMPONENT: Context Check ---
# For true validation, this script should run in the context of the delegated user (non-Administrator).
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script should ideally be executed as a member of the delegated group (non-Administrator) to properly verify permissions."
}

# --- CORE COMPONENT: Membership Verification ---
# Data Flow: Current User Token -> NTAccount Resolution -> Group Match Check
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$groupFound = $false
foreach ($groupSid in $currentUser.Groups) {
    try {
        $groupNameResolved = $groupSid.Translate([Security.Principal.NTAccount]).Value
        if ($groupNameResolved -eq $GroupName -or $groupNameResolved -like "*\$GroupName") {
            $groupFound = $true
            break
        }
    } catch {
        # Some SIDs might not resolve, skip them
        continue
    }
}

if (-not $groupFound) {
    Write-Warning "Current user '$($currentUser.Name)' does not appear to be a member of group '$GroupName'. Verification results may fail."
}

Write-Output "--- Verifying IIS Permissions for $GroupName ---"
Import-Module WebAdministration
$Results = @()

# --- FUNCTIONALITY: Service Access Test ---
# Verifies that the user can query the service status and control the service (via sdshow proxy).
foreach ($Svc in @("W3SVC", "WAS")) {
    $canQuery = Get-Service $Svc -ErrorAction SilentlyContinue
    $status = "Fail"
    if ($canQuery) {
        try {
            # Try to query the security descriptor as a proxy for control access
            sc.exe sdshow $Svc | Out-Null
            if ($LASTEXITCODE -eq 0) { $status = "Pass" }
        } catch { $status = "Fail (No Control)" }
    }
    $Results += [PSCustomObject]@{ Test = "Service Access ($Svc)"; Status = $status }
}

# --- FUNCTIONALITY: Registry ACL Check ---
# Explicitly checks the Access Control List for the GroupName entry with appropriate rights.
$RegPath = "HKLM:\SOFTWARE\Microsoft\InetStp"
try {
    $Acl = Get-Acl $RegPath -ErrorAction Stop
    $hasAcl = $Acl.Access | Where-Object { $_.IdentityReference -like "*$GroupName*" -and $_.RegistryRights -match "FullControl|Modify" }
    $Results += [PSCustomObject]@{ Test = "Registry ACL Check"; Status = if ($hasAcl) { "Pass" } else { "Fail (ACL Missing)" } }
} catch {
    $Results += [PSCustomObject]@{ Test = "Registry Path Access"; Status = "Fail: $($_.Exception.Message)" }
}

# --- FUNCTIONALITY: NTFS ACL Check ---
# Explicitly checks the Access Control List for critical system paths.
$Paths = @("C:\Windows\System32\inetsrv\config", "C:\inetpub\temp\appPools")
foreach ($Path in $Paths) {
    if (Test-Path $Path) {
        $Acl = Get-Acl $Path
        $hasAcl = $Acl.Access | Where-Object { $_.IdentityReference -like "*$GroupName*" -and $_.FileSystemRights -match "Modify|FullControl" }
        $Results += [PSCustomObject]@{ Test = "NTFS ACL Check ($($Path.Split('\')[-1]))"; Status = if ($hasAcl) { "Pass" } else { "Fail (ACL Missing)" } }
    } else {
        $Results += [PSCustomObject]@{ Test = "Path Existence ($Path)"; Status = "Fail (Not Found)" }
    }
}

# --- FUNCTIONALITY: Functional Commit Test ---
# Attempts real-world configuration writes to various areas of applicationHost.config.
try {
    # 4.1. App Pool Test
    $pool = Get-Item "IIS:\AppPools\DefaultAppPool" -ErrorAction Stop
    $currentAutoStart = $pool.autoStart
    Set-WebConfigurationProperty -Filter "/system.applicationHost/applicationPools/add[@name='DefaultAppPool']" -Name "autoStart" -Value $currentAutoStart -ErrorAction Stop
    $Results += [PSCustomObject]@{ Test = "IIS Config Commit (AppPools)"; Status = "Pass" }

    # 4.2. Site Test (Default Web Site)
    $site = Get-Item "IIS:\Sites\Default Web Site" -ErrorAction Stop
    $currentLog = $site.logFile.directory
    Set-WebConfigurationProperty -Filter "/system.applicationHost/sites/site[@name='Default Web Site']/logFile" -Name "directory" -Value $currentLog -ErrorAction Stop
    $Results += [PSCustomObject]@{ Test = "IIS Config Commit (Sites)"; Status = "Pass" }

    # 4.3. Nested Section Test (Authentication)
    $currentAuth = (Get-WebConfigurationProperty -Filter "system.webServer/security/authentication/anonymousAuthentication" -Name "enabled").Value
    Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/anonymousAuthentication" -Name "enabled" -Value $currentAuth -ErrorAction Stop
    $Results += [PSCustomObject]@{ Test = "IIS Config Commit (Nested Sec)"; Status = "Pass" }
} catch {
    $Results += [PSCustomObject]@{ Test = "IIS Config Commit Test"; Status = "Fail: $($_.Exception.Message)" }
}

Write-Output "`nVerification Summary:"
$Results | Format-Table -AutoSize

$allPass = ($Results | Where-Object { $_.Status -ne "Pass" }).Count -eq 0
if ($allPass) {
    Write-Output "--- Verification SUCCESSFUL ---"
} else {
    Write-Output "--- Verification FAILED ---"
}
