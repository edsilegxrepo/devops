#Requires -Version 5.1
<#
.SYNOPSIS
    SFTPGo plugin - provides ping (health check) command.

.DESCRIPTION
    Plugin commands for sftpgo:
    - ping: Health check via HTTPS endpoint or sftpgo CLI

.NOTES
    Uses System.Net.WebClient instead of Invoke-WebRequest for PS 5.1 compatibility.
    Temporarily bypasses certificate validation for self-signed certs (internal use only).
    The original ServerCertificateValidationCallback is saved and restored in finally block.

    PSAvoidUsingWriteHost is suppressed because plugins provide user feedback
    via colored console output during interactive service management.
#>

# Suppress Write-Host warning - plugins need colored console output for user feedback
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
param()

$script:PluginCommands = @{

    # Health check - ping the SFTPGo service
    Ping = {
        param($Config)

        Write-Host "Pinging $($Config.name)..."

        # Prefer healthUrl if configured (HTTPS health endpoint)
        if ($Config.healthUrl) {
            $webClient = $null
            $originalCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback

            try {
                # Temporarily bypass certificate validation for self-signed certs
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

                $webClient = New-Object System.Net.WebClient
                $response = $webClient.DownloadString($Config.healthUrl)

                if ($response -match "ok") {
                    Write-Host "$($Config.name) is healthy"
                    return $true
                } else {
                    Write-Host "$($Config.name) unexpected response: $response" -ForegroundColor Yellow
                    return $false
                }
            } catch {
                Write-Host "$($Config.name) is not responding: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            } finally {
                # Restore original callback
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
                # Dispose WebClient
                if ($webClient) {
                    $webClient.Dispose()
                }
            }
        } else {
            # Fall back to sftpgo ping command
            & $Config.ExePath ping --config-dir $Config.data 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "$($Config.name) is healthy"
                return $true
            } else {
                Write-Host "$($Config.name) is not responding" -ForegroundColor Red
                return $false
            }
        }
    }

}
