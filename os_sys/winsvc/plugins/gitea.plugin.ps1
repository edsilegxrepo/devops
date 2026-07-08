#Requires -Version 5.1
<#
.SYNOPSIS
    Gitea plugin - provides doctor (diagnostic) command.

.DESCRIPTION
    Plugin commands for gitea:
    - doctor: Run Gitea's built-in diagnostic checks

.NOTES
    Uses gitea's 'doctor check' command to validate configuration
    and database integrity.

    PSAvoidUsingWriteHost is suppressed because plugins provide user feedback
    via colored console output during interactive service management.
#>

# Suppress Write-Host warning - plugins need colored console output for user feedback
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
param()

$script:PluginCommands = @{

    # Run Gitea diagnostics
    Doctor = {
        param($Config)

        Write-Host "Running $($Config.name) doctor..."
        & $Config.ExePath doctor check --config "$($Config.data)/conf/app.ini"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "$($Config.name) is healthy"
            return $true
        } else {
            Write-Host "$($Config.name) has issues" -ForegroundColor Yellow
            return $false
        }
    }

}
