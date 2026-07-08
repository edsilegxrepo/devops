<#
.SYNOPSIS
    Process management utility - list, set priority/affinity, and terminate processes.

.DESCRIPTION
    A comprehensive PowerShell utility for managing Windows processes. Provides five
    operational modes for process inspection and control:

    MODES:
        list  - Display processes in a tabular format with key metrics including name,
                PID, status, owner, priority, CPU affinity, CPU time, and memory usage.
                Supports filtering, sorting, and limiting results.

        info  - Show detailed information for specific process(es) including path,
                command line, start time, thread/handle counts, parent process, and
                resource usage. Ideal for troubleshooting and diagnostics.

        set   - Modify process priority class and/or CPU affinity. Supports multiple
                affinity formats (CPU list, hex mask, decimal, or 'all'). Changes take
                effect immediately without requiring process restart.

        kill  - Terminate processes with optional confirmation prompt. Supports force
                mode for scripted/automated scenarios. Reports success/failure for
                each targeted process.

        help  - Display comprehensive usage information including all options,
                examples, and available configuration presets.

    FEATURES:
        - Filter processes by name (substring match) or exact PID
        - Support for comma-separated multiple filters
        - Configuration file presets for common filter groups (browsers, office, etc.)
        - JSON output mode for scripting and pipeline integration
        - Quiet mode for silent operation (exit codes only)
        - User-only filtering to show/affect only current user's processes
        - Sorting and top-N limiting for list mode

    EXIT CODES:
        0 - Success (operation completed, or no matches found)
        1 - Invalid arguments or missing required parameters
        2 - Partial failure (some operations failed, others succeeded)

    CONFIGURATION:
        The script looks for 'procmgr.config.json' in the same directory. This file
        can define filter presets - named groups of process filters for convenience.

        Example config:
        {
            "presets": [
                { "name": "browsers", "filters": ["chrome", "edge", "firefox"] },
                { "name": "office", "filters": ["outlook", "teams", "excel"] }
            ]
        }

    SECURITY CONSIDERATIONS:
        - Setting RealTime priority requires elevated privileges and can destabilize
          the system if misused.
        - Killing system processes may cause system instability or data loss.
        - The -force flag bypasses confirmation - use with caution in scripts.

.PARAMETER Mode
    The operational mode. Valid values: list, info, set, kill, help.
    If omitted, displays help information.

.PARAMETER Filter
    Filter processes by name (substring match) or PID. Accepts multiple values
    as an array or comma-separated string. Can also reference preset names
    defined in the configuration file.

    Examples:
        -filter chrome              # Single filter
        -filter chrome,edge         # Multiple filters
        -filter 1234                # Filter by PID
        -filter browsers            # Use preset from config

.PARAMETER Priority
    Process priority class to set (set mode only). Valid values:
        Idle        (I) - Lowest priority, runs only when system is idle
        BelowNormal (B) - Lower than normal priority
        Normal      (N) - Default priority for most processes
        AboveNormal (A) - Higher than normal priority
        High        (H) - High priority, may affect system responsiveness
        RealTime    (R) - Highest priority, requires admin, use with extreme caution

.PARAMETER Affinity
    CPU affinity mask to set (set mode only). Determines which CPU cores the
    process can run on. Accepts multiple formats:

        all     - Use all available CPUs (removes affinity restriction)
        0,1,2   - CPU list (zero-indexed core numbers)
        0xF     - Hexadecimal bitmask (0xF = cores 0-3)
        15      - Decimal bitmask (15 = cores 0-3)

    Note: CPU numbers are zero-indexed. A system with 8 cores has CPUs 0-7.

.PARAMETER Top
    Limit output to the first N results (list mode only). Applied after sorting.

.PARAMETER SortBy
    Sort results by the specified field (list mode only). Valid values:
        CPU  - Sort by CPU time (descending)
        Mem  - Sort by memory usage (descending)
        Name - Sort by process name (ascending, alphabetical)
        PID  - Sort by process ID (ascending)

.PARAMETER Json
    Output results as JSON instead of formatted tables/lists. Useful for:
        - Scripting and automation
        - Pipeline processing with ConvertFrom-Json
        - Integration with other tools and APIs

    Note: Suppresses informational messages; only JSON output is produced.

.PARAMETER Force
    Skip confirmation prompts (kill mode). Use for automated/scripted scenarios.
    WARNING: Processes will be terminated immediately without user confirmation.

