#!/bin/bash
# ======================================================================
# OCI Extraction Script (v0.0.1xg - 2025/11/20)
#
# A comprehensive script to download OCI (Open Container Initiative)
# compliant container images, extract their filesystems, and perform
# various analysis tasks.
#
# Core Features:
#   - Downloads images using 'skopeo'.
#   - Extracts the root filesystem by correctly ordering and applying layers.
#   - Inspects image metadata (e.g., CMD, Entrypoint, Exposed Ports).
#   - Verifies the integrity of image layers using SHA256 checksums.
#   - Performs high-speed, parallel searches for files within the
#     extracted filesystem.
#
# Dependencies:
#   - Core: tar, jq, find
#   - Download Mode: skopeo
#   - Verification: sha256sum
# ======================================================================

# --- Script Configuration ---

# Strict error handling:
#   -e: Exit immediately if a command exits with a non-zero status.
#   -u: Treat unset variables as an error when substituting.
set -eu

# --- Global Variable Declarations ---

# Script Behavior Flags
PURGE_LAYERS=0          # If 1, deletes the layers directory on successful exit.
RUN_SEARCH=""           # Stores the regex pattern for the file search.
RUN_INSPECT=0           # If 1, runs the metadata inspection.
RUN_VERIFY=0            # If 1, runs the integrity verification.
QUIET_MODE=0            # If 1, suppresses all non-error output.

# Core Path and Mode Variables
SOURCE_IMAGE=""         # The full image name to be downloaded (e.g., docker://ubuntu:22.04).
LAYERS_DIR_INPUT=""     # The user-provided directory for existing layers.
DEST_DIR_RAW=""         # The user-provided target directory for the extracted filesystem.
LAYERS_DIR=""           # The absolute path to the directory where layers are stored.
DEST_DIR=""             # The absolute path to the final extraction directory.
MODE=""                 # The script's operational mode: "DOWNLOAD" or "EXISTING".

# State Tracking
LAYER_EXTRACTION_STATUS=0 # Captures the exit code of the layer extraction subshell.

# --- Core Functions ---

#
# A simple logging function that respects the --quiet flag.
# Globals:
#   - QUIET_MODE
# Arguments:
#   - $@: The message to be printed.
#
log() {
    if [ "$QUIET_MODE" -eq 0 ]; then
        echo "$@"
    fi
}

#
# Checks for the presence of all required command-line tools before execution.
# The list of tools changes based on the script's operational mode and options.
# Globals:
#   - MODE
#   - RUN_VERIFY
#
check_dependencies() {
    local required_tools=("tar" "jq" "find")
    local missing_tools=()

    # Add skopeo if we are in download mode.
    if [ "$MODE" == "DOWNLOAD" ]; then
        required_tools+=("skopeo")
    fi
    # Add sha256sum if verification is requested.
    if [ "$RUN_VERIFY" -eq 1 ]; then
        required_tools+=("sha256sum")
    fi
    
    # Check for each tool and add missing ones to the list.
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # If any tools are missing, print an error and exit.
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo "ERROR: The following critical tool(s) are missing:" >&2
        echo "           ${missing_tools[*]}" >&2
        echo "           Please install them to proceed." >&2
        exit 1
    fi
}

#
# Performs a parallel, recursive search for filenames/paths matching a regex.
# It uses 'find' for searching and 'xargs' to parallelize the output processing.
# SECURITY: The input pattern is escaped to prevent command injection.
# Arguments:
#   - $1: The directory to search within.
#   - $2: The POSIX extended regular expression to match against file paths.
#
search_files() {
    local search_dir="$1"
    local pattern="$2"
    
    log ""
    log "--- Search Results (Parallel Find) ---"
    
    # Escape single quotes in the pattern to prevent injection vulnerabilities.
    local escaped_pattern
    escaped_pattern=$(printf '%s' "$pattern" | sed "s/'/'\\\''/g")

    log "Searching filenames recursively in $search_dir for escaped pattern: '$escaped_pattern'"
    
    # Determine the number of CPU cores to use for parallel processing.
    local CPUS
    CPUS=$(nproc 2>/dev/null || echo 4) # Default to 4 if nproc fails.

    log "Using $CPUS parallel worker(s) for output processing."
    
    # Execute the find command and pipe results to xargs for parallel printing.
    # -L: Follow symbolic links.
    # -print0 / -0: Use null characters to separate filenames, handling special characters safely.
    find -L "$search_dir" -regextype posix-extended -regex ".*${escaped_pattern}.*" -print0 2>/dev/null |
    xargs -0 -P "$CPUS" -I {} echo {} || true # '|| true' prevents exit on no results.
    
    log "---------------------------"
}

