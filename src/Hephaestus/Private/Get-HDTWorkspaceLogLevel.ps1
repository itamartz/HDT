function Get-HDTWorkspaceLogLevel {
    <#
        .SYNOPSIS
            The levels a deployment share can log at, in order of severity.

        .DESCRIPTION
            ONE LIST, TWO READERS. Assert-HDTWorkspaceDocument refuses anything
            outside it, and the console's Log level row offers exactly it. Those
            were two hand-written copies of the same four words, which is the
            arrangement where a fifth level gets added to the validator and the
            list a technician picks from silently stays at four.

            THE SCHEMA IS STILL THE AUTHORITY. schemas/workspace.schema.json
            declares the enum and a contract test asserts this function matches
            it, so this is the runtime's copy of a decision made there rather
            than a second place the decision is taken.

            THE ORDER IS SEVERITY, LOUDEST FIRST, and it is the order the list
            is shown in. Alphabetical would put Debug at the top, which is the
            one level a share should not be left on.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the levels, most severe first.

        .EXAMPLE
            Get-HDTWorkspaceLogLevel

            Error, Warning, Info, Debug.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @('Error', 'Warning', 'Info', 'Debug')
}
