<#
.SYNOPSIS
    DNS management utility for Windows.

.DESCRIPTION
    OBJECTIVE:
    To provide a reliable, automated interface for managing and inspecting DNS configurations
    on Windows systems. This utility simplifies common tasks such as listing active
    name servers, managing search suffixes, and performing multi-host resolutions.

    CORE COMPONENTS:
    1. Inspection Tier: Retrieves active DNS server addresses and global search suffixes.
    2. Management Tier: Configures DNS search suffixes with mandatory administrative enforcement.
    3. Resolution Engine: Performs synchronous resolution of hostnames with support for multiple record types.
    4. Argument Mapping: Hyphenated flag support for cross-environment compatibility.

    FUNCTIONALITY & DATA FLOW:
    - Input: CLI parameters or hyphenated flags (captured via ValueFromRemainingArguments).
    - Validation: Enforces administrative rights for system-level configuration changes.
    - Processing: Filters interfaces to show only relevant (non-empty) DNS configurations.
    - Output: Supports both human-readable console tables and machine-readable JSON payloads.

.PARAMETER List
    List active DNS name servers and the global search suffix list.

.PARAMETER Primary
    Restricts the -List output to only the primary network interface (the one with the default gateway).

.PARAMETER SetSuffix
    Sets the list of DNS search suffixes. Supports comma-separated strings or multiple arguments.
    Requires administrative privileges.

.PARAMETER Resolve
    Performs DNS resolution for a single host or a list of hosts.

.PARAMETER Json
    Enables machine-readable JSON output for all operations.

.PARAMETER Version
    Displays the current version of the script (1.0.0).

.EXAMPLE
    .\dnsmgr.ps1 -list -primary
    .\dnsmgr.ps1 -set-suffix "corp.local,dev.local" -json
    .\dnsmgr.ps1 -resolve "google.com,microsoft.com"
#>

