<#
.SYNOPSIS
    Automates the update of Cygwin and MSYS2 environments.

.DESCRIPTION
    OBJECTIVE:
    To provide a headless, automated update utility for Windows-based POSIX environments.
    The script ensures that Cygwin and MSYS2 are kept up-to-date with zero manual
    intervention, while preventing PATH collisions between the two systems.

    CORE COMPONENTS:
    1. Argument Mapping: Manual fail-safe logic for non-standard CLI flags (e.g., --update-all).
    2. Path Isolation Tier: Functions to construct and apply temporary, clean PATH environments.
    3. Update Engines: Specialized logic for Cygwin (setup-x86_64.exe) and MSYS2 (pacman).
    4. Orchestrator: Main execution logic that triggers isolated updates based on user flags.

    FUNCTIONALITY & DATA FLOW:
    - Input: CLI switches or environment variables (CYGWIN_HOME, MSYS_HOME).
    - Isolation: Before each update, the script filters the current PATH to remove
      competing POSIX binaries, ensuring the update tools use the correct runtime.
    - Automation: Executes update processes with hidden windows and unattended flags.
    - Optimization: MSYS2 update uses output analysis to skip redundant cycles.

.PARAMETER update-all
    Updates both Cygwin and MSYS2 in sequence.

.PARAMETER update-cygwin
    Updates only the Cygwin environment using setup-x86_64.exe.

.PARAMETER update-msys
    Updates only the MSYS2 environment using pacman -Syu.

.PARAMETER LogPath
    Optional file path to save session logs for auditing and debugging.

.PARAMETER CygwinMirror
    Optional URL for the Cygwin mirror. Defaults to mirrors.kernel.org.

.PARAMETER Json
    Optional switch to format all logs, warnings, errors, and environment info in structured ndjson (no colorization) for CI/CD pipelines.

.EXAMPLE
    .\winposix_update.ps1 --update-all --LogPath "C:\logs\winposix.log"

.EXAMPLE
    .\winposix_update.ps1 --update-all --json
#>

[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$UpdateAll,

    [Parameter(Mandatory = $false)]
    [switch]$UpdateCygwin,

    [Parameter(Mandatory = $false)]
    [switch]$UpdateMsys,

    [Parameter(Mandatory = $false)]
    [switch]$InstallCygwin,

    [Parameter(Mandatory = $false)]
    [switch]$InstallMsys,

    [Parameter(Mandatory = $false)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [Alias("help")]
    [switch]$ShowHelp,

    [Parameter(Mandatory = $false)]
    [Alias("info")]
    [switch]$ShowInfo,

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [switch]$Json,

    [Parameter(Mandatory = $false)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "")]
    [string]$CygwinMirror = "https://mirrors.kernel.org/sourceware/cygwin/",

    # Capture any unbound arguments (like --update-cygwin) to support standard Linux-style flags.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

# Set strict mode to ensure absolute reliability in variable and property references.
Set-StrictMode -Version Latest

# Suppress progress bars for Invoke-WebRequest/RestMethod to ensure headless execution.
$ProgressPreference = 'SilentlyContinue'

# MANUAL ARGUMENT MAPPING:
# This fail-safe block ensures that flags like --update-all are correctly captured
# even if the shell or calling environment has non-standard parameter binding.
if ($null -ne $RemainingArgs -and $RemainingArgs.Count -gt 0) {
    if ($RemainingArgs -match "--update-all") { $UpdateAll = $true }
    if ($RemainingArgs -match "--update-cygwin") { $UpdateCygwin = $true }
    if ($RemainingArgs -match "--update-msys") { $UpdateMsys = $true }
    if ($RemainingArgs -match "--install-cygwin") { $InstallCygwin = $true }
    if ($RemainingArgs -match "--install-msys") { $InstallMsys = $true }
    if ($RemainingArgs -match "--help") { $ShowHelp = $true }
    if ($RemainingArgs -match "--info") { $ShowInfo = $true }
    if ($RemainingArgs -match "--json") { $Json = $true }

    # Path mapping: captures the value after --path if present.
    $pathIdx = [Array]::IndexOf($RemainingArgs, "--path")
    if ($pathIdx -ge 0 -and $pathIdx -lt ($RemainingArgs.Count - 1)) {
        $Path = $RemainingArgs[$pathIdx + 1]
    }
}

# --- UTILITY TIER ---

<#
.SYNOPSIS
    Standardized logging engine for both console and file output.

.DESCRIPTION
    Logs messages to stdout and optionally to a file path. Supports standard text
    output with colorization or structured ndjson logs suitable for CI/CD pipelines.

.PARAMETER Message
    The text message or log content to write.

.PARAMETER Color
    The console foreground color used when printing text logs. Defaults to White.

.PARAMETER Level
    The severity level of the log (INFO, LOG, WARN, ERR, SUCCESS). Defaults to INFO.
#>
function Write-LogMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,
        [ValidateSet("Green", "Cyan", "Yellow", "Red", "Gray", "White")]
        [string]$Color = "White",
        [ValidateSet("INFO", "LOG", "WARN", "ERR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if ($Json) {
        $logObj = [Ordered]@{
            timestamp = $timestamp
            level = $Level
            message = $Message
        }
        $jsonStr = $logObj | ConvertTo-Json -Compress
        Write-Output $jsonStr
        if ($LogPath) {
            try {
                $jsonStr | Out-File -FilePath $LogPath -Append -Encoding UTF8
            } catch {
                Write-Verbose "Failed to write log to file: $_"
            }
        }
    } else {
        $formattedMessage = "[$timestamp] [$Level] $Message"
        Write-Host $formattedMessage -ForegroundColor $Color
        if ($LogPath) {
            try {
                $parentDir = Split-Path -Path $LogPath -Parent
                if (-not (Test-Path -Path $parentDir)) {
                    $null = New-Item -ItemType Directory -Path $parentDir -Force
                }
                $formattedMessage | Out-File -FilePath $LogPath -Append -Encoding UTF8
            }
            catch {
                Write-Warning "Failed to write to log file: $_"
            }
        }
    }
}

<#
.SYNOPSIS
    Writes a script error (as JSON or stderr message) and exits.

.DESCRIPTION
    Standardized error reporter that terminates script execution. It formats the
    error message as a structured JSON object if in JSON mode, or outputs it to the
    error stream.

.PARAMETER Message
    The error description message to report.
#>
function Write-ScriptError {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    if ($Json) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $errObj = [Ordered]@{
            timestamp = $timestamp
            level = "ERR"
            message = $Message
        }
        $errObj | ConvertTo-Json -Compress | Write-Output
    } else {
        Write-Error $Message
    }
}