.PARAMETER User
    Filter to show/affect only processes owned by the current user session.
    Useful for avoiding accidental modification of system or other users' processes.

.PARAMETER Quiet
    Suppress all output except errors. The script communicates results via exit
    codes only. Useful for scheduled tasks and silent automation.

.EXAMPLE
    .\procmgr.ps1 list

    List all running processes with default columns (Name, PID, Status, Owner,
    Priority, Affinity, CPU, Memory).

.EXAMPLE
    .\procmgr.ps1 list -filter chrome -top 10 -sortby mem

    List the top 10 Chrome processes sorted by memory usage (highest first).

.EXAMPLE
    .\procmgr.ps1 list -user -sortby cpu -top 20

    List the current user's top 20 processes by CPU time.

.EXAMPLE
    .\procmgr.ps1 list -filter browsers -json | ConvertFrom-Json

    List all browser processes (using preset) and parse the JSON output.

.EXAMPLE
    .\procmgr.ps1 info -filter notepad

    Show detailed information for all notepad processes including path,
    command line, start time, threads, handles, and parent process.

.EXAMPLE
    .\procmgr.ps1 set -priority BelowNormal -filter teams,outlook

    Set Teams and Outlook processes to below-normal priority to reduce
    their impact on system responsiveness.

.EXAMPLE
    .\procmgr.ps1 set -affinity 0,1 -filter myapp

    Restrict 'myapp' processes to run only on CPU cores 0 and 1.

.EXAMPLE
    .\procmgr.ps1 set -priority Normal -affinity all -filter chrome

    Reset Chrome processes to normal priority and allow them to use all CPUs.

.EXAMPLE
    .\procmgr.ps1 kill -filter notepad

    Terminate all notepad processes (with confirmation prompt).

.EXAMPLE
    .\procmgr.ps1 kill -filter notepad -force -quiet

    Silently terminate all notepad processes without confirmation.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.String
        When -Json is specified, outputs JSON-formatted process data.

    Microsoft.PowerShell.Commands.Internal.Format
        When -Json is not specified, outputs formatted tables or lists.

.NOTES
    Version:        1.0.0
    Author:         Infrastructure Team
    Requires:       PowerShell 5.1 or later
    Platform:       Windows only (uses Windows-specific process APIs)

    The script uses session ID comparison to determine process ownership rather
    than WMI queries for performance reasons. This means "User" indicates the
    process runs in the current user's session, while "Other" indicates a
    different session (system, service, or another user).

    CPU affinity changes are immediate but not persistent - they will reset
    when the process restarts. For persistent affinity, use Task Scheduler
    or process-specific configuration.

.LINK
    https://docs.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights

.LINK
    https://docs.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities
#>

#Requires -Version 5.1

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "",
    Justification = "Write-Host is intentional for colored console output in an interactive CLI tool")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "",
    Justification = "Parameters are accessed via script scope for use in nested functions")]
param(
    [Parameter(Position = 0, HelpMessage = "Operational mode: list, info, set, kill, or help")]
    [ValidateSet('list', 'info', 'set', 'kill', 'help')]
    [string]$Mode,

    [Parameter(HelpMessage = "Filter by process name (substring) or PID. Supports comma-separated values and config presets.")]
    [string[]]$Filter,

    [Parameter(HelpMessage = "Priority class to set: Idle, BelowNormal, Normal, AboveNormal, High, RealTime")]
    [ValidateSet('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High', 'RealTime')]
    [string]$Priority,

    [Parameter(HelpMessage = "CPU affinity: 'all', CPU list (0,1,2), hex (0xF), or decimal mask")]
    [string]$Affinity,

    [Parameter(HelpMessage = "Limit output to top N results (list mode)")]
    [int]$Top,

    [Parameter(HelpMessage = "Sort field: CPU, Mem, Name, or PID (list mode)")]
    [ValidateSet('CPU', 'Mem', 'Name', 'PID')]
    [string]$SortBy,

    [Parameter(HelpMessage = "Output as JSON for scripting/automation")]
    [switch]$Json,

    [Parameter(HelpMessage = "Skip confirmation prompts (kill mode)")]
    [switch]$Force,

    [Parameter(HelpMessage = "Filter to current user's processes only")]
    [switch]$User,

    [Parameter(HelpMessage = "Suppress all output; communicate via exit codes only")]
    [switch]$Quiet
)

