@{
    RootModule = 'ProcessControl.psm1'
    ModuleVersion = '1.1.0'
    GUID = 'f7d8e9a0-b1c2-4d3e-5f6a-7b8c9d0e1f2a'
    Author = 'System Administrator'
    Description = 'Framework for managing user-space services on Windows'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-ServiceConfig'
        'Get-AllServiceConfigs'
        'Get-ServiceProcess'
        'Test-ServiceRunning'
        'Start-ServiceProcess'
        'Stop-ServiceProcess'
        'Restart-ServiceProcess'
        'Get-ServiceStatus'
        'Invoke-ServiceCommand'
        'Invoke-LogRotation'
        'Enable-ServiceAutoStart'
        'Disable-ServiceAutoStart'
        'Get-ServiceAutoStartStatus'
        'Get-ServiceAutoStartInfo'
    )

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
