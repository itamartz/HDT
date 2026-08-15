function Resolve-HDTConsoleStepBlock {
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
            ambiguous disk (DESIGN 9.1), for the same reason.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to find.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - one block from
            Get-HDTConsoleStepBlock.

        .EXAMPLE
            Resolve-HDTConsoleStepBlock -Line $line -Name 'Apply OS'
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

    $block = @(Get-HDTConsoleStepBlock -Line $Line)
    $matched = @($block | Where-Object { $_.Name -eq $Name })

    if (@($matched).Count -eq 0) {
        throw (New-HDTConsoleErrorRecord -Path $Name -Category ObjectNotFound `
                -Message ("there is no step or group called '{0}' in this task sequence." -f $Name))
    }

    if (@($matched).Count -gt 1) {
        throw (New-HDTConsoleErrorRecord -Path $Name -Category InvalidArgument `
                -Message ("this task sequence holds {0} steps called '{1}', so the one to act on is ambiguous. Rename one of them first." -f @($matched).Count, $Name))
    }

    return $matched[0]
}