#region Initialization
# ============================================================================
# INITIALIZATION
# ============================================================================
# Set up strict mode, error handling, and script-level constants.
# These values are used throughout the script and should not be modified
# during execution.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Configuration file path - expected in the same directory as the script
$script:ConfigPath = Join-Path $PSScriptRoot 'procmgr.config.json'

# Current user's session ID - used for owner detection (faster than WMI queries)
$script:CurrentSessionId = (Get-Process -Id $PID).SessionId

# CPU topology information - used for affinity validation and display
$script:CpuCount = [Environment]::ProcessorCount
$script:AllCpuMask = [long]([Math]::Pow(2, $script:CpuCount) - 1)

# Exit codes - provides granular feedback for automation and CI/CD pipelines
$script:EXIT_SUCCESS = 0         # Operation completed successfully
$script:EXIT_INVALID_ARGS = 1    # Invalid arguments or missing required parameters
$script:EXIT_PARTIAL_FAILURE = 2 # Some operations failed (e.g., couldn't kill some processes)

#endregion

#region Output Helpers
# ============================================================================
# OUTPUT HELPERS
# ============================================================================
# Functions for consistent output handling across all modes. These respect
# the -Json and -Quiet flags to control output format and verbosity.
# ============================================================================

function Write-Log {
    <#
    .SYNOPSIS
        Write a message to the console with appropriate formatting.

    .DESCRIPTION
        Centralized logging function that respects -Json and -Quiet flags.
        Messages are suppressed in JSON mode (to keep output clean) and
        in Quiet mode (for silent operation).

    .PARAMETER Message
        The message text to display.

    .PARAMETER Level
        Message severity: Info (default), Warning, or Error.
        - Info: Standard white text
        - Warning: Yellow text via Write-Warning
        - Error: Red text for visibility
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    # Suppress all logging in JSON or Quiet mode
    if ($script:Json -or $script:Quiet) { return }

    switch ($Level) {
        'Info' { Write-Host $Message }
        'Warning' { Write-Warning $Message }
        'Error' { Write-Host $Message -ForegroundColor Red }
    }
}

function Write-JsonOrTable {
    <#
    .SYNOPSIS
        Output results as JSON or formatted table/list based on -Json flag.

    .DESCRIPTION
        Handles the dual output requirement: JSON for scripting, formatted
        tables/lists for interactive use. Ensures consistent array output
        in JSON mode even for single items (PS 5.1 compatibility).

    .PARAMETER Results
        Array of objects to output.

    .PARAMETER AsTable
        If specified, use Format-Table; otherwise use Format-List.
        Tables are better for list mode (many items, few properties).
        Lists are better for info mode (few items, many properties).
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Results,

        [switch]$AsTable
    )

    # Quiet mode suppresses all output
    if ($script:Quiet) { return }

    if ($script:Json) {
        # Ensure array output even for single item (PS 5.1 doesn't have -AsArray)
        # This provides consistent JSON structure for consumers
        if ($Results.Count -eq 1) {
            ConvertTo-Json -InputObject @($Results) -Depth 5
        } else {
            ConvertTo-Json -InputObject $Results -Depth 5
        }
    } elseif ($AsTable) {
        $Results | Format-Table -AutoSize
    } else {
        $Results | Format-List
    }
}

function Exit-WithError {
    <#
    .SYNOPSIS
        Display an error message and exit with the specified code.

    .DESCRIPTION
        Provides consistent error handling across all modes. In JSON mode,
        outputs a JSON object with the error; otherwise uses Write-Error.

    .PARAMETER Message
        The error message to display.

    .PARAMETER ExitCode
        The exit code to return (default: EXIT_INVALID_ARGS).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [int]$ExitCode = $script:EXIT_INVALID_ARGS
    )

    if ($script:Json) {
        [PSCustomObject]@{ Error = $Message } | ConvertTo-Json
    } else {
        Write-Error $Message
    }
    exit $ExitCode
}

#endregion

#region Configuration
# ============================================================================
# CONFIGURATION
# ============================================================================
# Functions for loading and processing the configuration file. The config
# file is optional - the script works without it but loses preset support.
# ============================================================================