#
# Inspects the image configuration file (JSON) and prints key metadata.
# Uses 'jq' with conditional logic to gracefully handle missing or null fields.
# Arguments:
#   - $1: The path to the image's JSON configuration file.
#
inspect_metadata() {
    local config_path="$1"
    log ""
    log "--- Image Metadata Inspection ---"
    
    # Simple value lookups
    log "Architecture:   $(jq -r '.architecture' "$config_path")"
    log "OS:             $(jq -r '.os' "$config_path")"
    
    # Use jq's '//' operator to provide a default "N/A" value if the field is null.
    log "User:           $(jq -r '.config.User // "N/A"' "$config_path")"
    log "Working Dir:    $(jq -r '.config.WorkingDir // "N/A"' "$config_path")"
    
    # For arrays, check if they exist and are not empty before joining them.
    log "Entrypoint:     $(jq -r '.config.Entrypoint | if type == "array" and length > 0 then join(" ") else "N/A" end' "$config_path")"
    log "CMD:            $(jq -r '.config.Cmd | if type == "array" and length > 0 then join(" ") else "N/A" end' "$config_path")"
    
    # For objects, check if they are null, otherwise print their keys.
    log "Exposed Ports:  $(jq -r '.config.ExposedPorts | if . == null then "N/A" else (keys | join(", ")) end' "$config_path")"
    
    log "---------------------------------"
}

#
# Verifies the SHA256 checksum of each layer against the digest in the manifest.
# Arguments:
#   - $1: The path to the 'manifest.json' file.
#   - $2: The directory containing the layer files (blobs).
# Returns:
#   - 0 on success, 1 if any verification fails.
#
verify_integrity() {
    local manifest_path="$1"
    local layers_dir="$2"
    
    log ""
    log "--- Content Integrity Verification ---"
    local exit_code=0
    
    # Use jq with process substitution so loop exit_code updates persist in the function scope.
    while read -r DIGEST SHA; do
        LAYER_FILE="$layers_dir/$SHA"
        
        # OCI layers can sometimes have extensions, so we check for common ones.
        if [[ ! -f "$LAYER_FILE" ]] && [[ -f "${LAYER_FILE}.tar" ]]; then
            LAYER_FILE="${LAYER_FILE}.tar"
        elif [[ ! -f "$LAYER_FILE" ]] && [[ -f "${LAYER_FILE}.tar.gz" ]]; then
            LAYER_FILE="${LAYER_FILE}.tar.gz"
        fi
        
        # If the layer file doesn't exist, record an error and continue.
        if [ ! -f "$LAYER_FILE" ]; then
            echo "ERROR: Missing layer file for digest $DIGEST." >&2
            exit_code=1
            continue
        fi

        log "Verifying ${LAYER_FILE##*/}..."
        
        # Calculate the digest and compare it to the expected value.
        CALCULATED_DIGEST=$(sha256sum "$LAYER_FILE" | awk '{print "sha256:"$1}')
        
        if [ "$CALCULATED_DIGEST" = "$DIGEST" ]; then
            log "  [PASS] Digest matched: $DIGEST"
        else
            echo "  [FAIL] Calculated: $CALCULATED_DIGEST" >&2
            echo "         Expected: $DIGEST" >&2
            exit_code=1 # Mark verification as failed.
        fi
    done < <(jq -r '.layers[] | "\(.digest) \(.digest | split(":")[1])"' "$manifest_path")
    
    # Return a non-zero status if any check failed.
    if [ $exit_code -ne 0 ]; then
        return 1
    fi
    log "Verification complete."
    log "--------------------------------------"
    return 0
}

# --- Help and Examples Functions ---

