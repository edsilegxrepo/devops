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

.EXAMPLE
    .\winposix_update.ps1 --update-all --LogPath "C:\logs\winposix.log"
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

# --- UTILITY TIER ---

<#
.SYNOPSIS
    Checks if a directory is writeable by attempting to create a temporary file.
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

# PRIVILEGE CHECK:
# Most operations (installing to C:\, updating system binaries) require administrative rights.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Administrative privileges are required. Please run this script as Administrator."
    exit 1
}

# --- UTILITY TIER ---

<#
.SYNOPSIS
    Persists home variables to the Machine-level environment if they are not already set.
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
#>
function Show-EnvironmentInfo {
    Write-LogMessage -Message "--- WinPOSIX Environment Inspection ---" -Color Cyan -Level "INFO"
    Write-Output ""

    # 1. Inspect Cygwin
    $cygInstalled = $false
    if ($CYGWIN_HOME -and (Test-Path $CYGWIN_HOME)) {
        $cygDll = Join-Path $CYGWIN_HOME "bin\cygwin1.dll"
        if (Test-Path $cygDll) {
            $cygVersion = (Get-Item $cygDll).VersionInfo.ProductVersion
            $cygDate = $null
            Invoke-IsolatedAction -Target "Cygwin" -Action {
                $cygExe = Join-Path $CYGWIN_HOME "bin\uname.exe"
                if (Test-Path $cygExe) {
                    $cygBuild = & $cygExe -v
                    if ($cygBuild -match "\d{4}-\d{2}-\d{2}") { $script:cygDate = $matches[0] }
                }
            }

            Write-Output "Cygwin Installation:"
            Write-Output "  Path:    $CYGWIN_HOME"
            Write-Output "  Version: $cygVersion $(if ($cygDate) { '(Release: ' + $cygDate + ')' })"
            $cygInstalled = $true
        }
    }
    if (-not $cygInstalled) { Write-Output "Cygwin: Not detected." }
    Write-Output ""

    # 2. Inspect MSYS2
    $msysInstalled = $false
    if ($MSYS_HOME -and (Test-Path $MSYS_HOME)) {
        $msysDll = Join-Path $MSYS_HOME "usr\bin\msys-2.0.dll"
        if (Test-Path $msysDll) {
            $msysVersion = (Get-Item $msysDll).VersionInfo.ProductVersion
            $msysDate = $null
            Invoke-IsolatedAction -Target "MSYS" -Action {
                $msysExe = Join-Path $MSYS_HOME "usr\bin\uname.exe"
                if (Test-Path $msysExe) {
                    $msysBuild = & $msysExe -v
                    if ($msysBuild -match "\d{4}-\d{2}-\d{2}") { $script:msysDate = $matches[0] }
                }
            }

            Write-Output "MSYS2 Installation:"
            Write-Output "  Path:    $MSYS_HOME"
            Write-Output "  Version: $msysVersion $(if ($msysDate) { '(Release: ' + $msysDate + ')' })"
            $msysInstalled = $true
        }
    }
    if (-not $msysInstalled) { Write-Output "MSYS2: Not detected." }
    Write-Output ""

    # 3. Inspect Environment Variables
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

    # Path mapping: captures the value after --path if present.
    $pathIdx = [Array]::IndexOf($RemainingArgs, "--path")
    if ($pathIdx -ge 0 -and $pathIdx -lt ($RemainingArgs.Count - 1)) {
        $Path = $RemainingArgs[$pathIdx + 1]
    }
}

# Explicitly reference parameter to satisfy linter requirement for used parameters.
$null = $CygwinMirror

# VALIDATION TIER:
# Ensure that mode-specific parameters are correctly paired and paths are writeable.
if ($Path -and -not $InstallCygwin -and -not $InstallMsys) {
    Write-Error "The --path parameter is restricted to installation mode (--install-cygwin or --install-msys)."
    exit 1
}