function Get-Config {
    <#
    .SYNOPSIS
        Load and parse the configuration file.

    .DESCRIPTION
        Attempts to load procmgr.config.json from the script directory.
        Returns $null if the file doesn't exist or can't be parsed.
        Invalid JSON triggers a warning but doesn't halt execution.

    .OUTPUTS
        PSCustomObject with configuration data, or $null if unavailable.
    #>
    if (-not (Test-Path $script:ConfigPath)) { return $null }

    try {
        return Get-Content $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Log "Warning: Failed to parse config file: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Expand-FilterPreset {
    <#
    .SYNOPSIS
        Expand filter preset names to their constituent filters.

    .DESCRIPTION
        Looks up each filter value in the configuration presets. If a preset
        with that name exists, expands it to the preset's filter list.
        Non-preset values pass through unchanged.

    .PARAMETER FilterInput
        Array of filter strings, which may include preset names.

    .OUTPUTS
        Array of expanded filter strings with presets resolved.

    .EXAMPLE
        # If config has preset "browsers" = ["chrome", "edge", "firefox"]
        Expand-FilterPreset -FilterInput @("browsers", "notepad")
        # Returns: @("chrome", "edge", "firefox", "notepad")
    #>
    param([string[]]$FilterInput)

    if (-not $FilterInput) { return $null }

    $config = Get-Config
    if (-not $config) { return $FilterInput }

    # Check if presets property exists (strict mode safe)
    $hasPresets = $config.PSObject.Properties.Name -contains 'presets'
    if (-not $hasPresets -or -not $config.presets) { return $FilterInput }

    $expanded = foreach ($f in $FilterInput) {
        $trimmed = $f.Trim()
        $preset = $config.presets | Where-Object { $_.name -eq $trimmed } | Select-Object -First 1
        if ($preset) {
            # Expand preset to its filter list
            $preset.filters
        } else {
            # Not a preset - pass through as-is
            $trimmed
        }
    }
    return $expanded
}

#endregion

#region Process Helpers
# ============================================================================
# PROCESS HELPERS
# ============================================================================
# Core functions for process retrieval, filtering, and manipulation.
# These provide the foundation for all operational modes.
# ============================================================================

function Get-FilteredProcess {
    <#
    .SYNOPSIS
        Retrieve processes matching the specified filters.

    .DESCRIPTION
        Gets all processes and applies optional filters. Supports:
        - Name substring matching (case-insensitive)
        - Exact PID matching
        - Multiple filters (OR logic)
        - User session filtering via -User flag
        - Preset expansion from config file

    .PARAMETER FilterText
        Array of filter strings. Each can be a name substring, PID,
        preset name, or comma-separated list.

    .OUTPUTS
        Array of System.Diagnostics.Process objects matching the filters.
    #>
    param([string[]]$FilterText)

    $procs = Get-Process -ErrorAction SilentlyContinue

    # Filter by current user's session if -User flag is set
    if ($script:User) {
        $procs = $procs | Where-Object { $_.SessionId -eq $script:CurrentSessionId }
    }

    # No filter = return all processes
    if (-not $FilterText) { return $procs }

    # Expand presets and flatten comma-separated values into individual filters
    $filters = Expand-FilterPreset -FilterInput $FilterText |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }

    # Apply filters with OR logic (match any filter)
    return $procs | Where-Object {
        $proc = $_
        foreach ($f in $filters) {
            # Match by name substring OR exact PID
            if ($proc.ProcessName -like "*$f*" -or $proc.Id -eq $f) { return $true }
        }
        return $false
    }
}

function Get-MatchedProcess {
    <#
    .SYNOPSIS
        Get filtered processes with validation for modes that require matches.

    .DESCRIPTION
        Wrapper around Get-FilteredProcess that enforces the -Filter parameter
        requirement and handles the "no matches" case gracefully. Used by
        info, set, and kill modes which require at least one target process.

    .PARAMETER ModeName
        The mode name for error messages (e.g., 'info', 'set', 'kill').

    .OUTPUTS
        Array of matching processes. Exits with code 0 if no matches.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ModeName
    )

    # These modes require explicit filter to prevent accidental mass operations
    if (-not $script:Filter) {
        Exit-WithError "The -filter parameter is required for '$ModeName' mode."
    }

    $processes = @(Get-FilteredProcess -FilterText $script:Filter)

    # No matches is not an error, but we exit cleanly with a warning
    if ($processes.Count -eq 0) {
        Write-Log "No processes found matching '$($script:Filter -join ', ')'." -Level Warning
        exit $script:EXIT_SUCCESS
    }

    return $processes
}

