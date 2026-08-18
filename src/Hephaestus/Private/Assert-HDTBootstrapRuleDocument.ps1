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

            THE SEVEN:

              HDTDeployRoot       the reason this file exists
              HDTUserId           the account to open it with - MDT's UserID,
              HDTUserDomain       UserDomain and UserPassword, which
              HDTUserPassword     Bootstrap.ini has always carried
              HDTSkipWizard       whether to ask anybody anything - MDT's
                                  SkipBDDWelcome, which Bootstrap.ini also owns
              HDTKeyboardLocale   the wizard needs both before it can draw, and
              HDTUILanguage       drawing happens before the share is reached

            THE ACCOUNT IS ON THE LIST BECAUSE THE SHARE IS. One boot image
            serving many sites needs an account per site as much as a share per
            site: a rule that chose \SERVER-B\Share and left SERVER-A's
            account behind has chosen a share it cannot open.

            THE PASSWORD IS CLEAR TEXT HERE, exactly as it was in Bootstrap.ini.
            The file is copied INTO the boot image, and anybody holding that
            image already holds the credential baked into it - so the secret is
            not made more available by being readable, only more obvious.

            THE DOMAIN JOIN ACCOUNT IS STILL REFUSED. HDTDomainAdminPassword
            joins a machine to a domain long after the share is open, and
            belongs in rules.yaml ON the share, which is not carried around
            inside an image.

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

    # WHAT A RULE MAY SET BEFORE THERE IS A SHARE. The account is on the list
    # because MDT's Bootstrap.ini carries it: one boot image serving many sites
    # needs an account per site as much as a share per site, and a rule that
    # chose SERVER-B and left SERVER-A's account behind has chosen a share it
    # cannot open. The password is clear text here, as it was there.
    $allowed = @('HDTDeployRoot', 'HDTSkipWizard', 'HDTKeyboardLocale', 'HDTUILanguage',
        'HDTUserId', 'HDTUserDomain', 'HDTUserPassword')

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

            # A DEPLOY ROOT WITH ONE LEADING BACKSLASH IS NOT A UNC, and it is
            # the mistake this file attracts - found on the lab share, written
            # by hand. YAML is not the culprit: a plain scalar keeps both
            # slashes, and the double-quoted form throws rather than eating one.
            # So it is a typo nothing else would notice until WinPE had already
            # been handed a path it cannot resolve, on a machine nobody is
            # watching.
            if ([string]::Equals($name, 'HDTDeployRoot', [System.StringComparison]::OrdinalIgnoreCase)) {

                $root = [string] $rule.Set[$variable]

                if ($root -match '^\\[^\\]') {
                    throw ("{0}: rule '{1}' sets HDTDeployRoot to '{2}', which starts with ONE backslash. A UNC path needs two: '\\{3}'. Nothing else would notice - WinPE would be handed a path it cannot resolve, on a machine nobody is watching." -f
                        $Path, [string] $rule.Name, $root, $root.TrimStart('\'))
                }
            }

            if ($allowed -contains $name) { continue }

            # A PASSWORD THAT IS NOT THE SHARE'S GETS ITS OWN SENTENCE.
            # HDTUserPassword is allowed above - it is the account this file
            # exists to choose. Anything else with Password in its name is a
            # secret used AFTER the share is open, most often the domain join
            # account, and "not allowed" would send somebody looking for the
            # right spelling rather than the right file.
            if ($name -like '*Password*' -or $name -like '*Credential*') {
                throw ("{0}: rule '{1}' sets '{2}', which is used after the deployment share is connected. This file is read before there is one, and the only credential it may carry is the share's own - HDTUserId, HDTUserDomain and HDTUserPassword. Put '{2}' in rules.yaml on the share." -f
                    $Path, [string] $rule.Name, $name)
            }

            throw ("{0}: rule '{1}' sets '{2}', which is decided after the deployment share is connected. This file is read before there is one, so it may set only: {3}. Move the rule to rules.yaml on the share." -f
                $Path, [string] $rule.Name, $name, ($allowed -join ', '))
        }
    }
}