[CmdletBinding(PositionalBinding = $false)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
param(
    [Parameter(Mandatory = $false)]
    [switch]$List,

    [Parameter(Mandatory = $false)]
    [string[]]$SetSuffix,

    [Parameter(Mandatory = $false)]
    [string[]]$Resolve,

    [Parameter(Mandatory = $false)]
    [switch]$Version,

    [Parameter(Mandatory = $false)]
    [switch]$Json,

    [Parameter(Mandatory = $false)]
    [switch]$Primary,

    # Capture any unbound arguments to support hyphenated flags (e.g., -set-suffix)
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

# Set strict mode to ensure absolute reliability in variable and property references.
Set-StrictMode -Version Latest

# --- OS VALIDATION ---

# Ensure the utility is executing on a Windows platform.
if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    $osError = "This utility is specific to Windows-based DNS management and is not supported on your current platform."
    if ($Json) {
        [PSCustomObject]@{ Status = "FAIL"; Message = $osError } | ConvertTo-Json
    } else {
        Write-Error $osError
    }
    exit 1
}

# --- UTILITY TIER ---

<#
.SYNOPSIS
    Checks if the current process is running with administrative privileges.
#>
function Test-IsAdministrator {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
.SYNOPSIS
    Displays the standardized help output for the utility.
#>
function Show-Help {
    Write-Host "DNS Manager Utility Help" -ForegroundColor Cyan
    Write-Host "Usage: .\dnsmgr.ps1 [flags]"
    Write-Host ""
    Write-Host "Flags:"
    Write-Host "ACTIONS"
    Write-Host "  -list                     List active DNS name servers and search suffixes"
    Write-Host "     -primary               Filter -list to only the primary network interface"
    Write-Host "  -set-suffix <list>        Set DNS search suffix list (comma/space separated)"
    Write-Host "  -resolve <list>           Resolve host(s) (supports list or multiple args)"
    Write-Host ""
    Write-Host "COMMON"
    Write-Host "  -json                     Output in machine-readable JSON format"
    Write-Host "  -version                  Show script version"
    Write-Host "  -help                     Show this help message"
    exit 0
}

# --- ARGUMENT MAPPING ---

# Fail-safe block to ensure hyphenated flags are correctly captured across different shells.
if ($null -ne $RemainingArgs -and $RemainingArgs.Count -gt 0) {
    for ($i = 0; $i -lt $RemainingArgs.Count; $i++) {
        $arg = $RemainingArgs[$i]
        switch -Regex ($arg) {
            "^-list$" { $List = $true }
            "^-set-suffix$" {
                if ($i + 1 -lt $RemainingArgs.Count) {
                    $SetSuffix = $RemainingArgs[++$i]
                }
            }
            "^-resolve$" {
                if ($i + 1 -lt $RemainingArgs.Count) {
                    $Resolve = $RemainingArgs[++$i] -split ','
                }
            }
            "^-version$" { $Version = $true }
            "^-json$" { $Json = $true }
            "^-primary$" { $Primary = $true }
            "^-help$|^\?$" { Show-Help }
        }
    }
}

# --- EXECUTION TIER ---

# Orchestration state to determine if any action was triggered.
$executed = $false

# 1. Inspection Engine (-List)
if ($List) {
    # Retrieve all DNS client server addresses, filtering out interfaces with no configured servers.
    $servers = Get-DnsClientServerAddress -AddressFamily IPv4, IPv6 |
        Where-Object { $_.ServerAddresses.Count -gt 0 }

    if ($Primary) {
        # Isolation: Find the primary interface index (the one with the lowest metric default route).
        $primaryIndex = Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric |
            Select-Object -First 1 |
            Select-Object -ExpandProperty InterfaceIndex

        if ($null -ne $primaryIndex) {
            $servers = $servers | Where-Object { $_.InterfaceIndex -eq $primaryIndex }
        } else {
            Write-Warning "Could not determine primary interface (no default gateway found)."
        }
    }

    $formattedServers = $servers | Select-Object InterfaceAlias, ServerAddresses
    $globalSettings = Get-DnsClientGlobalSetting
    $suffixes = $globalSettings.SuffixSearchList

    if ($Json) {
        $payload = [PSCustomObject]@{
            NameServers = $formattedServers
            SearchSuffixes = $suffixes
        }
        $payload | ConvertTo-Json -Depth 5
    } else {
        Write-Host "`n--- DNS Name Servers ---" -ForegroundColor Green
        $formattedServers | Format-Table -AutoSize | Out-String | Write-Host

        Write-Host "--- DNS Search Suffixes ---" -ForegroundColor Green
        if ($null -ne $suffixes -and $suffixes.Count -gt 0) {
            $suffixes | ForEach-Object { Write-Host "  $_" }
        } else {
            Write-Host "  (None configured)" -ForegroundColor Gray
        }
        Write-Host ""
    }
    $executed = $true
}

# 2. Management Engine (-SetSuffix)
if ($null -ne $SetSuffix -and $SetSuffix.Count -gt 0) {
    # Sanitization: Ensure input is treated as a clean array of non-empty strings.
    [string[]]$suffixList = $SetSuffix |
        ForEach-Object { $_ -split '[, ]' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    # Privilege Enforcement: Mandatory check for system-level changes.
    if (-not (Test-IsAdministrator)) {
        if ($Json) {
            [PSCustomObject]@{ Status = "FAIL"; Message = "Administrative privileges are required."; SearchSuffixes = $suffixList } | ConvertTo-Json
        } else {
            Write-Error "Administrative privileges are required to set DNS search suffixes. Please run as Administrator."
        }
        exit 1
    }

    if (-not $Json) { Write-Host "Setting DNS Search Suffixes to: $($suffixList -join ', ')" -ForegroundColor Cyan }

    try {
        Set-DnsClientGlobalSetting -SuffixSearchList $suffixList -ErrorAction Stop
        if ($Json) {
            [PSCustomObject]@{ Status = "PASS"; Message = "DNS search suffixes updated successfully."; SearchSuffixes = $suffixList } | ConvertTo-Json
        } else {
            Write-Host "Success: DNS search suffixes updated." -ForegroundColor Green
        }
    } catch {
        if ($Json) {
            [PSCustomObject]@{ Status = "FAIL"; Message = $_.ToString(); SearchSuffixes = $suffixList } | ConvertTo-Json
        } else {
            Write-Error "Failed to set DNS search suffixes: $_"
        }
        exit 1
    }
    $executed = $true
}

# 3. Resolution Engine (-Resolve)
if ($null -ne $Resolve -and $Resolve.Count -gt 0) {
    $resolutionResults = @()
    foreach ($hostName in $Resolve) {
        # Sanitization: Support comma-separated strings within list elements.
        $targets = $hostName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($target in $targets) {
            if (-not $Json) { Write-Host "Resolving: $target" -ForegroundColor Cyan }
            try {
                # Depth control: Extract core properties and ensure Type is a string for schema consistency.
                $dnsResult = Resolve-DnsName -Name $target -ErrorAction Stop |
                    Select-Object Name, @{ Name = 'Type'; Expression = { $_.Type.ToString() } }, IPAddress, @{ Name = 'Host'; Expression = { $_.NameHost } }
                if ($Json) {
                    $resolutionResults += $dnsResult
                } else {
                    $dnsResult | Format-Table -AutoSize | Out-String | Write-Host
                }
            } catch {
                if ($Json) {
                    $resolutionResults += [PSCustomObject]@{ Name = $target; Status = "FAIL"; Message = $_.ToString() }
                } else {
                    Write-Warning "Could not resolve ${target}: $_"
                }
            }
        }
    }
    if ($Json) { $resolutionResults | ConvertTo-Json }
    $executed = $true
}

# 4. Diagnostics Engine (-Version)
if ($Version) {
    $osInfo = Get-CimInstance Win32_OperatingSystem
    if ($Json) {
        [PSCustomObject]@{ 
            Version   = "1.0.0"
            OS        = $osInfo.Caption
            OSVersion = $osInfo.Version
        } | ConvertTo-Json
    } else {
        Write-Host "1.0.0 ($($osInfo.Caption) - $($osInfo.Version))"
    }
    $executed = $true
}

# Default behavior: Show help if no action was triggered.
if (-not $executed) {
    Show-Help
}