function Get-PriorityCode {
    <#
    .SYNOPSIS
        Convert a priority class to a single-letter code for display.

    .DESCRIPTION
        Maps priority class names to compact codes for tabular display:
        Idle=I, BelowNormal=B, Normal=N, AboveNormal=A, High=H, RealTime=R

    .PARAMETER PriorityClass
        The priority class value (string or ProcessPriorityClass enum).

    .OUTPUTS
        Single-letter code, or '-' if priority is unavailable.
    #>
    param($PriorityClass)

    if (-not $PriorityClass) { return '-' }

    $map = @{
        'Idle' = 'I'
        'BelowNormal' = 'B'
        'Normal' = 'N'
        'AboveNormal' = 'A'
        'High' = 'H'
        'RealTime' = 'R'
    }

    $key = $PriorityClass.ToString()
    if ($map.ContainsKey($key)) { return $map[$key] }
    return '-'
}

function Get-AffinityDisplay {
    <#
    .SYNOPSIS
        Convert a process's CPU affinity mask to human-readable format.

    .DESCRIPTION
        Reads the process's ProcessorAffinity and converts to display format:
        - "All" if all CPUs are enabled
        - Comma-separated list of CPU numbers (e.g., "0,1,2")
        - "-" if affinity cannot be read (access denied or not set)

    .PARAMETER Process
        The process object to read affinity from.

    .OUTPUTS
        String representation of the CPU affinity.
    #>
    param([System.Diagnostics.Process]$Process)

    try {
        $affinity = $Process.ProcessorAffinity
        if (-not $affinity -or $affinity -eq [IntPtr]::Zero) { return '-' }

        $mask = [long]$affinity
        if ($mask -eq $script:AllCpuMask) { return 'All' }

        # Convert bitmask to list of CPU numbers
        $cpus = for ($i = 0; $i -lt $script:CpuCount; $i++) {
            if ($mask -band [long][Math]::Pow(2, $i)) { $i }
        }
        return $cpus -join ','
    } catch {
        # Access denied for system/protected processes
        return '-'
    }
}

function ConvertTo-AffinityMask {
    <#
    .SYNOPSIS
        Convert various affinity formats to a numeric bitmask.

    .DESCRIPTION
        Accepts multiple input formats for user convenience:
        - "all" - All CPUs (full mask)
        - "0,1,2" - CPU list (zero-indexed)
        - "0xF" - Hexadecimal mask
        - "15" - Decimal mask

        Validates CPU numbers against the system's actual CPU count.

    .PARAMETER Value
        The affinity value in any supported format.

    .OUTPUTS
        Int64 bitmask suitable for ProcessorAffinity property.

    .EXAMPLE
        ConvertTo-AffinityMask -Value "0,1"  # Returns 3 (binary: 11)
        ConvertTo-AffinityMask -Value "all"  # Returns full mask for system
        ConvertTo-AffinityMask -Value "0xF"  # Returns 15
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $lower = $Value.ToLower()

    # "all" - all CPUs enabled
    if ($lower -eq 'all') {
        return $script:AllCpuMask
    }

    # Hex format: 0xF, 0xFF, etc.
    if ($lower -match '^0x[0-9a-f]+$') {
        return [Convert]::ToInt64($Value, 16)
    }

    # CPU list: 0,1,2 (requires at least one comma to distinguish from decimal)
    if ($Value -match '^\d+(,\s*\d+)+$') {
        $mask = 0
        foreach ($cpu in ($Value -split ',')) {
            $cpuNum = [int]$cpu.Trim()
            if ($cpuNum -ge $script:CpuCount) {
                throw "CPU $cpuNum is invalid. This system has $($script:CpuCount) CPUs (0-$($script:CpuCount - 1))."
            }
            $mask = $mask -bor [long][Math]::Pow(2, $cpuNum)
        }
        return $mask
    }

    # Single number - treated as decimal mask or single CPU
    if ($Value -match '^\d+$') {
        return [long]$Value
    }

    throw "Invalid affinity format: '$Value'. Use 'all', CPU list (0,1,2), hex (0xF), or decimal."
}

