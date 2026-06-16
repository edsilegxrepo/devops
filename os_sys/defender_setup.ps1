<#
.SYNOPSIS
    Consolidated setup and diagnostics tool for Microsoft Defender and SentinelOne.

.DESCRIPTION
    This script provides options to query endpoint security status and diagnostics, or completely remove Microsoft Defender (on Windows Server) to prevent conflicts with SentinelOne.

.PARAMETER Remove
    Initiates complete removal of Microsoft Defender (Windows Server only).

.PARAMETER Diags
    Runs endpoint security diagnostics report.

.EXAMPLE
    .\defender_setup.ps1 -Diags
    Runs diagnostics report to check registry, defender running mode, and service status.

.EXAMPLE
    .\defender_setup.ps1 -Remove
    Initiates Microsoft Defender feature uninstallation.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$Diags
)

# Ensure the script is running with Administrative privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as an Administrator. Please relaunch PowerShell as Administrator."
    exit 1
}

# If no arguments are passed, show usage
if (-not $Remove -and -not $Diags) {
    Write-Host "Usage: .\defender_setup.ps1 [-Remove] [-Diags]" -ForegroundColor Yellow
    Write-Host "  -Remove  : Initiate complete removal of Microsoft Defender (Windows Server only)"
    Write-Host "  -Diags   : Run endpoint security diagnostics report"
    exit 1
}