if ($Path) {
    # Check if we can write to the parent directory to create the target path.
    $targetDir = if (Test-Path $Path) { $Path } else { Split-Path $Path -Parent }
    if ($targetDir -and -not (Test-PathWriteable -DirPath $targetDir)) {
        Write-Error "Target installation path is not writeable: $targetDir. Please run as Administrator or check directory permissions."
        exit 1
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

# Sync identified paths to machine-level environment variables if missing.
Set-GlobalHomeVariable -CygwinPath $CYGWIN_HOME -MsysPath $MSYS_HOME

# --- UTILITY TIER ---

<#
.SYNOPSIS
    Standardized logging engine for both console and file output.
#>
function Write-LogMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("Green", "Cyan", "Yellow", "Red", "Gray", "White")]
        [string]$Color = "White",
        [ValidateSet("INFO", "LOG", "WARN", "ERR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formattedMessage = "[$timestamp] [$Level] $Message"

    Write-Host $formattedMessage -ForegroundColor $Color
    if ($LogPath) {
        try {
            $parentDir = Split-Path -Path $LogPath -Parent
            if ($parentDir -and -not (Test-Path -Path $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
            }
            $formattedMessage | Out-File -FilePath $LogPath -Append -Encoding UTF8
        }
        catch {
            Write-Warning "Failed to write to log file: $_"
        }
    }
}

# --- ISOLATION TIER ---

<#
.SYNOPSIS
    Generates a filtered PATH to prevent binary collisions during updates.
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

            # WindowStyle Hidden ensures a text-only experience by suppressing the setup GUI.
            $process = Start-Process -FilePath $setupExe -ArgumentList $setupArgs -Wait -PassThru -WindowStyle Hidden

            if ($process.ExitCode -eq 0) {
                Write-LogMessage -Message "Cygwin update completed successfully." -Color Green -Level "SUCCESS"
            } else {
                Write-LogMessage -Message "Cygwin setup exited with code $($process.ExitCode)" -Color Red -Level "ERR"
            }
        }
    }
}

<#
.SYNOPSIS
    Performs a fresh installation of Cygwin.
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

        # Discovery: Find the latest SFX release from GitHub.
        try {
            Write-LogMessage -Message "Querying GitHub for latest MSYS2 base release..." -Color Gray -Level "INFO"
            $apiUri = "https://api.github.com/repos/msys2/msys2-installer/releases/latest"
            $release = Invoke-RestMethod -Uri $apiUri
            $asset = $release.assets | Where-Object { $_.name -like "msys2-base-x86_64-*.sfx.exe" } | Select-Object -First 1
            if (-not $asset) { throw "Could not find SFX asset in latest release." }

            $downloadUrl = $asset.browser_download_url
            Write-LogMessage -Message "Downloading MSYS2 SFX from $downloadUrl..." -Color Cyan -Level "INFO"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $sfxPath -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Write-LogMessage -Message "Failed to download MSYS2 installer: $_" -Color Red -Level "ERR"
            return
        }

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
            }
        }

        # Cleanup.
        if (Test-Path $sfxPath) { Remove-Item -Path $sfxPath -Force }
    }
}

<#
.SYNOPSIS
    Updates MSYS2 with intelligent early-exit detection.
#>
function Update-MSYS {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Invoke-IsolatedAction -Target "MSYS" -Action {
        Write-LogMessage -Message "Updating MSYS2 at $MSYS_HOME" -Color Green -Level "INFO"
        $pacman = Join-Path -Path $MSYS_HOME -ChildPath "usr\bin\pacman.exe"
        if (-not (Test-Path -Path $pacman)) {
            Write-LogMessage -Message "MSYS2 pacman.exe not found at $pacman." -Color Red -Level "ERR"
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
                    Write-Output $_ # Stream to console for visibility
                    $output += $_ # Pass to capture for analysis
                }

                if ($LASTEXITCODE -ne 0) {
                    Write-LogMessage -Message "MSYS2 pacman update failed with exit code $LASTEXITCODE." -Color Red -Level "ERR"
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
    Write-Output ""
    Write-Output "Environment Variables:"
    Write-Output "  CYGWIN_HOME       (Default: C:\cygwin64)"
    Write-Output "  MSYS_HOME         (Default: C:\msys64)"
    exit 0
}

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
        Write-Error "Cygwin is already detected at $targetPath. To update, please use --update-cygwin or --update-all."
        exit 1
    }
    Install-Cygwin -InstallPath $targetPath -Mirror $CygwinMirror
}

if ($InstallMsys) {
    $targetPath = if ($Path) { $Path } else { $MSYS_HOME }
    if (Test-Path (Join-Path $targetPath "usr\bin\msys-2.0.dll")) {
        Write-Error "MSYS2 is already detected at $targetPath. To update, please use --update-msys or --update-all."
        exit 1
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

Write-LogMessage -Message "All requested tasks completed." -Color Green -Level "SUCCESS"
