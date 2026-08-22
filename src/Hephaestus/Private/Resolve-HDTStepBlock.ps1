function Resolve-HDTStepBlock {
    <#
        .SYNOPSIS
            Finds the one block a step-editing cmdlet was asked to act on.

        .DESCRIPTION
            The lookup every editing cmdlet shares, so "no such step" reads the
            same whichever button produced it and is written once.

            A NAME THAT IS NOT THERE IS AN ERROR, NOT A NO-OP. An edit that
            silently changed nothing would leave an administrator pressing a
            button and watching the file not change, with nothing to read.

            AN AMBIGUOUS NAME IS ALSO AN ERROR. A sequence may legally hold two
            steps called 'Restart' and the console must not guess which one the
            administrator meant - the same refusal DiskPartition makes about an
            ambiguous disk, for the same reason.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to find.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - one block from
            Get-HDTStepBlock.

        .PARAMETER Occurrence
            Which of the same-named blocks to return, 1-based, in document
            order. Omitted, an ambiguous name is refused - which is what a
            command line wants and what a console, holding a selected row,
            does not.

        .EXAMPLE
            Resolve-HDTStepBlock -Line $line -Name 'Apply OS'

        .EXAMPLE
            Resolve-HDTStepBlock -Line $line -Name 'Tattoo' -Occurrence 2

            The second of two, which is the row the console had selected.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # WHICH OF THE SAME-NAMED BLOCKS, IN DOCUMENT ORDER, 1-BASED. 0 means
        # "the caller did not say", which is the command line's case and keeps
        # the refusal below exactly as it was.
        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Occurrence = 0
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $block = @(Get-HDTStepBlock -Line $Line)
    $matched = @($block | Where-Object { $_.Name -eq $Name })

    if (@($matched).Count -eq 0) {
        throw (New-HDTErrorRecord -Path $Name -Category ObjectNotFound `
                -Message ("there is no step or group called '{0}' in this task sequence." -f $Name))
    }

    # AN ORDINAL SETTLES IT, AND ONLY A CALLER THAT HAS ONE MAY PASS IT.
    #
    # A CONSOLE HAS ONE AND A COMMAND LINE DOES NOT. `Remove-HDTStep -Name
    # 'Tattoo'` on a document with two of them genuinely is ambiguous, and
    # CLAUDE.md rule 6 refuses an ambiguous target rather than guessing. But the
    # console never asked an ambiguous question: a technician clicked a ROW, and
    # the console threw that away and passed a string. The row is the answer.
    #
    # DUPLICATE NAMES ARE LEGITIMATE. MDT allows them, a sequence that tattoos
    # twice is a real sequence, and "rename one of them first" was a toolkit
    # asking an administrator to change their deployment to suit its addressing.
    if ($Occurrence -gt 0) {
        if ($Occurrence -gt @($matched).Count) {
            throw (New-HDTErrorRecord -Path $Name -Category ObjectNotFound `
                    -Message ("this task sequence holds {0} step(s) called '{1}', so there is no occurrence {2} to act on." -f
                        @($matched).Count, $Name, $Occurrence))
        }

        return $matched[$Occurrence - 1]
    }

    if (@($matched).Count -gt 1) {
        throw (New-HDTErrorRecord -Path $Name -Category InvalidArgument `
                -Message ("this task sequence holds {0} steps called '{1}', so the one to act on is ambiguous. Say which with -Occurrence, or rename one of them." -f
                    @($matched).Count, $Name))
    }

    return $matched[0]
}