<#
.SYNOPSIS
    Checks if a directory is writeable by attempting to create a temporary file.

.DESCRIPTION
    Verifies write permissions on a target directory by generating a randomized
    temporary file, attempting to write it, and cleaning it up.

.PARAMETER DirPath
    The absolute directory path to test.

.OUTPUTS
    [bool] Returns True if the folder exists and is writeable, otherwise False.
#>
function Test-PathWriteable {
    param([string]$DirPath)
    if (-not (Test-Path -Path $DirPath)) { return $false }
    $testFile = Join-Path -Path $DirPath -ChildPath "winposix_test_$([Guid]::NewGuid().ToString().Substring(0,8)).tmp"
    try {
        $null = New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop
        Remove-Item -Path $testFile -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Queries the directory path to check for version and uname release date.

.DESCRIPTION
    Inspects a POSIX environment root (Cygwin or MSYS2). It parses the product
    version from its primary runtime DLL and invokes uname -v in an isolated shell
    to extract the release date.

.PARAMETER HomePath
    The root path of the target installation (e.g., C:\cygwin64).

.PARAMETER DllRelativePath
    The relative path to the core emulation DLL from the root.

.PARAMETER UnameRelativePath
    The relative path to uname.exe from the root.

.PARAMETER TargetName
    The name of the target environment ("Cygwin" or "MSYS") used for path isolation.

.OUTPUTS
    [hashtable] Returns a hashtable detailing if the environment is installed, its path, DLL version, and release date.
#>
function Get-EnvironmentDetail {
    param(
        [string]$HomePath,
        [string]$DllRelativePath,
        [string]$UnameRelativePath,
        [string]$TargetName
    )
    $details = @{ installed = $false; path = $null; version = $null; release = $null }
    $h = $HomePath
    $u = $UnameRelativePath
    if ($h -and (Test-Path $h)) {
        $dll = Join-Path $h $DllRelativePath
        if (Test-Path $dll) {
            $version = (Get-Item $dll).VersionInfo.ProductVersion
            $script:tempReleaseDate = $null
            Invoke-IsolatedAction -Target $TargetName -Action {
                $uname = Join-Path $h $u
                if (Test-Path $uname) {
                    $build = & $uname -v
                    if ($build -match "\d{4}-\d{2}-\d{2}") { $script:tempReleaseDate = $matches[0] }
                }
            }
            $details = @{
                installed = $true
                path = $h
                version = $version
                release = $script:tempReleaseDate
            }
        }
    }
    return $details
}

<#
.SYNOPSIS
    Asserts that no blocking processes are running under a specified directory.

.DESCRIPTION
    Inspects all active processes on the host. If any process executable resides
    under the target directory path, it accumulates their names and PIDs, outputs
    a clean error, and aborts execution with exit code 1.

.PARAMETER DirectoryPath
    The base directory to check for running processes.

.PARAMETER DisplayName
    A user-friendly label of the environment (e.g. "Cygwin") used in log messages.
#>
function Assert-NoRunningProcess {
    param(
        [string]$DirectoryPath,
        [string]$DisplayName
    )
    if ($DirectoryPath -and (Test-Path $DirectoryPath)) {
        $realPath = (Get-Item $DirectoryPath).FullName
        $runningProcesses = Get-Process | Where-Object {
            try {
                $_.Path -and $_.Path.StartsWith($realPath, [System.StringComparison]::OrdinalIgnoreCase)
            } catch {
                $false
            }
        }
        if ($runningProcesses) {
            $names = $runningProcesses | ForEach-Object { "$($_.Name) (PID: $($_.Id))" }
            Write-ScriptError -Message "Cannot proceed with update/install. Running $DisplayName processes detected under '$realPath': $($names -join ', '). Please close all processes and try again."
            exit 3
        }
    }
}

# PRIVILEGE CHECK:
# Most operations (installing to C:\, updating system binaries) require administrative rights.
# We bypass this check if the user is only requesting help or environment info.
$isHelpOrInfoRequest = $ShowHelp -or $ShowInfo -or (-not $UpdateAll -and -not $UpdateCygwin -and -not $UpdateMsys -and -not $InstallCygwin -and -not $InstallMsys)

if (-not $isHelpOrInfoRequest) {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-ScriptError -Message "Administrative privileges are required. Please run this script as Administrator."
        exit 2
    }
}

# --- UTILITY TIER ---

<#
.SYNOPSIS
    Persists home variables to the Machine-level environment if they are not already set.

.DESCRIPTION
    Updates CYGWIN_HOME and MSYS_HOME variables in the Machine (System) scope
    if they are currently unassigned or whitespace. This enables other tools
    to resolve these POSIX locations globally.

.PARAMETER CygwinPath
    The absolute path to the Cygwin installation root.

.PARAMETER MsysPath
    The absolute path to the MSYS2 installation root.
#>
function Set-GlobalHomeVariable {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$CygwinPath,
        [string]$MsysPath
    )
    if ($CygwinPath -and (Test-Path $CygwinPath)) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("CYGWIN_HOME", "Machine"))) {
            if ($PSCmdlet.ShouldProcess("Machine Environment", "Set CYGWIN_HOME to $CygwinPath")) {
                Write-LogMessage -Message "Populating Machine-level CYGWIN_HOME: $CygwinPath" -Color Gray -Level "INFO"
                [Environment]::SetEnvironmentVariable("CYGWIN_HOME", $CygwinPath, "Machine")
                $env:CYGWIN_HOME = $CygwinPath
            }
        }
    }
    if ($MsysPath -and (Test-Path $MsysPath)) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("MSYS_HOME", "Machine"))) {
            if ($PSCmdlet.ShouldProcess("Machine Environment", "Set MSYS_HOME to $MsysPath")) {
                Write-LogMessage -Message "Populating Machine-level MSYS_HOME: $MsysPath" -Color Gray -Level "INFO"
                [Environment]::SetEnvironmentVariable("MSYS_HOME", $MsysPath, "Machine")
                $env:MSYS_HOME = $MsysPath
            }
        }
    }
}

