function Get-HDTWizardSummary {
    <#
        .SYNOPSIS
            Builds the summary page: what was chosen, which variable holds it,
            and what to write in rules.yaml so nobody sees the wizard again.

        .DESCRIPTION
            IT CONFIRMS WHAT WAS CHOSEN, AND IT ALSO TEACHES, which is
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
            $provider = New-HDTLocalContentProvider -Root 'C:\HDTLab\Share'
            $wizard = Import-HDTWizardDocument -Provider $provider
            $page = @($wizard.Page)[0]
            $summary = Get-HDTWizardSummary -Page $page -Value @{ HDTComputerName = 'HDT-01' }

            The last screen: what was chosen, and which variable each answer lands in.

        .EXAMPLE
            $summary.Snippet

            The rules.yaml that would make this same deployment unattended next time.
            A technician who typed the same three answers on twenty machines is a
            technician nobody gave that snippet to.

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

    $skipLine = @()
    $candidate = @()

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
        foreach ($declaration in @($collect)) {
            if ($null -eq $declaration) { continue }

            $isSecret = $false
            if ($null -ne $declaration.PSObject.Properties['IsSecret']) { $isSecret = [bool] $declaration.IsSecret }

            $candidate += [pscustomobject] @{
                Variable = [string] $declaration.Variable
                IsSecret = $isSecret
                IsSplit  = $false
                Setting  = [string] $current.Title
                Skip     = $skip
            }

            if ($null -ne $declaration.PSObject.Properties['SplitVariable'] -and
                -not [string]::IsNullOrWhiteSpace([string] $declaration.SplitVariable)) {

                # THE SPLIT HALF INHERITS THE SECRECY. Nothing splits a password
                # today, and a half of a secret printed because it arrived by a
                # different route is exactly the shape a leak takes.
                $candidate += [pscustomobject] @{
                    Variable = [string] $declaration.SplitVariable
                    IsSecret = $isSecret
                    IsSplit  = $true
                    Setting  = [string] $current.Title
                    Skip     = $skip
                }
            }
        }
    }

    # ONE VARIABLE, ONE ROW - AND ONE LINE IN THE SNIPPET.
    #
    # A VARIABLE IS LEGITIMATELY DECLARED TWICE. The shipped ComputerDetail page
    # asks for HDTDomainAdminDomain in its own box AND splits it off
    # CORP\svc-hdt-join, because a technician may type the account and its
    # domain separately or type one string carrying both. Both declarations are
    # right; a summary listing CORP on two rows was not, and it reported one
    # answer as though the deployment had been told two things.
    #
    # AND IN THE SNIPPET IT IS WORSE THAN COSMETIC. That block is pasted into
    # rules.yaml, where the FIRST match wins (DESIGN 3.1), so one variable set
    # twice inside one rule teaches a shape that bites the day the two lines
    # disagree.
    #
    # WHICH DECLARATION WINS, decided here rather than left to whichever the
    # enumeration reached first:
    #
    #   1. one whose value IS set beats one that is not - the row a technician
    #      filled in is the row worth keeping. (A value is looked up by variable
    #      NAME, so today every declaration of one variable agrees about that;
    #      the rule is stated first so it stays true if that ever changes.)
    #   2. a declaration with ITS OWN CONTROL beats a split half. The half is
    #      DERIVED - whatever was left of CORP\svc-hdt-join after the backslash -
    #      while HDTDomainAdminDomainBox is a box somebody typed into, and it is
    #      that box's page, title and skip variable the summary should name.
    #   3. otherwise the first page to ask wins, which keeps the rows in the
    #      order the wizard asked them.
    #
    # SECRECY IS NOT A TIE-BREAK, IT IS STICKY. A variable any declaration calls
    # a secret is a secret on the row that survives, whichever declaration won -
    # a half printed because it arrived by the other route is exactly the shape
    # a leak takes.
    #
    # ON THE NAME, NEVER ON THE VALUE. A machine named CORP joining a domain
    # named CORP is two answers, not one, and dropping either row would hide
    # half the deployment.
    $order = @()
    $winner = @{}
    $secretVariable = @{}

    foreach ($entry in @($candidate)) {

        $variable = [string] $entry.Variable

        $isSet = ($chosen.ContainsKey($variable) -and -not [string]::IsNullOrWhiteSpace([string] $chosen[$variable]))

        $rank = 0
        if ($isSet) { $rank += 2 }
        if (-not $entry.IsSplit) { $rank += 1 }

        if ($entry.IsSecret) { $secretVariable[$variable] = $true }

        if (-not $winner.ContainsKey($variable)) {
            $order += $variable
            $winner[$variable] = [pscustomobject] @{ Entry = $entry; Rank = $rank }
            continue
        }

        # STRICTLY GREATER, so an equal rank leaves the first one standing.
        if ($rank -gt [int] $winner[$variable].Rank) {
            $winner[$variable] = [pscustomobject] @{ Entry = $entry; Rank = $rank }
        }
    }

    $row = @()
    $setLine = @()
    $secretLine = @()

    foreach ($variable in $order) {

        $entry = $winner[$variable].Entry
        $isSecret = $secretVariable.ContainsKey($variable)

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
            Setting  = [string] $entry.Setting
            Value    = $shown
            Variable = $variable
            Skip     = [string] $entry.Skip
            IsSet    = $isSet
        }

        if ($isSecret) {
            # NOT EVEN EMPTY, AND NOT REDACTED. A rules.yaml carrying
            # HDTDomainAdminPassword: "" RESOLVES the variable to nothing,
            # so every later rule that would have supplied it is skipped and
            # the join fails with a password nobody set rather than one
            # nobody typed. A comment names it and says where it does not go.
            #
            # THE SENTENCE IS SAID ONCE, ABOVE THE LIST, RATHER THAN ONCE PER
            # NAME. It read '#   {0} is not written here - it is collected at
            # deployment time.', which is 84 characters for a 22-character
            # variable - past the 68 this box fits (see the snippet comment
            # below) - so all three wrapped, and a longer name would only have
            # been worse. One heading and a bare indented name per line says the
            # same thing, fits, and reads as the list it always was.
            $secretLine += ('#   {0}' -f $variable)
            continue
        }

        if ($isSet) {
            $text = [string] $chosen[$variable]
            if (& $needsQuote $text) { $text = '"{0}"' -f $text }

            $setLine += ('      {0}: {1}' -f $variable, $text)
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
    # ===== EVERY LINE HERE IS WRITTEN TO A 68-CHARACTER BUDGET =====
    #
    # This block is rendered into HDTSummarySnippet, which owns the whole
    # summary page and is already as wide as it can get: the shell is 900px, the
    # rail takes 230, the content margin 36, the ScrollViewer's padding 12 and
    # its own scrollbar the rest - about 542px, or a shade over 70 characters of
    # Consolas at HDTHintSize. Summary.xaml therefore wraps, deliberately and
    # permanently, because a clipped line there is UNREACHABLE rather than
    # merely awkward (the reasoning is on that file).
    #
    # BUT A NET THAT CATCHES EVERY LINE IS A NET HOLDING THE WHOLE WEIGHT. The
    # prose here used to run to 84 characters, so six header lines wrapped on a
    # real render and one continuation started at column 0 - which momentarily
    # reads as the wrong YAML indent level in a format where indentation is the
    # meaning. The fix is at the source: say it in fewer characters per line.
    #
    # 68 rather than 70 leaves two characters of margin, since that sum measures
    # a layout rather than guaranteeing one. Tests/unit/Get-HDTWizardSummary
    # asserts it, and carries the arithmetic to redo if the layout moves.
    #
    # WHAT IS EXEMPT, AND IT IS ONLY THIS: a value the technician typed. An OU
    # of any realistic depth blows the budget, and re-breaking or truncating a
    # YAML value would change what pastes. That line is what the wrapping is
    # for. The set: keys stay at six spaces - two saved there would not rescue a
    # DN either, and the snippet should look like the rules.yaml it goes into.
    #
    $secretHeader = @()
    if (@($secretLine).Count -gt 0) {
        $secretHeader = @(
            '#'
            '# These are collected at deployment time, not written here:'
        ) + $secretLine
    }

    $snippet = @(
        '# Paste into rules.yaml on the deployment share.'
        '#'
        '# This hides every wizard page. The WELCOME screen is not here:'
        '# it runs before the share is reachable, so it is set instead in'
        '# bootstrap.json inside the boot image (HDTSkipWelcome, or build'
        '# with a credential and without -PromptForCredential).'
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
