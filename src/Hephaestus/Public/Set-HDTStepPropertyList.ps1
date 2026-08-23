function Set-HDTStepPropertyList {
    <#
        .SYNOPSIS
            Writes a step property whose value is a list, in place, keeping the
            comments around it.

        .DESCRIPTION
            THE LIST HALF OF Set-HDTStepProperty. That one writes a SCALAR and
            hands the text to Get-HDTConsoleScalarText, which quotes anything
            opening with '[' - correctly, because a scalar that started a flow
            sequence would stop being a scalar. Asked for successCodes it writes

                successCodes: '[0, 3010]'

            which parses back as ONE STRING, and Invoke-HDTCommandLineStep casts
            each entry to [int] and dies on the bracket. Until now the console
            offered no way to edit these at all, which is why nothing had hit it.

            FLOW, NOT BLOCK, AND THAT IS A DECISION. The block form

                features:
                  - Web-Server

            reads better for a long list, and this writes the flow form anyway:

              * every template in this repo already writes flow -
                'successCodes: [0, 3010]', 'features: []' - so the console
                agrees with the file it was handed rather than reformatting it
                the first time anybody presses Apply (DESIGN 12);

              * Get-HDTStepKey ends its scan of a step at the first line
                matching '^\s*-\s', so a block list under a key would hide every
                key BELOW it from Set-HDTStepProperty. A page that wrote one
                would break the page next to it;

              * one line in means one line out, so this is the same
                single-line splice every other edit here makes, and the comments
                above and below survive for free.

            AN EMPTY LIST IS WRITTEN AS [], NOT REMOVED. The key present and
            empty is a different statement from the key absent: Install Roles
            ships with 'features: []' precisely so its page has something to
            show. Clearing the last entry and finding the setting gone would
            read as a setting nobody had ever touched.

        .PARAMETER Line
            The document's lines, as read.

        .PARAMETER Name
            The step to edit, by name.

        .PARAMETER Occurrence
            Which step of that name, 1-based, for a sequence holding more than
            one. Defaults to the first.

        .PARAMETER Property
            The key to write.

        .PARAMETER Item
            The entries. Blank ones are dropped - a page with an empty row at
            the end should not add an empty feature - and each is quoted if it
            carries anything that would end the entry early.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document, with that one line rewritten.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'))
            Set-HDTStepPropertyList -Line $line -Name 'Install the agent' -Property 'successCodes' -Item @('0', '1641')

        .EXAMPLE
            Set-HDTStepPropertyList -Line $line -Name 'Install Roles and Features' -Property 'features' -Item @('Web-Server')
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
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
        [ValidateNotNullOrEmpty()]
        [string] $Property,

        [Parameter(Mandatory = $true, Position = 3)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Item,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Occurrence = 0
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $target = Resolve-HDTStepBlock -Line $Line -Name $Name -Occurrence $Occurrence
    $found = Get-HDTStepKey -Line $Line -Block $target -Key $Property

    # WHAT ENDS AN ENTRY EARLY. A comma is the separator, a bracket or a brace
    # closes the sequence, and a colon-space or a space-hash mean something else
    # again to a YAML reader. Anything carrying one of those is quoted; a plain
    # 'Web-Server' or '3010' is left bare, which is what every template writes
    # and what a diff should keep showing.
    $quoted = foreach ($one in @($Item)) {
        if ([string]::IsNullOrWhiteSpace($one)) { continue }

        $text = [string] $one

        if ($text -match '[,\[\]\{\}]' -or $text -match ':\s' -or $text -match '\s#' -or
            $text -ne $text.Trim() -or $text -match '^["'']') {

            $text = "'{0}'" -f ($text -replace "'", "''")
        }

        $text
    }

    $written = '{0}{1}: [{2}]' -f (' ' * $found.Indent), $Property, ((@($quoted)) -join ', ')

    # THE ENTRY LINE KEEPS ITS DASH, for the reason Set-HDTStepProperty gives:
    # '- name: X' is a list item whose first key happens to be the name, and
    # rewriting it as a plain key folds the step into the one above it.
    if ($found.Index -ge 0 -and $found.Index -eq [int] $target.Entry) {
        $written = '{0}- {1}: [{2}]' -f (' ' * [int] $target.Indent), $Property, ((@($quoted)) -join ', ')
    }

    if (-not $PSCmdlet.ShouldProcess($Name, ("Set {0} to a list of {1}" -f $Property, @($quoted).Count))) {
        return [string[]] @($Line)
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($found.Index -ge 0 -and $i -eq $found.Index) {
            [void] $result.Add($written)
            continue
        }

        [void] $result.Add($Line[$i])

        # A KEY THE STEP HAS NEVER NAMED GOES IN AFTER type, which is where
        # Get-HDTStepKey points Insert and where a reader looks for what a step
        # does before how it reports it.
        if ($found.Index -lt 0 -and $i -eq $found.Insert) {
            [void] $result.Add($written)
        }
    }

    return [string[]] @($result)
}