# Displays the primary help message.
show_help() {
    echo "Usage: $0 <MODE_OPTIONS> --target-dir <DEST_DIR> [GENERAL_OPTIONS]"
    echo ""; echo "This script downloads an OCI image via 'skopeo' or uses existing layers to extract the"
    echo "root filesystem, providing advanced analysis features."; echo ""; echo "--- MODE OPTIONS (Choose ONE) ---"
    echo "  --image <SOURCE_IMAGE>    : Specifies the image to download and extract.";
    echo "  --layer-dir <LAYERS_DIR>  : Specifies an existing directory containing the layers and manifest.json (skips download).";
    echo ""; echo "--- REQUIRED OPTION ---"
    echo "  --target-dir <DEST_DIR>   : The final, local directory where the merged filesystem will be extracted.";
    echo ""; echo "--- GENERAL OPTIONS ---"
    echo "  --purge-layer-dir         : Automatically delete the layers directory after successful extraction.";
    echo "  --inspect                 : Prints key image metadata (CMD, ENV, Ports, etc.) from the image configuration file.";
    echo "  --verify                  : Calculates SHA256 hashes of all layer files and compares them against the digests.";
    echo "  --search <regexp>         : Runs a parallel recursive **filename/path search** using 'find'.";
    echo "  --quiet                   : Suppress all phase and layer messages, printing only errors and the final result.";
    echo "  --examples                : Show detailed usage examples."; echo ""
}

# Displays detailed usage examples.
show_examples() {
    echo "--- Usage Examples ---"; echo ""; echo "1. Basic Download, Extraction, and Cleanup:";
    echo "./extract_oci.sh \\"; echo "  --image docker://node:20-alpine \\"; echo "  --target-dir ./node_rootfs \\"; echo "  --purge-layer-dir"; echo "";
    echo "2. Local Image Extraction with Search:"; echo "./extract_oci.sh \\"; echo "  --image my_app:v1.2 \\"; echo "  --target-dir ./app_fs \\"; echo "  --search '.*\/etc\/nginx\.conf$'"; echo ""
    echo "3. Inspection and Verification (No Extraction Focus):"; echo "./extract_oci.sh \\"; echo "  --image docker://ubuntu:22.04 \\"; echo "  --target-dir ./temp_output \\"; echo "  --inspect \\"; echo "  --verify \\"; echo "  --purge-layer-dir"; echo ""
    echo "4. Reusing Existing Layers (Debugging/Efficiency):"; echo "./extract_oci.sh \\"; echo "  --layer-dir ./busybox_layers \\"; echo "  --target-dir ./extracted_busybox_fs \\"
    echo "  --quiet"; echo ""
    echo "5. Quiet Mode for Automation (Extract and Search):"; echo "EXTRACT_PATH=\"./large_app_root\""; echo "./extract_oci.sh \\"; echo "  --image large_app:2.0 \\"; echo "  --target-dir \"\$EXTRACT_PATH\" \\"; echo "  --search '.*license.*' \\"; echo "  --quiet"
}


# --- Main Execution ---

# --- Argument Parsing ---
# A standard 'while' loop to parse command-line arguments.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) show_help; exit 0 ;;
        --examples) show_examples; exit 0 ;;
        --purge-layer-dir) PURGE_LAYERS=1; shift ;;
        --inspect) RUN_INSPECT=1; shift ;;
        --verify) RUN_VERIFY=1; shift ;;
        --quiet) QUIET_MODE=1; shift ;;
        --search)
            if [ -z "$2" ]; then echo "ERROR: --search requires a regular expression pattern." >&2; exit 1; fi
            RUN_SEARCH="$2"; shift 2 ;;
        --image) SOURCE_IMAGE="$2"; shift 2 ;;
        --layer-dir) LAYERS_DIR_INPUT="$2"; shift 2 ;;
        --target-dir) DEST_DIR_RAW="$2"; shift 2 ;;
        *) echo "ERROR: Unknown option or invalid argument: $1" >&2; echo "Use '$0 --help' for usage." >&2; exit 1 ;;
    esac
done

# --- Initial Validation and Setup ---
# Ensure that --image and --layer-dir are not used together.
if [ -n "$SOURCE_IMAGE" ] && [ -n "$LAYERS_DIR_INPUT" ]; then
    echo "ERROR: Cannot use both --image and --layer-dir simultaneously." >&2; exit 1
# Ensure the required --target-dir is always provided.
elif [ -z "$DEST_DIR_RAW" ]; then
    echo "ERROR: --target-dir is required for all operations." >&2; exit 1;
fi

# Set the operational mode and layers directory based on user input.
if [ -n "$LAYERS_DIR_INPUT" ]; then
    MODE="EXISTING"
    LAYERS_DIR="$LAYERS_DIR_INPUT"
    PURGE_LAYERS=0 # Never purge a user-provided directory.