function Get-ProcessDetail {
    <#
    .SYNOPSIS
        Retrieve detailed information about a single process.

    .DESCRIPTION
        Gathers comprehensive process information including:
        - Basic: Name, PID, Status, Path
        - Resources: CPU time, Memory (working set and private)
        - Threads and handles count
        - Priority and affinity
        - Parent process information
        - Command line (via CIM/WMI)

        Some properties may be unavailable for system/protected processes.

    .PARAMETER Process
        The process object to inspect.

    .OUTPUTS
        PSCustomObject with detailed process properties.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    # Get extended info via CIM (command line and parent PID)
    # This is a single WMI call, much faster than per-property queries
    $cmdLine = $null
    $parentPid = $null

    try {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)" -Property CommandLine, ParentProcessId -ErrorAction Stop
        $cmdLine = $cim.CommandLine
        $parentPid = $cim.ParentProcessId
    } catch {
        # Some processes don't allow access (system, protected) - this is expected
        Write-Verbose "Cannot access CIM info for process $($Process.Id): $($_.Exception.Message)"
    }

    # Resolve parent process name if we have the PID
    $parentName = $null
    if ($parentPid) {
        try {
            $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
            $parentName = $parent.ProcessName
        } catch {
            # Parent may have exited - this is expected and common
            Write-Verbose "Parent process $parentPid not found"
        }
    }

    # Some properties throw on access for protected processes
    $startTime = try { $Process.StartTime } catch { $null }
    $priority = try { $Process.PriorityClass } catch { $null }

    return [PSCustomObject]@{
        Name = $Process.ProcessName
        PID = $Process.Id
        Status = if ($Process.Responding) { 'Running' } else { 'Not Responding' }
        Path = $Process.Path
        CommandLine = $cmdLine
        StartTime = $startTime
        CPU = [math]::Round($Process.CPU, 2)
        MemoryMB = [math]::Round($Process.WorkingSet64 / 1MB, 1)
        PrivateMemoryMB = [math]::Round($Process.PrivateMemorySize64 / 1MB, 1)
        Threads = $Process.Threads.Count
        Handles = $Process.HandleCount
        Priority = $priority
        Affinity = Get-AffinityDisplay -Process $Process
        ParentName = $parentName
        ParentPID = $parentPid
    }
}

function Confirm-Action {
    <#
    .SYNOPSIS
        Prompt user for confirmation before destructive operations.

    .DESCRIPTION
        Displays a list of affected processes and prompts for Y/N confirmation.
        Bypassed when -Force, -Json, or -Quiet flags are set.

    .PARAMETER Processes
        Array of processes that will be affected.

    .PARAMETER Action
        Description of the action (e.g., "terminate", "modify").

    .OUTPUTS
        Boolean indicating whether to proceed.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Processes,

        [Parameter(Mandatory)]
        [string]$Action
    )

    # Skip confirmation in automated modes
    if ($script:Force -or $script:Json -or $script:Quiet) { return $true }

    Write-Host "Will $Action $($Processes.Count) process(es):"
    foreach ($proc in $Processes) {
        Write-Host "  - $($proc.ProcessName) (PID: $($proc.Id))"
    }

    $confirm = Read-Host "Continue? (y/N)"
    return $confirm -match '^y(es)?$'
}

#endregion

#region Mode Handlers
# ============================================================================
# MODE HANDLERS
# ============================================================================
# Implementation of each operational mode. Each function is responsible for
# its complete workflow: validation, execution, output, and error handling.
# ============================================================================

function Invoke-ListMode {
    <#
    .SYNOPSIS
        List processes in tabular format with filtering and sorting.

    .DESCRIPTION
        Displays processes with key metrics:
        - Name: Process name
        - PID: Process ID
        - Status: Running or Not Responding
        - Owner: User (current session) or Other
        - Pri: Priority code (I/B/N/A/H/R)
        - Affinity: CPU affinity (All or CPU list)
        - CPU: Total CPU time in seconds
        - MemMB: Working set memory in MB

        Supports filtering, sorting, and top-N limiting via parameters.
    #>
    $processes = Get-FilteredProcess -FilterText $Filter

    # Build result objects with display-friendly properties
    $results = @(foreach ($proc in $processes) {
            [PSCustomObject]@{
                Name = $proc.ProcessName
                PID = $proc.Id
                Status = if ($proc.Responding) { 'Running' } else { 'Not Responding' }
                Owner = if ($proc.SessionId -eq $script:CurrentSessionId) { 'User' } else { 'Other' }
                Pri = Get-PriorityCode $proc.PriorityClass
                Affinity = Get-AffinityDisplay -Process $proc
                CPU = [math]::Round($proc.CPU, 1)
                MemMB = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            }
        })

    # Apply sorting if specified
    if ($SortBy) {
        $results = switch ($SortBy) {
            'CPU' { $results | Sort-Object CPU -Descending }
            'Mem' { $results | Sort-Object MemMB -Descending }
            'Name' { $results | Sort-Object Name }
            'PID' { $results | Sort-Object PID }
        }
    }

    # Apply top-N limit if specified
    if ($Top -gt 0) {
        $results = @($results | Select-Object -First $Top)
    }

    # Handle empty results
    if ($results.Count -eq 0) {
        if ($script:Json) {
            Write-Host '[]'
        }
        return
    }

    Write-JsonOrTable -Results $results -AsTable
}

