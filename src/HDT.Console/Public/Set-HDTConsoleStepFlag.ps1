function Set-HDTConsoleStepFlag {
    <#
        .SYNOPSIS
            Switches a step off, or lets it fail without stopping the
            deployment, without reformatting the document.

        .DESCRIPTION
            THE OPTIONS TAB'S TWO CHECKBOXES, AS A COMMAND. Deployment
            Workbench puts "Disable this step" and "Continue on error" on a tab
            beside Properties; DESIGN 12 says the console may not do anything
            the cmdlets can't, so both are this cmdlet before they are controls.

            SWITCHING A STEP OFF IS NOT DELETING IT, and that is the whole point
            of the box. The reason to disable one is almost always to run the
            sequence again and watch what changes - which needs the step, its
            properties and the comment above it to still be in the file when the
            answer turns out to be no. The engine skips a disabled step
            (Invoke-HDTTaskSequence branch 2a) and the tree draws it struck
            through; this writes the fact.

            IT SPLICES. See Add-HDTConsoleStep for why nothing here parses YAML:
            a round trip through ConvertFrom-HDTYaml returns a dictionary, a
            dictionary has no comments in it, and DESIGN 12 forbids a UI that
            reformats the file. Exactly one line is inserted or rewritten and
            every other byte comes back as it went in.

            SETTING A FLAG TO WHAT IT ALREADY MEANS WRITES NOTHING. An absent
            `disabled:` already means false, so setting false on a step that has
            no such key would add a line that changes no behaviour and shows up
            in somebody's review as a question to answer. The default is left
            unwritten, which is how every sample sequence in this repository is
            written.

            A GROUP TAKES THE FLAG TOO, AND ITS STEPS ARE LEFT ALONE.
            Get-HDTConsoleStepKey stops at the group's `steps:`, so switching
            off 'Install' does not rewrite the first line inside it that happens
            to say `disabled:`.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to change. Ambiguous names are refused rather
            than guessed - see Resolve-HDTConsoleStepBlock.

        .PARAMETER Flag
            Disabled or ContinueOnError.

        .PARAMETER Value
            What it becomes.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document, with one line changed.

        .EXAMPLE
            Set-HDTConsoleStepFlag -Line $line -Name 'Apply OS' -Flag Disabled -Value $true

            Switches a step off, keeping it and its comment in the file.

        .EXAMPLE
            $line = Set-HDTConsoleStepFlag -Line $line -Name 'Install Applications' -Flag ContinueOnError -Value $true
            Save-HDTConsoleSequence -Path $path -Line $line -FileSystem (New-HDTFileSystem)
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

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateSet('Disabled', 'ContinueOnError')]
        [string] $Flag,

        [Parameter(Mandatory = $true, Position = 3)]
        [bool] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $target = Resolve-HDTConsoleStepBlock -Line $Line -Name $Name

    # The parameter is named the way the console reads; the file is written the
    # way the engine reads. Import-HDTSequenceDocument's common-key list is the
    # authority for both spellings.
    $key = 'disabled'
    if ($Flag -eq 'ContinueOnError') { $key = 'continueOnError' }

    $found = Get-HDTConsoleStepKey -Line $Line -Block $target -Key $key

    $text = 'false'
    if ($Value) { $text = 'true' }

    # An absent key already means false. Writing it would add a line that
    # changes nothing and asks a reviewer a question with no answer.
    if ($found.Index -lt 0 -and -not $Value) {
        return [string[]] @($Line)
    }

    $action = 'Set {0} to {1}' -f $key, $text

    if (-not $PSCmdlet.ShouldProcess($Name, $action)) {
        return [string[]] @($Line)
    }

    $written = '{0}{1}: {2}' -f (' ' * $found.Indent), $key, $text

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($found.Index -ge 0 -and $i -eq $found.Index) {
            # In place, so the keys around it keep the order they were written
            # in and the diff is one line.
            [void] $result.Add($written)
            continue
        }

        [void] $result.Add($Line[$i])

        if ($found.Index -lt 0 -and $i -eq $found.Insert) {
            [void] $result.Add($written)
        }
    }

    return [string[]] @($result)
}
