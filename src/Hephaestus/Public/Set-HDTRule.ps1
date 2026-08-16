function Set-HDTRule {
    <#
        .SYNOPSIS
            Changes what one rule matches on and what it assigns, leaving every
            other line byte-identical.

        .DESCRIPTION
            The command an administrator types to edit a variable rule, and the
            one anything with a rule editor has to run.

            IT REPLACES A KEY, NOT A FILE. when:, set: and setFrom: are each a
            range of lines, and only the range the caller named is rewritten. The
            comment above the rule, the rules either side of it, the header at
            the top of the file and the spacing between everything come back
            exactly as they went in - which is the whole point, because
            rules.yaml is hand-edited from the day it is created and an editor
            that reformats it makes every change unreviewable.

            A RULE ASSIGNS EITHER WAY, NEVER BOTH. Giving -Set to a rule that had
            setFrom: swaps one for the other, and so does the reverse: that is
            what the caller asked for, and leaving both behind would produce a
            document the engine refuses to load. Passing both at once is refused,
            because there is no rule that could be.

            AN EMPTY -When REMOVES THE CONDITIONS. A when: with nothing under it
            is not a document the engine loads, so "no conditions" can only mean
            "this rule always applies" - which is how a rule is turned into a
            fallback.

            RENAMING IS AN EDIT LIKE ANY OTHER, and it happens on the rule's own
            entry line. The name is what provenance reports, so no other rule may
            already use the new one.

            IT IS CHECKED AGAINST THE ENGINE'S OWN READER BEFORE IT RETURNS, so a
            variable that is not named HDTSomething is refused here rather than
            at Save.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTRuleDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The rule to change. A name that is not there is an error rather than
            a silent no-op.

        .PARAMETER NewName
            What the rule is renamed to.

        .PARAMETER When
            The conditions the rule matches on, replacing whatever it had. Empty
            removes them, so the rule always applies.

        .PARAMETER Set
            The variables the rule assigns, replacing whatever it assigned.
            Every name must begin HDT.

        .PARAMETER SetFrom
            A script, relative to the workspace root, whose output becomes the
            variables the rule assigns.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document, with one rule changed.

        .EXAMPLE
            Set-HDTRule -Line $line -Name 'Fallback' -Set ([ordered] @{ HDTComputerName = 'PC-%HDTAssetTag%' })

        .EXAMPLE
            Set-HDTRule -Line $line -Name 'Latitude naming' -When ([ordered] @{ HDTModel = 'Latitude*' })

        .EXAMPLE
            Set-HDTRule -Line $line -Name 'Fallback' -When ([ordered] @{})

            Removes the conditions, so the rule applies to every machine.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $NewName,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $When,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Set,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $SetFrom
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $hasWhen = $PSBoundParameters.ContainsKey('When')
    $hasSet = $PSBoundParameters.ContainsKey('Set')
    $hasSetFrom = $PSBoundParameters.ContainsKey('SetFrom')
    $hasName = $PSBoundParameters.ContainsKey('NewName')

    if ($hasSet -and $hasSetFrom) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category InvalidArgument `
                    -Message ("a rule declares either set or setFrom, never both. Pass -Set for variables written in the file, or -SetFrom for a script that works them out.")))
    }

    if (-not ($hasWhen -or $hasSet -or $hasSetFrom -or $hasName)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category InvalidArgument `
                    -Message ("nothing was asked to change. Pass -NewName, -When, -Set or -SetFrom.")))
    }

    # The rule has to exist before anything else is worth reporting.
    [void] (Resolve-HDTRuleBlock -Line $Line -Name $Name)

    if ($hasName) {
        $taken = @(Get-HDTRuleBlock -Line $Line | Where-Object { $_.Name -eq $NewName -and $_.Name -ne $Name })

        if (@($taken).Count -gt 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $NewName -Category InvalidArgument `
                        -Message ("a rule called '{0}' is already in this document. Provenance reports the rule that set a variable, so two rules sharing a name would make that answer ambiguous." -f $NewName)))
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Change the rule')) {
        return [string[]] @($Line)
    }

    $result = [string[]] @($Line)

    # -- the conditions ------------------------------------------------------

    # THE BLOCK IS RESOLVED AGAIN BEFORE EVERY SPLICE. Each one changes how many
    # lines are above the next, so a block held across two of them points at the
    # wrong range for the second.
    if ($hasWhen) {
        $block = Resolve-HDTRuleBlock -Line $result -Name $Name
        $text = [string[]] @()

        if ($null -ne $When -and @($When.Keys).Count -gt 0) {
            $text = [string[]] @(ConvertTo-HDTRuleMapLine -Key 'when' -Map $When -Indent ([int] $block.Indent + 2))
        }

        $result = [string[]] @(Set-HDTRuleKey -Line $result -Block $block -Key 'when' -Text $text)
    }

    # -- what it assigns -----------------------------------------------------

    if ($hasSet) {
        $block = Resolve-HDTRuleBlock -Line $result -Name $Name
        $text = [string[]] @()

        if ($null -ne $Set) {
            $text = [string[]] @(ConvertTo-HDTRuleMapLine -Key 'set' -Map $Set -Indent ([int] $block.Indent + 2))
        }

        $result = [string[]] @(Set-HDTRuleKey -Line $result -Block $block -Key 'set' -Text $text)

        # A rule declares one or the other, so the one being replaced goes.
        $block = Resolve-HDTRuleBlock -Line $result -Name $Name
        $result = [string[]] @(Set-HDTRuleKey -Line $result -Block $block -Key 'setFrom' -Text ([string[]] @()))
    }

    if ($hasSetFrom) {
        $block = Resolve-HDTRuleBlock -Line $result -Name $Name

        $text = [string[]] @(('{0}setFrom: {1}' -f (' ' * ([int] $block.Indent + 2)), (ConvertTo-HDTRuleScalarText -Value $SetFrom)))
        $result = [string[]] @(Set-HDTRuleKey -Line $result -Block $block -Key 'setFrom' -Text $text)

        $block = Resolve-HDTRuleBlock -Line $result -Name $Name
        $result = [string[]] @(Set-HDTRuleKey -Line $result -Block $block -Key 'set' -Text ([string[]] @()))
    }

    # -- the name ------------------------------------------------------------

    # Renaming last, because every lookup above finds the rule by the name it
    # still has.
    if ($hasName) {
        $block = Resolve-HDTRuleBlock -Line $result -Name $Name
        $key = @(Get-HDTRuleKey -Line $result -Block $block | Where-Object { $_.Name -eq 'name' })

        if (@($key).Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category InvalidOperation `
                        -Message ("this rule carries no name: line to rename. Every rule declares one; it is what provenance reports.")))
        }

        $at = [int] $key[0].Index

        # THE ENTRY LINE KEEPS ITS DASH. `- name: X` is a list item whose first
        # key happens to be the name; rewriting it as a plain key would fold the
        # rule into the one above it.
        $written = '{0}name: {1}' -f (' ' * [int] $key[0].Indent), (ConvertTo-HDTRuleScalarText -Value $NewName)

        if ($at -eq [int] $block.Entry) {
            $written = '{0}- name: {1}' -f (' ' * [int] $block.Indent), (ConvertTo-HDTRuleScalarText -Value $NewName)
        }

        $rewritten = New-Object -TypeName System.Collections.ArrayList

        for ($i = 0; $i -lt $result.Count; $i++) {
            if ($i -eq $at) {
                [void] $rewritten.Add($written)
                continue
            }

            [void] $rewritten.Add($result[$i])
        }

        $result = [string[]] @($rewritten)
    }

    try {
        Assert-HDTRuleLine -Line $result
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
