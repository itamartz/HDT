function Get-HDTErrorSummary {
    <#
        .SYNOPSIS
            One line naming what actually failed and where.

        .DESCRIPTION
            THE HUMAN HALF OF Get-HDTErrorDetail. The JSONL record carries the
            whole diagnostic set - every exception layer, the position message,
            the stack trace - and this is what goes in the `message` field, which
            is also what the CMTrace twin shows.

            ONE LINE, ON PURPOSE, AND IT IS THE ONE EXCEPTION TO "write too
            much". HDT.log is read by eye in a viewer with one row per record, so
            a stack trace pasted into the middle of it does not add detail, it
            destroys the ability to scan the file at all. The detail is not
            dropped - it is one field away, in the same record's data.

            IT NAMES THE CAUSE, NOT THE SYMPTOM. The innermost exception message
            and the innermost type, then the file and line. What it deliberately
            does NOT lead with is the outermost wrapper, which on the failure
            that prompted this was "Exception calling "SetValue" with "4"
            argument(s)" - a sentence about PowerShell's method-call plumbing,
            offered in place of "Cannot delete a subkey tree".

        .PARAMETER ErrorRecord
            The ErrorRecord from a catch block.

        .PARAMETER Prefix
            What the sentence opens with. Defaults to 'The task sequence
            stopped', which is what the engine's own catch says.

        .OUTPUTS
            System.String, always a single line.

        .EXAMPLE
            Get-HDTErrorSummary -ErrorRecord $_ -Prefix ("step {0} failed" -f $index)

            step 12 failed: Cannot delete a subkey tree because the subkey does
            not exist (System.ArgumentException at New-HDTRegistryService.ps1:214)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $ErrorRecord,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Prefix = 'The task sequence stopped'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $detail = Get-HDTErrorDetail -ErrorRecord $ErrorRecord

    # THE LEAF NAME, NOT THE PATH. The full path of a file inside a WinPE RAM
    # disk is long, changes between legs, and is in data.scriptName anyway; what
    # a reader needs on the line is which file and which line of it.
    $where = ''
    if (-not [string]::IsNullOrWhiteSpace([string] $detail['scriptName'])) {
        $where = '{0}:{1}' -f (Split-Path -Leaf ([string] $detail['scriptName'])), [int] $detail['scriptLineNumber']
    }

    # A cause with no location still reports the cause; a cause with no type
    # still reports the cause. Nothing about this line may depend on the failure
    # being well formed.
    $at = @($detail['exceptionType'], $where) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }

    $sentence = '{0}: {1}' -f $Prefix, [string] $detail['cause']
    if (@($at).Count -gt 0) {
        $sentence = '{0} ({1})' -f $sentence, (@($at) -join ' at ')
    }

    # NEWLINES ARE FLATTENED RATHER THAN TRUSTED. An exception message may carry
    # its own, and one physical line per record is what both JSON Lines and
    # CMTrace require.
    return (($sentence -replace '\r?\n', ' ') -replace '\s{2,}', ' ').Trim()
}