else
    MODE="DOWNLOAD"
    # Create a secure, temporary directory for storing layers.
    LAYERS_DIR=$(mktemp -d --tmpdir=/tmp oci_extract_XXXXXX)
fi

# --- Dependency Check ---
# Perform an early check for required tools to fail fast if the environment is not ready.
check_dependencies

# --- Cleanup Trap ---
# A trap to ensure that temporary files are cleaned up upon script exit,
# interruption (Ctrl+C), or termination.
cleanup() {
    local exit_code=$?
    # Prioritize the exit code from the extraction subshell if it failed.
    if [ "$LAYER_EXTRACTION_STATUS" -ne 0 ] && [ "$exit_code" -eq 0 ]; then
        exit_code="$LAYER_EXTRACTION_STATUS"
    fi

    # Only purge the layers directory if in DOWNLOAD mode and --purge-layer-dir is set.
    if [ "$MODE" == "DOWNLOAD" ] && [ $PURGE_LAYERS -eq 1 ] && [ -d "$LAYERS_DIR" ]; then
        log "Removing temporary layers directory: $LAYERS_DIR"
        rm -rf "$LAYERS_DIR" 
    # If the script failed, notify the user where the temporary files are for debugging.
    elif [ $exit_code -ne 0 ] && [ "$MODE" == "DOWNLOAD" ] && [ -d "$LAYERS_DIR" ]; then
        echo "Script failed with code $exit_code. Layer files left at: $LAYERS_DIR" >&2
    fi
    trap - EXIT # Clear the trap before exiting.
    exit "$exit_code"
}
# The trap is only set for DOWNLOAD mode where temporary directories are created.
if [ "$MODE" == "DOWNLOAD" ]; then
    trap cleanup EXIT INT TERM
fi


# --- Phase 1: Obtain Image Source ---
if [ "$MODE" == "DOWNLOAD" ]; then
    log "--- Phase 1: Downloading Image Layers ---"
    log "Temporary Layers Directory: $LAYERS_DIR"

    # If the image name doesn't specify a transport protocol, default to the local Docker daemon.
    if [[ "$SOURCE_IMAGE" != *"://"* ]]; then
        SKOPEO_SOURCE="docker-daemon:$SOURCE_IMAGE"
    else
        SKOPEO_SOURCE="$SOURCE_IMAGE"
    fi

    log "Source Image: $SKOPEO_SOURCE"
    # Use skopeo to copy the image contents to the temporary directory.
    skopeo copy --insecure-policy "$SKOPEO_SOURCE" "dir:$LAYERS_DIR"
    
    log "--- Phase 1 Complete ---"
else # MODE == EXISTING
    log "--- Phase 1: Using Existing Layers ---"
    log "Source Layers Directory: $LAYERS_DIR"
    
    if [ ! -d "$LAYERS_DIR" ]; then
        echo "ERROR: Existing layers directory '$LAYERS_DIR' not found." >&2
        exit 1
    fi
    log "--- Phase 1 Complete ---"
fi


# --- Phase 1.5: Pre-Extraction Validation ---

# Standardize the layers directory path and define manifest/config paths.
LAYERS_DIR=$(realpath "$LAYERS_DIR")
MANIFEST_PATH="$LAYERS_DIR/manifest.json"

# Validate that the manifest.json file exists.
if [ ! -f "$MANIFEST_PATH" ]; then
    echo "ERROR: manifest.json not found in '$LAYERS_DIR'. Directory is not a valid OCI layer output." >&2
    exit 1
fi

# Get the config file's SHA from the manifest and construct its path.
CONFIG_FILE_DIGEST=$(jq -r '.config.digest | split(":")[1]' "$MANIFEST_PATH")
CONFIG_PATH="$LAYERS_DIR/$CONFIG_FILE_DIGEST"
if [ ! -f "$CONFIG_PATH" ]; then
    echo "ERROR: Configuration file '$CONFIG_FILE_DIGEST' not found." >&2
    exit 1
fi

# Run optional verification and inspection tasks if requested.
if [ "$RUN_VERIFY" -eq 1 ]; then
    verify_integrity "$MANIFEST_PATH" "$LAYERS_DIR"
fi

if [ "$RUN_INSPECT" -eq 1 ]; then
    inspect_metadata "$CONFIG_PATH"
fi

# --- Phase 2: Layer Extraction ---
log ""
log "--- Phase 2: Layer Extraction ---"