<#
.SYNOPSIS
    Inspects and displays details about Cygwin and MSYS2 installations.

.DESCRIPTION
    Queries the host environment for installed POSIX platforms, formats version and
    release details, maps system environment variables, and outputs them either as
    plain text or structured JSON.

.OUTPUTS
    Writes plain text or a JSON object detailing Cygwin and MSYS2 installations to stdout.
#>
function Show-EnvironmentInfo {
    $cygDetails = Get-EnvironmentDetail -HomePath $CYGWIN_HOME -DllRelativePath "bin\cygwin1.dll" -UnameRelativePath "bin\uname.exe" -TargetName "Cygwin"
    $msysDetails = Get-EnvironmentDetail -HomePath $MSYS_HOME -DllRelativePath "usr\bin\msys-2.0.dll" -UnameRelativePath "usr\bin\uname.exe" -TargetName "MSYS"

    if ($Json) {
        $envVarsObj = [Ordered]@{}
        $envVars = @("CYGWIN_HOME", "MSYS_HOME", "MSYS2_HOME")
        foreach ($var in $envVars) {
            $varTargets = @{}
            foreach ($target in @("Machine", "User", "Process")) {
                $val = [Environment]::GetEnvironmentVariable($var, $target)
                if ($val) {
                    $scopeLabel = if ($target -eq "Machine") { "System" } else { $target }
                    $varTargets[$scopeLabel] = $val
                }
            }
            if ($varTargets.Count -gt 0) {
                $envVarsObj[$var] = $varTargets
            }
        }

        $infoResult = [Ordered]@{
            cygwin = $cygDetails
            msys2 = $msysDetails
            environmentVariables = $envVarsObj
        }
        $infoResult | ConvertTo-Json -Depth 5 | Write-Output
        exit 0
    }

    Write-LogMessage -Message "--- WinPOSIX Environment Inspection ---" -Color Cyan -Level "INFO"
    Write-Output ""

    if ($cygDetails.installed) {
        Write-Output "Cygwin Installation:"
        Write-Output "  Path:    $($cygDetails.path)"
        Write-Output "  Version: $($cygDetails.version) $(if ($cygDetails.release) { '(Release: ' + $cygDetails.release + ')' })"
    } else {
        Write-Output "Cygwin: Not detected."
    }
    Write-Output ""

    if ($msysDetails.installed) {
        Write-Output "MSYS2 Installation:"
        Write-Output "  Path:    $($msysDetails.path)"
        Write-Output "  Version: $($msysDetails.version) $(if ($msysDetails.release) { '(Release: ' + $msysDetails.release + ')' })"
    } else {
        Write-Output "MSYS2: Not detected."
    }
    Write-Output ""

    Write-Output "Related Environment Variables:"
    $envVars = @("CYGWIN_HOME", "MSYS_HOME", "MSYS2_HOME")
    $anyFound = $false
    foreach ($var in $envVars) {
        foreach ($target in @("Machine", "User", "Process")) {
            $val = [Environment]::GetEnvironmentVariable($var, $target)
            if ($val) {
                $scopeLabel = if ($target -eq "Machine") { "System" } else { $target }
                Write-Output "  $($var.PadRight(12)) ($($scopeLabel.PadRight(7))): $val"
                $anyFound = $true
            }
        }
    }
    if (-not $anyFound) { Write-Output "  None detected." }
    Write-Output ""
    exit 0
}



