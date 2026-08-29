function Get-HDTValidateCheckResultName {
    <#
        .SYNOPSIS
            The closed set of verdicts a pre-flight check can carry.

        .DESCRIPTION
            THE VERDICT IS A VOCABULARY, NOT PROSE, for the reason Write-HDTLog's
            event names are: the Deployment Summary window colours these and a
            report counts them, and both do it by matching a known set rather
            than by reading a sentence.

            Five, and what separates them:

              pass      the check was made and the machine met it
              fail      the check was made and the machine did not - the run stops
              warn      the machine was accepted, and something about it was
                        recorded anyway
              skipped   the sequence did not ask for this check. It is REPORTED
                        rather than omitted, because a check absent from the log
                        and a check that passed look identical to a reader, and
                        the whole point of the enumeration is that an
                        administrator can learn what HDT checks without failing it
              excluded  a disk that cannot be the deployment target. Not a
                        failure: excluding four disks to arrive at one is the
                        step working

            MDT DRAWS THE SAME LINE between skipped and warned. ZTIValidate logs
            "OSInstall flag is not set, validation check bypassed." at Info and
            "WARNING - Cannot determine image size, guessing 7GB" at Warning: a
            check deliberately not made is information, a check that could not be
            made is a warning.

            A SIXTH NAME ADDED HERE WITHOUT A RENDERING is a verdict nothing
            displays, so a test holds this list against the ones the step emits.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Get-HDTValidateCheckResultName
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @('pass', 'fail', 'warn', 'skipped', 'excluded')
}
