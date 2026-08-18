function Assert-HDTBootstrapRuleDocument {
    <#
        .SYNOPSIS
            Holds a bootstrap rules document to what can be decided before there
            is a share.

        .DESCRIPTION
            THE VOCABULARY, AND NOTHING ELSE. Import-HDTRuleDocument has already
            proved the grammar; this proves that every rule sets something a
            machine with no share, no workspace and no task sequence can act on.

            WHY AN ALLOW-LIST AND NOT A WARNING. A set: this file cannot act on
            does nothing, silently, on a machine at three in the morning with
            nobody watching - and the administrator's evidence is a deployment
            that used the wrong computer name. Refusing at author time, naming
            the file that CAN set it, is the whole difference.

            THE FOUR:

              HDTDeployRoot       the reason this file exists
              HDTSkipWizard       whether to ask anybody anything - MDT's
                                  SkipBDDWelcome, which Bootstrap.ini also owns
              HDTKeyboardLocale   the wizard needs both before it can draw, and
              HDTUILanguage       drawing happens before the share is reached

            CREDENTIALS ARE NOT AMONG THEM, on purpose. Bootstrap.ini carries
            UserID and UserPassword in clear text; the account lives in
            Control\share-credential.json here, and the refusal says so rather
            than reporting an unknown name.

        .PARAMETER Document
            What Import-HDTRuleDocument returned.

        .PARAMETER Path
            The file, for the message.

        .OUTPUTS
            None. Throws a terminating error naming the file, the variable and
            the ones it would have taken.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Document) { return }

    $allowed = @('HDTDeployRoot', 'HDTSkipWizard', 'HDTKeyboardLocale', 'HDTUILanguage')

    foreach ($rule in @($Document.Rule)) {

        # A SCRIPT RULE NAMES A PATH UNDER Scripts\ ON THE SHARE, and there is
        # no share yet. Refused here rather than discovered as a file-not-found
        # on a machine that has not connected to anything.
        if ($null -ne $rule.PSObject.Properties['SetFrom'] -and
            -not [string]::IsNullOrWhiteSpace([string] $rule.SetFrom)) {

            throw ("{0}: rule '{1}' uses setFrom, and a bootstrap rule cannot. setFrom names a script under Scripts\ on the deployment share, which has not been connected to when this file is read. Decide it with when: here, or move the rule to rules.yaml where the script exists." -f
                $Path, [string] $rule.Name)
        }

        if ($null -eq $rule.PSObject.Properties['Set'] -or $null -eq $rule.Set) { continue }

        foreach ($variable in @($rule.Set.Keys)) {
            $name = [string] $variable

            if ($allowed -contains $name) { continue }

            # A PASSWORD GETS ITS OWN SENTENCE. Somebody writing one here is
            # copying a Bootstrap.ini, and "not allowed" would send them looking
            # for the right spelling rather than the right file.
            if ($name -like '*Password*' -or $name -like '*Credential*') {
                throw ("{0}: rule '{1}' sets '{2}'. No credential is written into a document here - Bootstrap.ini's clear-text UserPassword is one of the MDT exposures HDT narrows. Run Set-HDTShareCredential, which stores it protected in Control\share-credential.json and embeds it at build time." -f
                    $Path, [string] $rule.Name, $name)
            }

            throw ("{0}: rule '{1}' sets '{2}', which is decided after the deployment share is connected. This file is read before there is one, so it may set only: {3}. Move the rule to rules.yaml on the share." -f
                $Path, [string] $rule.Name, $name, ($allowed -join ', '))
        }
    }
}
