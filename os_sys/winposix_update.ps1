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
    [Alias("help")]
    [switch]$ShowHelp,

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

# --- INITIALIZATION TIER ---

# MANUAL ARGUMENT MAPPING:
# This fail-safe block ensures that flags like --update-all are correctly captured
# even if the shell or calling environment has non-standard parameter binding.
if ($null -ne $RemainingArgs -and $RemainingArgs.Count -gt 0) {
    if ($RemainingArgs -match "--update-all") { $UpdateAll = $true }
    if ($RemainingArgs -match "--update-cygwin") { $UpdateCygwin = $true }
    if ($RemainingArgs -match "--update-msys") { $UpdateMsys = $true }
}

# Explicitly reference parameter to satisfy linter requirement for used parameters.
$null = $CygwinMirror

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
        Write-LogMessage -Message "Setting isolated PATH for $Target..." -Color Cyan -Level "INFO"
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
        Write-LogMessage -Message "PATH restored to original state." -Color Gray -Level "INFO"
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
        [string]$Mirror
    )
    $null = $Mirror
    Write-LogMessage -Message "Updating Cygwin at $CYGWIN_HOME" -Color Green -Level "INFO"

    # Locate the setup utility locally or in the system path.
    $setupExe = Join-Path -Path $CYGWIN_HOME -ChildPath "setup-x86_64.exe"
    if (-not (Test-Path -Path $setupExe)) {
        $setupExe = Get-Command -Name "setup-x86_64.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    }

    if (-not $setupExe) {
        Write-LogMessage -Message "Cygwin setup-x86_64.exe not found." -Color Yellow -Level "WARN"
        return
    }

    if ($PSCmdlet.ShouldProcess($CYGWIN_HOME, "Update packages via setup-x86_64.exe (Headless)")) {
        Write-LogMessage -Message "Executing Cygwin setup (Mirror: $Mirror)..." -Color Yellow -Level "LOG"

        # Headless Configuration:
        # --quiet-mode: Unattended setup
        # --no-desktop/--no-shortcuts/--no-startmenu: Prevent UI shell interactions
        $setupArgs = @(
            "--quiet-mode",
            "--upgrade-also",
            "--no-desktop",
            "--no-shortcuts",
            "--no-startmenu",
            "--root", $CYGWIN_HOME,
            "--site", $Mirror,
            "--local-package-dir", (Join-Path -Path $CYGWIN_HOME -ChildPath "packages")
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

<#
.SYNOPSIS
    Updates MSYS2 with intelligent early-exit detection.
#>
function Update-MSYS {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
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
            $output = & $pacman -Syu --noconfirm *>&1 | ForEach-Object {
                Write-Output $_ # Stream to console for visibility
                $_ # Pass to capture for analysis
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

# --- ORCHESTRATION TIER ---

# HELP OUTPUT: Provides standardized usage guidance.
if ($ShowHelp -or (-not $UpdateAll -and -not $UpdateCygwin -and -not $UpdateMsys)) {
    Write-LogMessage -Message "WinPOSIX Auto-Updater Help Output" -Color Cyan
    Write-Output "Usage: .\winposix_update.ps1 [flags]"
    Write-Output ""
    Write-Output "Flags:"
    Write-Output "  --update-all      Update both Cygwin and MSYS2"
    Write-Output "  --update-cygwin   Update only Cygwin"
    Write-Output "  --update-msys     Update only MSYS2"
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
    Write-LogMessage -Message "--- WinPOSIX Update Session Started ---" -Color Gray -Level "INFO"
}

# Execution: Triggers isolated actions based on the mapped switches.
if ($UpdateAll -or $UpdateCygwin) {
    Invoke-IsolatedAction -Target "Cygwin" -Action { Update-Cygwin -Mirror $CygwinMirror }
}

if ($UpdateAll -or $UpdateMsys) {
    Invoke-IsolatedAction -Target "MSYS" -Action { Update-MSYS }
}

Write-LogMessage -Message "All requested tasks completed." -Color Green -Level "SUCCESS"