# Explicitly reference parameter to satisfy linter requirement for used parameters.
$null = $CygwinMirror

# VALIDATION TIER:
# Ensure that mode-specific parameters are correctly paired and paths are writeable.
if ($Path -and -not $InstallCygwin -and -not $InstallMsys) {
    Write-ScriptError -Message "The --path parameter is restricted to installation mode (--install-cygwin or --install-msys)."
    exit 4
}

if ($Path) {
    # Check if we can write to the parent directory to create the target path.
    $targetDir = if (Test-Path $Path) { $Path } else { Split-Path $Path -Parent }
    if ($targetDir -and -not (Test-PathWriteable -DirPath $targetDir)) {
        Write-ScriptError -Message "Target installation path is not writeable: $targetDir. Please run as Administrator or check directory permissions."
        exit 4
    }
}

if ($LogPath) {
    $logDir = Split-Path $LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { Write-Verbose "Failed to create log directory: $_" }
    }
    if ($logDir -and -not (Test-PathWriteable -DirPath $logDir)) {
        Write-Warning "Log directory '$logDir' is not writeable. Logging to file will be disabled."
        $LogPath = $null
    }
}

# CONFIGURATION:
# Resolves home directories via environment variables with hardcoded fallbacks for standard installations.
$cygwinPaths = @(
    if ($env:CYGWIN_HOME) { ($env:CYGWIN_HOME -split ';')[0] }
    "C:\admin\cygwin"
    "C:\cygwin64"
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$CYGWIN_HOME = ($cygwinPaths | Where-Object { Test-Path $_ } | Select-Object -First 1)
if (-not $CYGWIN_HOME) { $CYGWIN_HOME = "C:\cygwin64" }

$msysPaths = @(
    if ($env:MSYS_HOME) { ($env:MSYS_HOME -split ';')[0] }
    if ($env:MSYS2_HOME) { ($env:MSYS2_HOME -split ';')[0] }
    "C:\admin\msys2"
    "C:\msys64"
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$MSYS_HOME = ($msysPaths | Where-Object { Test-Path $_ } | Select-Object -First 1)
if (-not $MSYS_HOME) { $MSYS_HOME = "C:\msys64" }

# Sync identified paths to machine-level environment variables if missing (skipped for help or info requests to avoid permission issues).
if (-not $isHelpOrInfoRequest) {
    Set-GlobalHomeVariable -CygwinPath $CYGWIN_HOME -MsysPath $MSYS_HOME
}

# RUNNING PROCESS CHECK:
# Verify that no blocking processes are running in Cygwin or MSYS2 environments before executing updates or installations.
$isActionRequest = $UpdateAll -or $UpdateCygwin -or $UpdateMsys -or $InstallCygwin -or $InstallMsys
if ($isActionRequest) {
    Assert-NoRunningProcess -DirectoryPath $CYGWIN_HOME -DisplayName "Cygwin"
    Assert-NoRunningProcess -DirectoryPath $MSYS_HOME -DisplayName "MSYS2"
    Assert-NoRunningProcess -DirectoryPath $Path -DisplayName "target path"
}

# --- ISOLATION TIER ---

<#
.SYNOPSIS
    Generates a filtered PATH to prevent binary collisions during updates.

.DESCRIPTION
    Constructs a sanitized PATH string. When targeting Cygwin, MSYS2 and Git-Bash
    paths are filtered out. When targeting MSYS2, Cygwin paths are filtered out.
    This eliminates DLL and command collisions (e.g. conflicting versions of grep or ls).

.PARAMETER Target
    The environment to isolate ("Cygwin" or "MSYS").

.OUTPUTS
    [string] The isolated and filtered PATH string.
#>
function Get-IsolatedPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Cygwin", "MSYS")]
        [string]$Target
    )

    $currentPath = $env:PATH -split ';' | Where-Object { [string]::IsNullOrWhiteSpace($_) -eq $false }
    $filteredPath = @()

    if ($Target -eq "Cygwin") {
        # OBJECTIVE: Remove MSYS2/Git-Bash paths to ensure Cygwin tools are used.
        Write-Verbose "Isolating Cygwin environment (removing MSYS2/Git-Bash paths)..."
        $filteredPath = $currentPath | Where-Object { $_ -notmatch "msys2|git-bash" }
        $cygBin = Join-Path -Path $CYGWIN_HOME -ChildPath "bin"
        if ($filteredPath -notcontains $cygBin) {
            $filteredPath = , $cygBin + $filteredPath
        }
    }
    else {
        # OBJECTIVE: Remove Cygwin paths to ensure MSYS2/pacman use the correct runtime.
        Write-Verbose "Isolating MSYS2 environment (removing Cygwin paths)..."
        $filteredPath = $currentPath | Where-Object { $_ -notmatch "cygwin" }
        $msysBins = @(
            (Join-Path -Path $MSYS_HOME -ChildPath "usr\bin"),
            (Join-Path -Path $MSYS_HOME -ChildPath "bin")
        )
        foreach ($bin in $msysBins) {
            if ($filteredPath -notcontains $bin) {
                $filteredPath = , $bin + $filteredPath
            }
        }
    }

    return $filteredPath -join ';'
}