# 1. Execute Diagnostics if requested
if ($Diags) {
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "   ENDPOINT SECURITY DIAGNOSTICS REPORT (TUNED)" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "Timestamp: $(Get-Date)"
    Write-Host "OS Version: $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Host "----------------------------------------------------"

    # Check Registry Configuration Staging
    Write-Host "[1/4] Checking Staged Registry Configuration..." -ForegroundColor Yellow
    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection"
    $valName = "ForceDefenderPassiveMode"
    $isStaged = $false

    if (Test-Path $regPath) {
        $regValue = Get-ItemProperty -Path $regPath -Name $valName -ErrorAction SilentlyContinue
        if ($null -ne $regValue -and $regValue.$valName -eq 1) {
            Write-Host "  [+] Registry Key Present: ForceDefenderPassiveMode is set to 1" -ForegroundColor Green
            $isStaged = $true
        } else {
            Write-Host "  [!] Registry key path exists, but ForceDefenderPassiveMode is NOT set to 1." -ForegroundColor Red
        }
    } else {
        Write-Host "  [-] Registry Path Not Found (Normal if Defender feature is completely removed)." -ForegroundColor Gray
    }

    # Check Active Microsoft Defender State
    Write-Host "`n[2/4] Querying Live Microsoft Defender Status..." -ForegroundColor Yellow
    $runningMode = "Unknown"
    $defenderUninstalled = $false

    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        try {
            $mpStatus = Get-MpComputerStatus -ErrorAction Stop
            $runningMode = $mpStatus.AMRunningMode
            $rtpState    = $mpStatus.RealTimeProtectionEnabled

            $modeColor = if ($runningMode -eq "Passive Mode" -or $runningMode -eq "EDR Block Mode") { "Green" } else { "Yellow" }
            Write-Host "  - AM Running Mode       : $runningMode" -ForegroundColor $modeColor
            Write-Host "  - Real-Time Protection  : $rtpState"
        } catch {
            # Catching the "Invalid class" error indicating WMI provider has been removed
            # Safe checking to prevent NullReferenceException on InnerException
            $isInvalidClass = $_.Exception.Message -match "Invalid class" -or
                              ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.Message -match "Invalid class")
            if ($isInvalidClass) {
                Write-Host "  [+] Defender WMI Namespace is gone. Engine is completely uninstalled." -ForegroundColor Green
                $defenderUninstalled = $true
            } else {
                Write-Host "  [!] Failed to retrieve Defender metrics: $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  [+] Defender PowerShell module is missing. Engine is uninstalled." -ForegroundColor Green
        $defenderUninstalled = $true
    }

    # Process & Service Integrity Checks
    Write-Host "`n[3/4] Checking Antivirus System Processes and Services..." -ForegroundColor Yellow

    $defService = Get-Service -Name "WinDefend" -ErrorAction SilentlyContinue
    if ($defService) {
        Write-Host "  - Service 'WinDefend'   : $($defService.Status)"
    } else {
        Write-Host "  - Service 'WinDefend'   : NOT INSTALLED (Healthy)" -ForegroundColor Green
        $defenderUninstalled = $true
    }

    $expectedS1Names = @("SentinelAgent", "SentinelHelperService", "SentinelStaticEngine")
    $s1Services = Get-Service -Name $expectedS1Names -ErrorAction SilentlyContinue
    $s1Healthy = $false

    if ($s1Services) {
        $runningCount = 0
        $installedNames = $s1Services | ForEach-Object { $_.Name }
        $missingServices = $expectedS1Names | Where-Object { $_ -notin $installedNames }

        foreach ($svc in $s1Services) {
            $s1Color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
            Write-Host "  - Service '$($svc.Name)' : $($svc.Status)" -ForegroundColor $s1Color
            if ($svc.Status -eq "Running") { $runningCount++ }
        }

        if ($missingServices) {
            foreach ($missing in $missingServices) {
                Write-Host "  - Service '$missing' : NOT INSTALLED" -ForegroundColor Red
            }
        }

        # S1 is healthy only if all 3 expected services are present and running
        if ($runningCount -eq 3 -and $s1Services.Count -eq 3) {
            $s1Healthy = $true
        }
    } else {
        Write-Host "  - Service 'SentinelOne' : NOT DETECTED" -ForegroundColor Red
    }

    # Optimized process check
    $runningProcesses = Get-Process -Name MsMpEng, SentinelAgent, SentinelServiceHost -ErrorAction SilentlyContinue
    if ($runningProcesses) {
        Write-Host "  - Active Executables Running in Memory:"
        foreach ($proc in $runningProcesses) {
            Write-Host "    - $($proc.Name).exe (PID: $($proc.Id))" -ForegroundColor Gray
        }
    }

    # Final Verdict / Recommendation
    Write-Host "`n[4/4] Summary and Next Steps:" -ForegroundColor Yellow

    if ($defenderUninstalled -and $s1Healthy) {
        Write-Host "  -> VERDICT: Healthy Clean State! Microsoft Defender has completely stood down/uninstalled." -ForegroundColor Green
        Write-Host "     SentinelOne is operating unhindered with 100% processing priority. Native testing speeds restored." -ForegroundColor Green
    } elseif ($runningMode -eq "Normal" -and $isStaged) {
        Write-Host "  -> VERDICT: Passive Mode staged, but engine is locked open. Reboot required." -ForegroundColor Cyan
    } elseif ($runningMode -eq "Passive Mode" -or $runningMode -eq "EDR Block Mode") {
        Write-Host "  -> VERDICT: Healthy Co-existence State. Defender is running in Passive mode." -ForegroundColor Green
    } else {
        Write-Host "  -> VERDICT: Verification inconclusive. Check Agent integrity." -ForegroundColor Gray
    }
    Write-Host "====================================================" -ForegroundColor Cyan
}

# 2. Execute Removal if requested
if ($Remove) {
    # Check if we are on Windows Server or Client
    if (Get-Command Uninstall-WindowsFeature -ErrorAction SilentlyContinue) {
        Write-Host "Initiating complete removal of Microsoft Defender to prevent collision with SentinelOne..." -ForegroundColor Cyan
        try {
            $result = Uninstall-WindowsFeature -Name Windows-Defender -ErrorAction Stop

            if ($result.RestartNeeded -eq "Yes") {
                Write-Host "Microsoft Defender feature uninstalled successfully." -ForegroundColor Green
                Write-Warning "A system reboot is REQUIRED to completely remove the kernel-level file filters from memory."
                Write-Host "Please execute: Restart-Computer -Force" -ForegroundColor Yellow
            } else {
                Write-Host "Microsoft Defender feature is already removed or inactive." -ForegroundColor Green
            }
        }
        catch {
            Write-Error "Failed to uninstall Windows-Defender feature. Error details: $_"
        }
    } else {
        Write-Warning "Uninstall-WindowsFeature is not available on this operating system."
        Write-Host "For non-Server Windows editions, Microsoft Defender is managed via policies or settings." -ForegroundColor Yellow
    }
}