function Invoke-InfoMode {
    <#
    .SYNOPSIS
        Display detailed information for specific processes.

    .DESCRIPTION
        Shows comprehensive details for each matching process including
        path, command line, resource usage, thread/handle counts, and
        parent process information. Uses Format-List for readability.
    #>
    $processes = Get-MatchedProcess -ModeName 'info'
    $results = @(foreach ($proc in $processes) {
            Get-ProcessDetail -Process $proc
        })
    Write-JsonOrTable -Results $results
}

function Invoke-KillMode {
    <#
    .SYNOPSIS
        Terminate processes matching the filter.

    .DESCRIPTION
        Kills all processes matching the filter. Prompts for confirmation
        unless -Force is specified. Reports success/failure for each process
        and returns appropriate exit code for partial failures.
    #>
    $processes = Get-MatchedProcess -ModeName 'kill'

    # Confirm before destructive operation
    if (-not (Confirm-Action -Processes $processes -Action 'terminate')) {
        Write-Log "Cancelled."
        exit $script:EXIT_SUCCESS
    }

    $results = [System.Collections.ArrayList]::new()
    $hasErrors = $false

    foreach ($proc in $processes) {
        $result = [PSCustomObject]@{
            Name = $proc.ProcessName
            PID = $proc.Id
            Success = $false
            Error = $null
        }

        try {
            $proc.Kill()
            $null = $proc.WaitForExit(5000)  # Wait up to 5 seconds for clean exit
            $result.Success = $true
            Write-Log "Killed '$($proc.ProcessName)' (PID: $($proc.Id))"
        } catch {
            $result.Error = $_.Exception.Message
            $hasErrors = $true
            Write-Log "Failed to kill '$($proc.ProcessName)' (PID: $($proc.Id)): $($_.Exception.Message)" -Level Warning
        }

        $null = $results.Add($result)
    }

    # Output results in JSON mode
    if ($script:Json) { Write-JsonOrTable -Results $results.ToArray() }

    # Exit with partial failure code if any kills failed
    if ($hasErrors) { exit $script:EXIT_PARTIAL_FAILURE }
}

function Invoke-SetMode {
    <#
    .SYNOPSIS
        Set priority and/or CPU affinity for processes.

    .DESCRIPTION
        Modifies process priority class and/or processor affinity for all
        matching processes. Validates affinity before making any changes
        to ensure consistent behavior (all-or-nothing on validation failure).
    #>
    # Require at least one setting to change
    if (-not $Priority -and -not $Affinity) {
        Exit-WithError "Specify -priority and/or -affinity to set."
    }

    $processes = Get-MatchedProcess -ModeName 'set'

    # Pre-validate affinity before modifying any processes
    # This ensures we don't partially apply changes on validation failure
    $affinityValue = $null
    if ($Affinity) {
        try {
            $affinityValue = ConvertTo-AffinityMask -Value $Affinity
        } catch {
            Exit-WithError $_.Exception.Message
        }
    }

    $results = [System.Collections.ArrayList]::new()
    $hasErrors = $false

    foreach ($proc in $processes) {
        $result = [PSCustomObject]@{
            Name = $proc.ProcessName
            PID = $proc.Id
            Priority = $null
            Affinity = $null
            Success = $false
            Error = $null
        }

        try {
            if ($Priority) {
                $proc.PriorityClass = $Priority
                $result.Priority = $Priority
                Write-Log "Set priority of '$($proc.ProcessName)' (PID: $($proc.Id)) to $Priority"
            }

            if ($affinityValue) {
                $proc.ProcessorAffinity = [IntPtr]$affinityValue
                $result.Affinity = $affinityValue
                Write-Log "Set affinity of '$($proc.ProcessName)' (PID: $($proc.Id)) to $affinityValue (CPUs: $Affinity)"
            }

            $result.Success = $true
        } catch {
            $result.Error = $_.Exception.Message
            $hasErrors = $true
            Write-Log "Failed to modify '$($proc.ProcessName)' (PID: $($proc.Id)): $($_.Exception.Message)" -Level Warning
        }

        $null = $results.Add($result)
    }

    # Output results in JSON mode
    if ($script:Json) { Write-JsonOrTable -Results $results.ToArray() }

    # Exit with partial failure code if any modifications failed
    if ($hasErrors) { exit $script:EXIT_PARTIAL_FAILURE }
}

