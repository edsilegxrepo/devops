@{
    # PSScriptAnalyzer Enterprise Settings
    # Enforces comprehensive security, reliability, and maintainability standards.

    # Severity levels to include in reports
    Severity = @('Error', 'Warning', 'Information')

    # Detailed Rule Configuration & Hardening
    # All default rules are enabled. The following specific rules are hardened or configured.
    Rules = @{
        # --- Security & Portability ---
        PSAvoidUsingComputerNameHardcoded              = @{ Enable = $true } # Error: Use parameters instead of hardcoded hostnames
        PSAvoidUsingInvokeExpression                   = @{ Enable = $true } # Warning: Prevents command injection
        PSAvoidUsingPlainTextForPassword               = @{ Enable = $true } # Warning: No hardcoded secrets
        PSAvoidUsingUsernameAndPasswordParams          = @{ Enable = $true } # Error: Use PSCredential objects
        PSUsePSCredentialType                          = @{ Enable = $true } # Warning: Proper type safety for credentials
        PSAvoidUsingConvertToSecureStringWithPlainText = @{ Enable = $true } # Error: Secure handling of sensitive data
        PSAvoidUsingInternalURLs                       = @{ Enable = $true } # Information: Avoid leaking internal infra details

        # --- Reliability & Bug Prevention ---
        PSPossibleIncorrectComparisonWithNull          = @{ Enable = $true } # Warning: $null must be on the left side ($null -eq $var)
        PSPossibleIncorrectUsageOfRedirectionOperator   = @{ Enable = $true } # Warning: Detects accidental use of '>' instead of '-gt'
        PSUseUsingScopeModifierInNewRunspaces           = @{ Enable = $true } # Error: Required for thread safety in multi-runspace scripts
        PSAvoidAssignmentToAutomaticVariable           = @{ Enable = $true } # Error: Protects system variables ($Error, $PID, etc.)
        PSAvoidUsingEmptyCatchBlock                     = @{ Enable = $true } # Warning: Prevents silent failure anti-patterns
        PSUseDeclaredVarsMoreThanAssignments           = @{ Enable = $true } # Warning: Dead code and uninitialized variable detection
        PSReviewUnusedParameter                         = @{ Enable = $true } # Warning: Keeps API signatures clean
        PSUseShouldProcessForStateChangingFunctions     = @{ Enable = $true } # Warning: Mandatory for -WhatIf / -Confirm support
        PSUseSupportsShouldProcess                     = @{ Enable = $true } # Warning: Ensures correct ShouldProcess implementation

        # --- Best Practices & Standards ---
        PSUseApprovedVerbs                             = @{ Enable = $true } # Warning: PowerShell standard naming
        PSUseSingularNouns                              = @{ Enable = $true } # Warning: PowerShell standard naming
        PSUseToExportFieldsInManifest                  = @{ Enable = $true } # Warning: Explicit exports in manifests (no wildcards)
        PSAvoidUsingWMICmdlet                          = @{ Enable = $true } # Warning: Use CIM instead of legacy WMI
        PSAvoidUsingWriteHost                          = @{ Enable = $true } # Warning: Use Write-Output/Verbose for better redirection

        # --- Style & Formatting (Synced with .editorconfig) ---
        PSUseConsistentIndentation                     = @{ Enable = $true; IndentationSize = 4 }
        PSUseConsistentWhitespace                      = @{ Enable = $true }
        PSPlaceOpenBraceOnSameLine                     = @{ Enable = $true }
        PSPlaceCloseBraceOnNewLine                     = @{ Enable = $true }
    }
}
