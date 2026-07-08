#Requires -Version 5.1
<#
.SYNOPSIS
    Nginx plugin - provides reload and test commands for nginx service.

.DESCRIPTION
    Plugin commands for nginx:
    - reload: Reload nginx configuration without stopping the service
    - test:   Validate nginx configuration syntax

.NOTES
    Nginx outputs to stderr even on success, so ErrorActionPreference
    is temporarily set to Continue and we check $LASTEXITCODE instead.

    PSAvoidUsingWriteHost is suppressed because plugins provide user feedback
    via colored console output during interactive service management.
#>

# Suppress Write-Host warning - plugins need colored console output for user feedback
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
param()

$script:PluginCommands = @{

    # Reload nginx configuration (hot reload, no downtime)
    Reload = {
        param($Config)

        if (-not (Test-ServiceRunning -Name $Config.name)) {
            Write-Host "$($Config.name) is not running"
            return $false
        }

        # Test config first (nginx outputs to stderr even on success)
        Write-Host "Testing configuration..."
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $testOutput = & $Config.ExePath -t -c "$($Config.home)/conf/nginx.conf" -p $Config.home 2>&1
        $testExitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEAP

        if ($testExitCode -ne 0) {
            Write-Host "ERROR: configuration test failed - reload aborted" -ForegroundColor Red
            $testOutput | ForEach-Object { Write-Host $_ }
            return $false
        }

        Write-Host "Reloading $($Config.name) configuration"
        $ErrorActionPreference = "Continue"
        & $Config.ExePath -s reload -c "$($Config.home)/conf/nginx.conf" -p $Config.home 2>&1 | Out-Null
        $reloadExitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEAP

        if ($reloadExitCode -eq 0) {
            Write-Host "$($Config.name) configuration reloaded"
            return $true
        } else {
            Write-Host "ERROR: $($Config.name) reload failed" -ForegroundColor Red
            return $false
        }
    }

    # Test nginx configuration syntax
    Test = {
        param($Config)

        Write-Host "Testing $($Config.name) configuration..."
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & $Config.ExePath -t -c "$($Config.home)/conf/nginx.conf" -p $Config.home 2>&1 | ForEach-Object { Write-Host $_ }
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEAP
        return $exitCode -eq 0
    }

}
