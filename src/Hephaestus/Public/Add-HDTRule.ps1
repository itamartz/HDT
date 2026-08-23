function Add-HDTRule {
    <#
        .SYNOPSIS
            Adds a rule to a rules document, at a position the caller chooses,
            leaving every other line byte-identical.

        .DESCRIPTION
            The command an administrator types to add a variable rule, and the
            one anything with a New Rule button has to run - if the command
            cannot do it, the window cannot do it either.

            WHERE THE RULE GOES IS PART OF WHAT IT MEANS. rules.yaml is one of
            five sources a variable can come from, and within it the rules are
            walked top to bottom with a set: value taking effect only if that
            variable is not already resolved. First match wins per variable, so a
            rule moved up shadows the ones below it and a rule at the bottom is a
            fallback. This is why -After and -First exist rather than a plain
            append: position is not layout here.

            THE DEFAULT IS THE END, which is the one position that cannot change
            what any existing rule does. A rule added anywhere else may take a
            variable that a rule below it used to set, and an administrator
            adding a rule should have to say so.

            IT INVENTS TEXT, so it invents it at the column the document's own
            rules are written at. YAML is whitespace-significant: a rule written
            two columns out belongs to the rule above it or to nothing, and the
            administrator's own edit is what broke the file.

            IT IS CHECKED AGAINST THE ENGINE'S OWN READER BEFORE IT RETURNS. A
            variable that is not named HDTSomething, a rule name another rule
            already uses, a value the reader cannot make sense of - all of them
            are refused here, naming what is wrong, rather than surfacing at Save
            with several more edits stacked on top.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTRuleDocument is what
            touches the share, so an edit can be composed, reviewed and abandoned
            without a file ever changing.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The new rule's name. It is what provenance reports when the rule sets
            a variable, so no other rule may already use it.

        .PARAMETER Set
            The variables the rule assigns, in the order they should be written.
            Every name must begin HDT; run Get-HDTVariableMap for the ones the
            engine knows and what they were called in MDT. A value may be a
            string, a boolean, a number or a list.

        .PARAMETER SetFrom
            A script, relative to the workspace root, whose output becomes the
            variables the rule assigns. A rule declares either Set or SetFrom,
            never both.

        .PARAMETER When
            The conditions under which the rule applies. Every one of them must
            match. Omit it for a rule that always applies.

        .PARAMETER After
            The rule the new one is placed directly after.

        .PARAMETER First
            Places the new rule above every other, where it wins over all of
            them.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the rule added.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\rules.yaml'))
            Add-HDTRule -Line $line -Name 'Fallback naming' -Set @{ HDTComputerName = 'PC-%HDTSerialNumber%' }

            Appended at the end, where it can only act as a fallback.

        .EXAMPLE
            Add-HDTRule -Line $line -Name 'Latitude naming' -When ([ordered] @{ HDTModel = 'Latitude*'; HDTIsLaptop = $true }) -Set ([ordered] @{ HDTComputerName = 'LT-%HDTSerialNumber%' }) -First

            Placed at the top, so it wins over the naming rules below it.

        .EXAMPLE
            Add-HDTRule -Line $line -Name 'Naming service' -SetFrom 'Scripts\Get-ComputerName.ps1' -After 'Lab subnet'
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'Set')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Set,

        [Parameter(Mandatory = $true, ParameterSetName = 'SetFrom')]
        [ValidateNotNullOrEmpty()]
        [string] $SetFrom,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $When,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $After,

        [Parameter()]
        [switch] $First
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- where ---------------------------------------------------------------

    if ($PSBoundParameters.ContainsKey('After') -and $First) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category InvalidArgument `
                    -Message ("-After and -First name two different places for this rule. Position decides which rule wins, so it cannot be guessed - pass one of them.")))
    }

    $block = @(Get-HDTRuleBlock -Line $Line)

    if (@($block).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category ObjectNotFound `
                    -Message ("this document declares no rules for a new one to be placed among. A rules document is a schemaVersion and a rules list holding at least one rule.")))
    }

    if (@($block | Where-Object { $_.Name -eq $Name }).Count -gt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category InvalidArgument `
                    -Message ("a rule called '{0}' is already in this document. Provenance reports the rule that set a variable, so two rules sharing a name would make that answer ambiguous." -f $Name)))
    }

    $at = [int] $block[@($block).Count - 1].End
    $before = $false

    if ($First) {
        $at = [int] $block[0].Start
        $before = $true
    } elseif ($PSBoundParameters.ContainsKey('After')) {
        $at = [int] (Resolve-HDTRuleBlock -Line $Line -Name $After).End
    }

    # -- what ----------------------------------------------------------------

    # Composed at column zero and then shifted to where it lands, which is the
    # same reindenting a pasted task sequence step goes through and for the same
    # reason: the block's internal shape survives, and the dash ends up in the
    # one column that makes it a rule.
    $text = New-Object -TypeName System.Collections.ArrayList

    [void] $text.Add(('- name: {0}' -f (ConvertTo-HDTRuleScalarText -Value $Name)))

    if ($PSBoundParameters.ContainsKey('When') -and $null -ne $When -and @($When.Keys).Count -gt 0) {
        foreach ($current in @(ConvertTo-HDTRuleMapLine -Key 'when' -Map $When -Indent 2)) {
            [void] $text.Add($current)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Set') {
        foreach ($current in @(ConvertTo-HDTRuleMapLine -Key 'set' -Map $Set -Indent 2)) {
            [void] $text.Add($current)
        }
    } else {
        [void] $text.Add(('  setFrom: {0}' -f (ConvertTo-HDTRuleScalarText -Value $SetFrom)))
    }

    $written = @(Set-HDTBlockIndent -Block ([string[]] @($text)) -Indent ([int] $block[0].Indent))

    # -- splice --------------------------------------------------------------

    $action = 'Add to the rules'
    if ($First) { $action = 'Add above every other rule' }
    if ($PSBoundParameters.ContainsKey('After')) { $action = 'Add after {0}' -f $After }

    if (-not $PSCmdlet.ShouldProcess($Name, $action)) {
        return [string[]] @($Line)
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        # A blank line between the new rule and its neighbour, so it is spaced
        # the way the rules around it are rather than welded to one of them.
        if ($before -and $i -eq $at) {
            foreach ($current in $written) { [void] $result.Add($current) }
            [void] $result.Add('')
        }

        [void] $result.Add($Line[$i])

        if (-not $before -and $i -eq $at) {
            [void] $result.Add('')
            foreach ($current in $written) { [void] $result.Add($current) }
        }
    }

    try {
        Assert-HDTRuleLine -Line ([string[]] @($result))
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] @($result)
}