<#
.SYNOPSIS
    Context manager for isolated operations.

.DESCRIPTION
    Executes a ScriptBlock inside a transient, isolated PATH scope. It backs up
    the active PATH, applies the filtered PATH, runs the actions, and guarantees
    the restoration of the original PATH in a finally block.

.PARAMETER Target
    The environment to target ("Cygwin" or "MSYS").

.PARAMETER Action
    The ScriptBlock containing operations to execute inside the isolated scope.
#>
function Invoke-IsolatedAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $oldPath = $env:PATH
    try {
        # Step 1: Apply the target-specific isolated PATH.
        Write-Verbose "Setting isolated PATH for $Target..."
        $env:PATH = Get-IsolatedPath -Target $Target
        Write-Verbose "Active PATH: $env:PATH"

        # Step 2: Execute the update logic.
        &$Action
    }
    catch {
        Write-LogMessage -Message "Error during isolated action for ${Target}: $_" -Color Red -Level "ERR"
        if ($script:exitCode -eq 0) { $script:exitCode = 8 }
    }
    finally {
        # Step 3: Guaranteed restoration of the original system PATH.
        $env:PATH = $oldPath
        Write-Verbose "PATH restored to original state."
    }
}

# --- UPDATE ENGINES ---

<#
.SYNOPSIS
    Updates Cygwin in a completely headless console mode.

.DESCRIPTION
    Performs unattended package updates for Cygwin. It bootstraps the latest
    setup-x86_64.exe installer from cygwin.com if out-of-date, and executes it with
    quiet mode flags inside a hidden window to prevent GUI popups.

.PARAMETER Mirror
    The site URL mirror used for package downloads.

.PARAMETER OverrideRoot
    Optional directory path to overwrite the default Cygwin installation root.
