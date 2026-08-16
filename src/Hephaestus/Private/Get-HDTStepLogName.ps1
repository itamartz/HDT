function Get-HDTStepLogName {
    <#
        .SYNOPSIS
            Builds the numbered per-step log file name.

        .DESCRIPTION
            "Step files are numbered in execution order, so the directory listing
            itself tells you the sequence and where it stopped - the thing you
            want first when a deployment fails":

              Steps\001-Validate.log
              Steps\002-DiskPartition.log
              Steps\003-Apply-OS-index-3.log

            THE NUMBER COMES FROM THE EXECUTION INDEX, not from the document
            order, which is the same 1-based index the state document checkpoints
            against. Two steps sharing a name therefore still get distinct files,
            and the listing sorts into the order they ran.

            The name is made safe for a file system rather than trusted: every
            character outside A-Za-z0-9._- becomes a dash, runs of dashes
            collapse, leading and trailing dashes go, and the result is truncated
            to 40 characters. A step named 'A\B' must not be able to write
            outside the Steps directory, and a step named after a sentence must
            not produce a path longer than the API takes.

            A name that sanitises to nothing becomes 'step', because the index
            still has to be readable.

            It returns a FILE NAME, never a path. The caller joins it to
            <_HDTLogPath>\Steps, so this function needs no knowledge of where the
            logs live.

        .PARAMETER Index
            The 1-based execution index.

        .PARAMETER Name
            The step's name, as authored.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTStepLogName -Index 3 -Name 'Apply OS (index 3)'

            003-Apply-OS-index-3.log
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Index,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $safe = [regex]::Replace([string] $Name, '[^A-Za-z0-9._-]', '-')
    $safe = [regex]::Replace($safe, '-{2,}', '-')
    $safe = $safe.Trim('-')

    if ($safe.Length -gt 40) {
        $safe = $safe.Substring(0, 40).Trim('-')
    }

    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'step'
    }

    return ('{0:000}-{1}.log' -f $Index, $safe)
}
