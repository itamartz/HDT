function Resolve-HDTRuleBlock {
    <#
        .SYNOPSIS
            Finds the one rule a rules-editing cmdlet was asked to act on.

        .DESCRIPTION
            The lookup every editing cmdlet shares, so "no such rule" reads the
            same whichever command produced it and is written once.

            A NAME THAT IS NOT THERE IS AN ERROR, NOT A NO-OP. An edit that
            silently changed nothing would leave an administrator watching the
            file not change, with nothing to read.

            AN AMBIGUOUS NAME IS ALSO AN ERROR. Two rules may not share a name in
            a document the engine will load - provenance reports which rule set a
            variable, and two rules called Fallback make that answer meaningless -
            but a file being edited by hand can be in that state for a while, and
            the editor must not guess which of them was meant.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The rule to find.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - one block from
            Get-HDTRuleBlock.

        .EXAMPLE
            Resolve-HDTRuleBlock -Line $line -Name 'Fallback'
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
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $block = @(Get-HDTRuleBlock -Line $Line)
    $matched = @($block | Where-Object { $_.Name -eq $Name })

    if (@($matched).Count -eq 0) {
        throw (New-HDTErrorRecord -Path $Name -Category ObjectNotFound `
                -Message ("there is no rule called '{0}' in this rules document." -f $Name))
    }

    if (@($matched).Count -gt 1) {
        throw (New-HDTErrorRecord -Path $Name -Category InvalidArgument `
                -Message ("this document holds {0} rules called '{1}', so the one to act on is ambiguous. Rename one of them first." -f @($matched).Count, $Name))
    }

    return $matched[0]
}