#>
function Update-Cygwin {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mirror,
        [Parameter(Mandatory = $false)]
        [string]$OverrideRoot
    )
    # LINTER SYNC: Assign parameters to local variables to satisfy PSScriptAnalyzer scope checks.
    $m = $Mirror
    $o = $OverrideRoot
    Invoke-IsolatedAction -Target "Cygwin" -Action {
        $rootPath = if ($o) { $o } else { $CYGWIN_HOME }
        Write-LogMessage -Message "Updating Cygwin at $rootPath" -Color Green -Level "INFO"

        # Locate the setup utility locally or in the system path.
        $setupExe = Join-Path -Path $rootPath -ChildPath "setup-x86_64.exe"
        if (-not (Test-Path -Path $setupExe)) {
            $setupExe = Get-Command -Name "setup-x86_64.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        }

        if (-not $setupExe) {
            $setupExe = Join-Path -Path $rootPath -ChildPath "setup-x86_64.exe"
        }

        # BOOTSTRAPPER / SELF-UPDATE:
        # Ensures the setup utility is the latest version before proceeding.
        $setupUrl = "https://cygwin.com/setup-x86_64.exe"
        $needsUpdate = $true

        # Pre-flight: Ensure the directory for the setup utility exists.
        $setupDir = Split-Path $setupExe -Parent
        if ($setupDir -and -not (Test-Path $setupDir)) {
            try { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null } catch { Write-Verbose "Failed to create setup directory: $_" }
        }

        if (Test-Path -Path $setupExe) {
            try {
                $lastModified = (Invoke-WebRequest -Uri $setupUrl -Method Head -UseBasicParsing -ErrorAction SilentlyContinue).Headers."Last-Modified"
                if ($lastModified) {
                    $remoteTime = [DateTime]::Parse($lastModified)
                    $localTime = (Get-Item $setupExe).LastWriteTime
                    if ($localTime -ge $remoteTime) {
                        $needsUpdate = $false
                        Write-LogMessage -Message "Cygwin setup is already up to date (Local: $localTime, Remote: $remoteTime). Skipping download." -Color Gray -Level "INFO"
                    }
                }
            }
            catch {
                # Fallback to update if check fails, but don't block.
                Write-Verbose "Could not verify remote setup version: $_"
            }
        }

        if ($needsUpdate) {
            try {
                if ($PSCmdlet.ShouldProcess($setupUrl, "Download latest setup-x86_64.exe")) {
                    Write-LogMessage -Message "Bootstrapping latest Cygwin setup from $setupUrl..." -Color Cyan -Level "INFO"
                    Invoke-WebRequest -Uri $setupUrl -OutFile $setupExe -UseBasicParsing -ErrorAction Stop
                }
            }
            catch {
                Write-LogMessage -Message "Manual bootstrap failed: $_. Proceeding with existing utility if available." -Color Yellow -Level "WARN"
            }
        }

        if (-not (Test-Path -Path $setupExe)) {
            Write-LogMessage -Message "Cygwin setup-x86_64.exe not found and bootstrap failed." -Color Red -Level "ERR"
            if ($script:exitCode -eq 0) { $script:exitCode = 6 }
            return
        }

        if ($PSCmdlet.ShouldProcess($rootPath, "Update packages via setup-x86_64.exe (Headless)")) {
            Write-LogMessage -Message "Executing Cygwin setup (Mirror: $Mirror)..." -Color Yellow -Level "LOG"

            # Headless Configuration:
            # --quiet-mode: Unattended setup
            # --no-version-check is OMITTED to allow the utility to self-update if a new version is released.
            # --no-replaceonreboot: Suppress reboot warnings during background execution.
            $setupArgs = @(
                "--quiet-mode",
                "--upgrade-also",
                "--no-desktop",
                "--no-shortcuts",
                "--no-startmenu",
                "--no-replaceonreboot",
                "--root", $rootPath,
                "--site", $m,
                "--local-package-dir", (Join-Path -Path $rootPath -ChildPath "packages")
            )

            $stdoutPath = Join-Path -Path $env:TEMP -ChildPath "cygwin_setup_out_$([Guid]::NewGuid().ToString().Substring(0,8)).log"
            $stderrPath = Join-Path -Path $env:TEMP -ChildPath "cygwin_setup_err_$([Guid]::NewGuid().ToString().Substring(0,8)).log"

            try {
                # WindowStyle Hidden ensures a text-only experience by suppressing the setup GUI.
                $process = Start-Process -FilePath $setupExe -ArgumentList $setupArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

                # Stream captured stdout logs through logging engine to preserve format
                if (Test-Path $stdoutPath) {
                    Get-Content -Path $stdoutPath -ErrorAction SilentlyContinue | ForEach-Object {
                        $line = $_
                        if ($null -ne $line -and -not [string]::IsNullOrWhiteSpace($line)) {
                            if ($Json) {
                                Write-LogMessage -Message $line -Level "LOG" -Color Gray
                            } else {
                                Write-Output $line
                            }
                        }
                    }
                }

                # Stream captured stderr logs through logging engine to preserve format
                if (Test-Path $stderrPath) {
                    Get-Content -Path $stderrPath -ErrorAction SilentlyContinue | ForEach-Object {
                        $line = $_
                        if ($null -ne $line -and -not [string]::IsNullOrWhiteSpace($line)) {
                            if ($Json) {
                                Write-LogMessage -Message $line -Level "WARN" -Color Yellow
                            } else {
                                Write-Output $line
                            }
                        }
                    }
                }

                if ($process.ExitCode -eq 0) {
                    Write-LogMessage -Message "Cygwin update completed successfully." -Color Green -Level "SUCCESS"
                } else {
                    Write-LogMessage -Message "Cygwin setup exited with code $($process.ExitCode)" -Color Red -Level "ERR"
                    if ($script:exitCode -eq 0) { $script:exitCode = 6 }
                }
            }
            finally {
                # Guaranteed cleanup of temporary files
                if (Test-Path $stdoutPath) { Remove-Item -Path $stdoutPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path $stderrPath) { Remove-Item -Path $stderrPath -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

<#
.SYNOPSIS
    Performs a fresh installation of Cygwin.

.DESCRIPTION
    Provisions a new Cygwin environment at the specified directory. It creates
    the folder structure, triggers Update-Cygwin to perform the base installation,
    and registers the home variable.

.PARAMETER InstallPath
    The absolute path where Cygwin should be installed.

.PARAMETER Mirror
    The mirror URL used for packages downloads.
#>
function Install-Cygwin {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallPath,
        [Parameter(Mandatory = $true)]
        [string]$Mirror
    )
    Write-LogMessage -Message "Installing Cygwin to $InstallPath..." -Color Cyan -Level "INFO"

    # Ensure the directory exists.
    if (-not (Test-Path -Path $InstallPath)) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    }

    # Use the existing update engine but with an explicit root.
    # The setup utility will perform a base install if the root is empty.
    Update-Cygwin -Mirror $Mirror -OverrideRoot $InstallPath

    # Persist the new home path to global environment.
    Set-GlobalHomeVariable -CygwinPath $InstallPath
}

<#
.SYNOPSIS
    Performs a fresh installation of MSYS2 using the base self-extracting archive.

.DESCRIPTION
    Provisions a fresh MSYS2 environment. It queries the GitHub API to dynamically
    resolve and download the latest base SFX archive, extracts it, initializes the
    pacman package database, and persists the home variables.

.PARAMETER InstallPath
    The absolute path where MSYS2 should be installed.
#>
function Install-MSYS {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallPath
    )
    # LINTER SYNC: Assign parameters to local variables to satisfy PSScriptAnalyzer scope checks.
    $p = $InstallPath
    Invoke-IsolatedAction -Target "MSYS" -Action {
        Write-LogMessage -Message "Installing MSYS2 to $p..." -Color Cyan -Level "INFO"

        # Ensure the directory exists.
        if (-not (Test-Path -Path $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }

        $sfxPath = Join-Path -Path $env:TEMP -ChildPath "msys2-base.sfx.exe"

        try {
            # Discovery: Find the latest SFX release from GitHub.
            Write-LogMessage -Message "Querying GitHub for latest MSYS2 base release..." -Color Gray -Level "INFO"
            $apiUri = "https://api.github.com/repos/msys2/msys2-installer/releases/latest"
            $release = Invoke-RestMethod -Uri $apiUri
            $asset = $release.assets | Where-Object { $_.name -like "msys2-base-x86_64-*.sfx.exe" } | Select-Object -First 1
            if (-not $asset) { throw "Could not find SFX asset in latest release." }

            $downloadUrl = $asset.browser_download_url
            Write-LogMessage -Message "Downloading MSYS2 SFX from $downloadUrl..." -Color Cyan -Level "INFO"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $sfxPath -UseBasicParsing -ErrorAction Stop

            if ($PSCmdlet.ShouldProcess($p, "Extract MSYS2 base system")) {
                Write-LogMessage -Message "Extracting MSYS2 (this may take a minute)..." -Color Yellow -Level "LOG"
                # -y: Assume yes to all questions
                # -o: Output directory (Note: no space after -o)
                $process = Start-Process -FilePath $sfxPath -ArgumentList "-y", "-o$p" -Wait -PassThru -WindowStyle Hidden

                if ($process.ExitCode -eq 0) {
                    Write-LogMessage -Message "MSYS2 extraction complete." -Color Green -Level "SUCCESS"
                    # Initialize the environment by running a dummy command.
                    $bash = Join-Path -Path $p -ChildPath "usr\bin\bash.exe"
                    if (Test-Path $bash) {
                        Write-LogMessage -Message "Initializing MSYS2 environment..." -Color Gray -Level "INFO"
                        Start-Process -FilePath $bash -ArgumentList "--login", "-c", "exit" -Wait -WindowStyle Hidden
                    }

                    # Persist the new home path to global environment.
                    Set-GlobalHomeVariable -MsysPath $p
                } else {
                    Write-LogMessage -Message "MSYS2 extraction failed with code $($process.ExitCode)" -Color Red -Level "ERR"
                    if ($script:exitCode -eq 0) { $script:exitCode = 7 }
                }
            }
        }
        catch {
            Write-LogMessage -Message "Failed to download/install MSYS2: $_" -Color Red -Level "ERR"
            if ($script:exitCode -eq 0) { $script:exitCode = 7 }
        }
        finally {
            # Cleanup.
            if (Test-Path $sfxPath) { Remove-Item -Path $sfxPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

<#
.SYNOPSIS
    Updates MSYS2 with intelligent early-exit detection.

.DESCRIPTION
    Performs package updates for MSYS2 using pacman. It executes up to 3 passes to
    ensure pacman and runtime database stability, and uses real-time stream output
    analysis to detect "there is nothing to do" to skip redundant update passes.
#>
function Update-MSYS {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Invoke-IsolatedAction -Target "MSYS" -Action {
        Write-LogMessage -Message "Updating MSYS2 at $MSYS_HOME" -Color Green -Level "INFO"
        $pacman = Join-Path -Path $MSYS_HOME -ChildPath "usr\bin\pacman.exe"
        if (-not (Test-Path -Path $pacman)) {
            Write-LogMessage -Message "MSYS2 pacman.exe not found at $pacman." -Color Red -Level "ERR"
            if ($script:exitCode -eq 0) { $script:exitCode = 7 }
            return
        }

        if ($PSCmdlet.ShouldProcess($MSYS_HOME, "Update packages via pacman -Syu")) {
            # pacman often requires multiple passes if the runtime or pacman itself is updated.
            $maxAttempts = 3
            for ($i = 1; $i -le $maxAttempts; $i++) {
                Write-LogMessage -Message "Running pacman -Syu (Attempt $i/$maxAttempts)..." -Color Yellow -Level "LOG"

                # FUNCTIONALITY: Real-time streaming and output capture for "there is nothing to do" detection.
                $output = ""
                & $pacman -Syu --noconfirm *>&1 | ForEach-Object {
                    $line = $_
                    if ($null -ne $line -and -not [string]::IsNullOrWhiteSpace($line)) {
                        if ($Json) {
                            Write-LogMessage -Message $line -Level "LOG" -Color Gray
                        } else {
                            Write-Output $line # Stream to console for visibility
                        }
                    }
                    $output += $line # Pass to capture for analysis
                }

                if ($LASTEXITCODE -ne 0) {
                    Write-LogMessage -Message "MSYS2 pacman update failed with exit code $LASTEXITCODE." -Color Red -Level "ERR"
                    if ($script:exitCode -eq 0) { $script:exitCode = 7 }
                    break
                }

                if ($output -match "there is nothing to do") {
                    Write-LogMessage -Message "MSYS2 is already up to date. Skipping redundant cycles." -Color Green -Level "SUCCESS"
                    break
                }
                Write-LogMessage -Message "Pass $i complete. Waiting for runtime stability..." -Color Gray -Level "INFO"
                Start-Sleep -Seconds 2
            }
            Write-LogMessage -Message "MSYS2 update process finished." -Color Green -Level "SUCCESS"
        }
    }
}

# --- ORCHESTRATION TIER ---

# HELP OUTPUT: Provides standardized usage guidance.
if ($ShowHelp -or (-not $UpdateAll -and -not $UpdateCygwin -and -not $UpdateMsys -and -not $InstallCygwin -and -not $InstallMsys -and -not $ShowInfo)) {
    if ($Json) {
        $helpObj = [Ordered]@{
            utility = "WinPOSIX Auto-Updater/Installer"
            usage = ".\winposix_update.ps1 [flags]"
            flags = @(
                @{ flag = "--update-all"; description = "Update both Cygwin and MSYS2" }
                @{ flag = "--update-cygwin"; description = "Update only Cygwin" }
                @{ flag = "--update-msys"; description = "Update only MSYS2" }
                @{ flag = "--install-cygwin"; description = "Install fresh Cygwin (Error if already present)" }
                @{ flag = "--install-msys"; description = "Install fresh MSYS2 (Error if already present)" }
                @{ flag = "--path <dir>"; description = "Explicit target directory for installation" }
                @{ flag = "--info"; description = "Inspect existing installations and environment" }
                @{ flag = "--LogPath"; description = "Path to a log file" }
                @{ flag = "--CygwinMirror"; description = "URL for Cygwin mirror" }
                @{ flag = "--help"; description = "Show this help message" }
                @{ flag = "--json"; description = "Format output in ndjson for CI/CD" }
            )
        }
        $helpObj | ConvertTo-Json | Write-Output
        exit 0
    }

    Write-LogMessage -Message "WinPOSIX Auto-Updater/Installer Help Output" -Color Cyan
    Write-Output "Usage: .\winposix_update.ps1 [flags]"
    Write-Output ""
    Write-Output "Maintenance Flags:"
    Write-Output "  --update-all      Update both Cygwin and MSYS2"
    Write-Output "  --update-cygwin   Update only Cygwin"
    Write-Output "  --update-msys     Update only MSYS2"
    Write-Output ""
    Write-Output "Installation Flags:"
    Write-Output "  --install-cygwin  Install fresh Cygwin (Error if already present)"
    Write-Output "  --install-msys    Install fresh MSYS2 (Error if already present)"
    Write-Output "  --path <dir>      Explicit target directory for installation"
    Write-Output ""
    Write-Output "General Flags:"
    Write-Output "  --info            Inspect existing installations and environment"
    Write-Output "  --LogPath         Path to a log file (e.g., C:\logs\update.log)"
    Write-Output "  --CygwinMirror    URL for Cygwin mirror"
    Write-Output "  --help            Show this help message"
    Write-Output "  --json            Format output in ndjson for CI/CD"
    Write-Output ""
    Write-Output "Environment Variables:"
    Write-Output "  CYGWIN_HOME       (Default: C:\cygwin64)"
    Write-Output "  MSYS_HOME         (Default: C:\msys64)"
    exit 0
}

$script:exitCode = 0

if ($LogPath) {
    Write-LogMessage -Message "--- WinPOSIX Update/Install Session Started ---" -Color Gray -Level "INFO"
}

if ($ShowInfo) {
    Show-EnvironmentInfo
}

# INSTALLATION TIER:
# Handles fresh installations with guardrails against overwriting existing environments.
if ($InstallCygwin) {
    $targetPath = if ($Path) { $Path } else { $CYGWIN_HOME }
    if (Test-Path (Join-Path $targetPath "bin\cygwin1.dll")) {
        Write-ScriptError -Message "Cygwin is already detected at $targetPath. To update, please use --update-cygwin or --update-all."
        exit 5
    }
    Install-Cygwin -InstallPath $targetPath -Mirror $CygwinMirror
}

if ($InstallMsys) {
    $targetPath = if ($Path) { $Path } else { $MSYS_HOME }
    if (Test-Path (Join-Path $targetPath "usr\bin\msys-2.0.dll")) {
        Write-ScriptError -Message "MSYS2 is already detected at $targetPath. To update, please use --update-msys or --update-all."
        exit 5
    }
    Install-MSYS -InstallPath $targetPath
}

# UPDATE TIER:
# Triggers isolated actions based on the mapped switches.
if ($UpdateAll -or $UpdateCygwin) {
    Update-Cygwin -Mirror $CygwinMirror
}

if ($UpdateAll -or $UpdateMsys) {
    Update-MSYS
}

if ($script:exitCode -ne 0) {
    Write-ScriptError -Message "One or more requested tasks failed."
    exit $script:exitCode
} else {
    Write-LogMessage -Message "All requested tasks completed." -Color Green -Level "SUCCESS"
    exit 0
}
