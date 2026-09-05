function Get-HDTUpdateResultName {
    <#
        .SYNOPSIS
            What a Windows Update Agent operation result code means, in words.

        .DESCRIPTION
            CLAUDE.md's logging rule, applied to the one number the agent
            answers every download and install with: "log the command AND its
            exit code AND what that code means". A line reading "result code 4"
            makes an administrator look up an enumeration before they can read
            their own deployment log; "result code 4 (failed)" does not, and
            they are reading it a week later on a machine they cannot touch.

            The set is WUA's OperationResultCode, and it is closed at six:

              0  not started            the operation never began
              1  in progress            it is still running - which a
                                        SYNCHRONOUS Install() should never
                                        return, so seeing it in a log is itself
                                        the finding
              2  succeeded              the only success
              3  succeeded with errors  part of the batch went in. NOT a
                                        success: the step installs one update at
                                        a time precisely so this is
                                        unambiguous, and a caller treating 3 as
                                        success is how a half-installed
                                        cumulative update gets reported green
              4  failed
              5  aborted                stopped, usually by a shutdown arriving
                                        mid-install

            A CODE OUTSIDE THE SET IS STILL REPORTED, by number. Returning an
            empty string would put "result code 9 ()" into the one line the
            administrator is relying on, which is worse than an unfamiliar
            number: it looks like the log is broken rather than like the agent
            said something new.

        .PARAMETER ResultCode
            The agent's OperationResultCode.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTUpdateResultName -ResultCode 4

            failed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [int] $ResultCode
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $name = @{
        0 = 'not started'
        1 = 'in progress'
        2 = 'succeeded'
        3 = 'succeeded with errors'
        4 = 'failed'
        5 = 'aborted'
    }

    if ($name.ContainsKey($ResultCode)) { return [string] $name[$ResultCode] }

    return ('an unknown result code, {0}' -f $ResultCode)
}
