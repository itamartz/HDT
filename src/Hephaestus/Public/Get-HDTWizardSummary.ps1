function Get-HDTWizardSummary {
    <#
        .SYNOPSIS
            Builds the summary page: what was chosen, which variable holds it,
            and what to write in rules.yaml so nobody sees the wizard again.

        .DESCRIPTION
            MDT'S SUMMARY CONFIRMS. THIS ONE ALSO TEACHES, and that is
            deliberate: DESIGN 11.2 says every page is individually skippable
            and that a page whose values are all supplied never appears, but
            nothing anywhere TOLD a technician the variable names. The skip
            model was documented and undiscoverable - the only way to learn it
            was to read the design document, which is not where somebody
            standing at a bench is looking.

            So every row carries three facts rather than one:

              Setting    what the page asked        'Computer name'
              Value      what the technician chose  'HDT-01'
              Variable   what HOLDS it              'HDTComputerName'
              Skip       what hides that page       'HDTSkipComputerName'

            And the snippet is those rows AS rules.yaml, ready to paste. An
            administrator drives the wizard by hand once and leaves with the
            file that means they never have to again.

            HDTSkipWizard IS IN THE SNIPPET, not the individual skips. Hiding
            every screen is what was asked for, and one line that does it is
            easier to get right than eight that must agree with each other. The
            per-page skip variable is on the ROW, for the site that wants to
            hide one page and keep the rest.

            A VALUE NOBODY CHOSE IS OMITTED FROM THE SNIPPET RATHER THAN
            WRITTEN EMPTY. A rule that sets a variable to nothing is worse than
            no rule at all: it RESOLVES that variable, so every later rule that
            would have supplied a real one is skipped - first match wins, DESIGN
            3.1 - and the deployment proceeds with an empty name it will not
            explain.

            IT REPORTS AND DOES NOT DECIDE. Nothing here resolves, validates or
            applies anything; Resolve-HDTVariable owns that, and a second
            opinion in a summary screen is how two answers start disagreeing.

        .PARAMETER Page
            The pages the wizard asked. A page that declares Collect - a Control
            and the Variable it fills - becomes a row; one that collects nothing,
            like the summary page itself, does not.

        .PARAMETER Value
            What has been collected so far, variable name to value.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Row (Setting,
            Value, Variable, Skip, IsSet) and Snippet.

        .EXAMPLE
            Get-HDTWizardSummary -Page $page -Value @{ HDTComputerName = 'HDT-01' }

        .EXAMPLE
            (Get-HDTWizardSummary -Page $page -Value $chosen).Snippet

            The rules.yaml that makes this deployment unattended.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Page,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (@($Page).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message 'there are no wizard pages to summarise.'))
    }

    $chosen = $Value
    if ($null -eq $chosen) { $chosen = @{} }

    # WHAT YAML WOULD READ AS SOMETHING ELSE. A name of 'true' unquoted is a
    # boolean, '0123' is the number 123, and a value carrying a %Token% or a
    # leading character YAML reserves stops the document parsing at all. A
    # snippet that does not paste cleanly is a snippet that cost somebody an
    # afternoon - and quoting EVERYTHING instead would make the common case
    # noisier to read, which is how a snippet stops being read.
    $needsQuote = {
        param([string] $Text)

        if ([string]::IsNullOrEmpty($Text)) { return $true }
        if ($Text -match '^[A-Za-z][A-Za-z0-9\-\.]*$' -and $Text -notmatch '^(true|false|yes|no|on|off|null|y|n)$') { return $false }

        return $true
    }

    $row = @()
    $setLine = @()
    $skipLine = @()
    $secretLine = @()

    foreach ($current in @($Page)) {

        # EVERY PAGE IS SKIPPABLE, INCLUDING ONE THAT COLLECTS NOTHING. The
        # summary page has no value to set and still has to be hidden, so the
        # skip line is gathered before the row is decided.
        if ($null -ne $current.PSObject.Properties['Skip'] -and
            -not [string]::IsNullOrWhiteSpace([string] $current.Skip)) {

            $skipLine += ('      {0}: true' -f [string] $current.Skip)
        }

        $collect = $null
        if ($null -ne $current.PSObject.Properties['Collect']) { $collect = $current.Collect }

        # THE SUMMARY PAGE IS NOT A ROW ABOUT ITSELF.
        if ($null -eq $collect) { continue }

        # ONE PAGE, SEVERAL VARIABLES. MDT's Computer Details pane collects the
        # name, the domain or the workgroup, the OU and the account that joins -
        # so a page that could name only one variable could not describe itself.
        # @() around a single declaration is that declaration, so a page with one
        # needs no special case.
        $skip = ''
        if ($null -ne $current.PSObject.Properties['Skip']) { $skip = [string] $current.Skip }

        # ONE DECLARATION CAN FILL TWO VARIABLES. The join account is typed once
        # as CORP\svc-hdt-join and lands in HDTDomainAdmin and
        # HDTDomainAdminDomain; a snippet naming only the first would leave the
        # join to guess which domain authenticates it.
        $named = @()
        foreach ($declaration in @($collect)) {
            if ($null -eq $declaration) { continue }

            $isSecret = $false
            if ($null -ne $declaration.PSObject.Properties['IsSecret']) { $isSecret = [bool] $declaration.IsSecret }

            $named += [pscustomobject] @{ Variable = [string] $declaration.Variable; IsSecret = $isSecret }

            if ($null -ne $declaration.PSObject.Properties['SplitVariable'] -and
                -not [string]::IsNullOrWhiteSpace([string] $declaration.SplitVariable)) {

                # THE SPLIT HALF INHERITS THE SECRECY. Nothing splits a password
                # today, and a half of a secret printed because it arrived by a
                # different route is exactly the shape a leak takes.
                $named += [pscustomobject] @{ Variable = [string] $declaration.SplitVariable; IsSecret = $isSecret }
            }
        }

        foreach ($declaration in $named) {

            $variable = [string] $declaration.Variable
            $isSecret = [bool] $declaration.IsSecret

            $isSet = $false
            $shown = '(not set)'

            if ($chosen.ContainsKey($variable) -and -not [string]::IsNullOrWhiteSpace([string] $chosen[$variable])) {
                $isSet = $true
                $shown = [string] $chosen[$variable]

                # A SECRET IS CONFIRMED, NOT DISPLAYED. Get-HDTVariableMap
                # already says of HDTDomainAdminPassword: "never written to a
                # log" - and a screen a technician photographs, or a YAML block
                # they paste into a file on a share, is worse than a log.
                if ($isSecret) { $shown = '(set, not shown)' }
            }

            $row += [pscustomobject] @{
                Setting  = [string] $current.Title
                Value    = $shown
                Variable = $variable
                Skip     = $skip
                IsSet    = $isSet
            }

            if ($isSecret) {
                # NOT EVEN EMPTY, AND NOT REDACTED. A rules.yaml carrying
                # HDTDomainAdminPassword: "" RESOLVES the variable to nothing,
                # so every later rule that would have supplied it is skipped and
                # the join fails with a password nobody set rather than one
                # nobody typed. A comment names it and says where it does not go.
                $secretLine += ('#   {0} is not written here - it is collected at deployment time.' -f $variable)
                continue
            }

            if ($isSet) {
                $text = [string] $chosen[$variable]
                if (& $needsQuote $text) { $text = '"{0}"' -f $text }

                $setLine += ('      {0}: {1}' -f $variable, $text)
            }
        }
    }

    # ONE RULE, WITH NO when:, WHICH IS A FALLBACK FOR EVERY MACHINE. That is
    # what an administrator who has just deployed one machine by hand actually
    # wants; narrowing it to a model or a subnet is the next thing they will do
    # and is not something this screen can guess.
    #
    # BOTH KINDS OF SKIP ARE WRITTEN OUT. HDTSkipWizard is the blunt one and is
    # a single line to get right; the per-page keys are what a site edits when
    # it wants to hide four pages and keep two, and a snippet that named only
    # the blunt one would leave an administrator to guess the fine-grained ones
    # exist - the same undiscoverability this whole screen exists to end.
    #
    # THE WELCOME SCREEN IS NOT IN THIS FILE, AND SAYING SO IS PART OF THE
    # ANSWER. rules.yaml lives ON THE SHARE, and the Welcome screen is what
    # makes the share reachable: HDTSkipWelcome here is a rule the machine
    # cannot read until after the screen it was meant to skip has been shown.
    # It belongs in bootstrap.json inside the boot image. MDT has the same split
    # for the same reason - SkipBDDWelcome is in Bootstrap.ini and every other
    # Skip* is in CustomSettings.ini.
    #
    $secretHeader = @()
    if (@($secretLine).Count -gt 0) {
        $secretHeader = @('#') + $secretLine
    }

    $snippet = @(
        '# Paste into rules.yaml on the deployment share.'
        '#'
        '# This hides every wizard page. The WELCOME screen is not in this file:'
        '# it runs before the share is reachable, so it is set in bootstrap.json'
        '# inside the boot image (HDTSkipWelcome, or build with a credential and'
        '# without -PromptForCredential).'
    ) + $secretHeader + @(
        'schemaVersion: 1'
        'rules:'
        '  - name: Unattended'
        '    set:'
    ) + $setLine + @('      HDTSkipWizard: true') + $skipLine

    return [pscustomobject] @{
        Row     = $row
        Snippet = ($snippet -join [System.Environment]::NewLine)
    }
}