function Show-Help {
    <#
    .SYNOPSIS
        Display comprehensive help information.

    .DESCRIPTION
        Shows usage information, all available options, examples, and
        any configured presets from the config file.
    #>
    # Build presets section if config exists and has presets
    $configSection = ""
    $config = Get-Config
    $hasPresets = $config -and ($config.PSObject.Properties.Name -contains 'presets') -and $config.presets
    if ($hasPresets) {
        $presetLines = foreach ($p in $config.presets) {
            "      $($p.name) = $($p.filters -join ',')"
        }
        $configSection = @"

PRESETS (from procmgr.config.json):
$($presetLines -join "`n")
"@
    }

    Write-Host @"
procmgr.ps1 - Process Management Utility

USAGE:
    .\procmgr.ps1 <mode> [options]

MODES:
    list    List processes (name, pid, status, owner, priority, affinity, cpu, mem)
    info    Detailed info for specific process(es)
    set     Set priority and/or CPU affinity
    kill    Terminate processes
    help    Show this help message

OPTIONS:
    -filter <string>    Filter by name (substring) or PID. Comma-separated for multiple.
                        Can also use preset names from config file.
    -user               Only show/affect processes owned by current user
    -priority <level>   Idle (I), BelowNormal (B), Normal (N), AboveNormal (A), High (H), RealTime (R)
    -affinity <value>   "all", CPU list (0,1,2), hex (0xF), or decimal (15)
    -top <N>            Show only top N results (list mode)
    -sortby <field>     Sort by: CPU, Mem, Name, PID (list mode)
    -json               Output as JSON
    -force              Skip confirmation prompts
    -quiet              Suppress all output except errors

EXAMPLES:
    .\procmgr.ps1 list                                  # List all processes
    .\procmgr.ps1 list -user -top 10 -sortby mem        # My top 10 by memory
    .\procmgr.ps1 list -filter chrome,edge -json        # JSON output
    .\procmgr.ps1 list -filter browsers                 # Use preset
    .\procmgr.ps1 info -filter notepad                  # Detailed process info
    .\procmgr.ps1 set -priority BelowNormal -filter teams,outlook
    .\procmgr.ps1 set -affinity 0,1,2 -filter myapp     # Limit to CPUs 0,1,2
    .\procmgr.ps1 set -affinity all -filter myapp       # Use all CPUs
    .\procmgr.ps1 kill -filter notepad                  # Kill with confirmation
    .\procmgr.ps1 kill -filter notepad -force -quiet    # Silent kill
$configSection
CONFIG FILE:
    Create procmgr.config.json in the same directory:
    {
      "presets": [
        { "name": "browsers", "filters": ["chrome", "edge", "firefox"] },
        { "name": "office", "filters": ["outlook", "teams", "excel", "word"] }
      ]
    }

EXIT CODES:
    0   Success
    1   Invalid arguments or missing required parameters
    2   Partial failure (some operations failed)
"@
}

#endregion

#region Main Entry Point
# ============================================================================
# MAIN ENTRY POINT
# ============================================================================
# Script execution starts here. Validates mode and dispatches to the
# appropriate handler function.
# ============================================================================

# No mode specified - show help
if (-not $Mode) {
    Show-Help
    exit $script:EXIT_SUCCESS
}

# Dispatch to mode handler
switch ($Mode) {
    'help' { Show-Help }
    'list' { Invoke-ListMode }
    'info' { Invoke-InfoMode }
    'kill' { Invoke-KillMode }
    'set' { Invoke-SetMode }
}

exit $script:EXIT_SUCCESS

#endregion