# 2.1 Destination Directory Safety Check
# Abort if the target directory exists and is not empty to prevent data loss.
if [ -d "$DEST_DIR_RAW" ]; then
    if [ -n "$(ls -A "$DEST_DIR_RAW")" ]; then
        echo "ERROR: Destination directory '$DEST_DIR_RAW' exists and is NOT empty. Aborting extraction." >&2
        exit 1
    fi
    log "Warning: Destination directory '$DEST_DIR_RAW' already exists but is empty. Proceeding."
else
    # Create the directory if it doesn't exist.
    mkdir -p "$DEST_DIR_RAW"
fi

# Resolve the absolute path for the destination directory.
DEST_DIR=$(realpath "$DEST_DIR_RAW")

log "Extraction Target: $DEST_DIR"
log "Starting layer merging..."

# 2.2 Extraction Loop
# This entire block is wrapped in a subshell (...) to reliably capture the exit status
# of the 'while' loop, which is critical for error handling.
(
    # The order of layers is determined by 'diff_ids' in the config, not the manifest.
    # We iterate through each 'diff_id' to process layers in the correct sequence.
    jq -r '.rootfs.diff_ids[]' "$CONFIG_PATH" | while read -r DIFF_ID; do
        
        # Find the numeric index of the current 'diff_id' in the config's list.
        LAYER_INDEX=$(jq -r --arg DIFF_ID "$DIFF_ID" '.rootfs.diff_ids | index($DIFF_ID)' "$CONFIG_PATH")

        # Use this index to look up the corresponding layer digest in the manifest's list.
        LAYER_DIGEST=$(jq -r --arg INDEX "$LAYER_INDEX" '.layers[($INDEX | tonumber)].digest' "$MANIFEST_PATH")

        # The layer's filename is its SHA hash.
        LAYER_SHA=$(echo "$LAYER_DIGEST" | cut -d ':' -f 2)
        
        if [ -z "$LAYER_SHA" ]; then
            echo "ERROR: Failed to map Diff ID $DIFF_ID (at index $LAYER_INDEX) to a blob digest in the manifest." >&2
            exit 1 # Exit the subshell on mapping failure.
        fi

        LAYER_FILE="$LAYERS_DIR/$LAYER_SHA"
        
        # Find the actual layer file, checking for common extensions.
        if [[ -f "$LAYER_FILE" ]]; then TARGET_FILE="$LAYER_FILE";
        elif [[ -f "${LAYER_FILE}.tar" ]]; then TARGET_FILE="${LAYER_FILE}.tar";
        elif [[ -f "${LAYER_FILE}.tar.gz" ]]; then TARGET_FILE="${LAYER_FILE}.tar.gz";
        else
            echo "ERROR: Layer file for SHA '$LAYER_SHA' (mapped from Diff ID $DIFF_ID) not found. This indicates an incomplete layer directory." >&2
            exit 1 # Exit the subshell if a layer file is missing.
        fi

        log "Applying layer: ${TARGET_FILE##*/}"
        
        # Extract the layer into the destination directory and check exit status.
        if ! tar -xf "$TARGET_FILE" -C "$DEST_DIR"; then
            echo "ERROR: tar extraction failed for ${TARGET_FILE##*/}. Aborting." >&2
            exit 1 # Exit subshell on failure.
        fi
    done
    exit 0 # Ensure the subshell exits cleanly if the loop completes.
)
# Capture the exit status of the subshell into a global variable.
LAYER_EXTRACTION_STATUS=$?

# If the subshell failed, abort the main script.
if [ "$LAYER_EXTRACTION_STATUS" -ne 0 ]; then
    echo "ERROR: Layer extraction process failed (Exit Code $LAYER_EXTRACTION_STATUS). Aborting script." >&2
    exit 1
fi

log "--- Phase 2 Complete ---"
log "Extraction complete. Files are in $DEST_DIR"

# --- Phase 3: Post-Extraction Search ---
# If a search pattern was provided, execute the search on the extracted filesystem.
if [ -n "$RUN_SEARCH" ]; then
    search_files "$DEST_DIR" "$RUN_SEARCH"
fi

# --- Final Notes ---
# Remind the user about the temporary directory if applicable.
if [ "$MODE" == "DOWNLOAD" ]; then
    log "NOTE: Layers are stored in $LAYERS_DIR. Use --purge-layer-dir to automatically delete them."
fi
