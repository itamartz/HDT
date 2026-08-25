function Get-HDTSelectionProfileContentFolder {
    <#
        .SYNOPSIS
            The share folders a selection profile may include from.

        .DESCRIPTION
            A SUBSET OF Get-HDTWorkspacePath's KINDS, and the difference is the
            whole point. These five are what an administrator authors content
            into; the rest of the layout is either generated, written to during a
            deployment, or this document's own home:

              Boot\      is what a build WRITES. A profile including it would
                         project this build's own output into its own input.
              Logs\      and Captures\ are the only two folders a deployment is
                         allowed to write to (DESIGN 2.1). They hold other
                         machines' logs and other machines' images.
              Control\   holds selection-profiles.yaml itself, so including it is
                         circular.
              Modules\   is the engine payload. It is staged unconditionally;
                         choosing it is not a choice anybody has.

            This is also the list MDT's own profile tree shows - Applications,
            Operating Systems, Out-of-Box Drivers, Packages, Task Sequences -
            with Scripts\ added because HDT stages user extension points from it
            and standalone media has to be able to carry them.

            IT IS THE ORDER THE CONSOLE'S TREE DRAWS IN, so it is authored order
            rather than alphabetical: content an administrator picks most often
            first.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the folder names, which are also the legal first
            segment of an include path.

        .EXAMPLE
            Get-HDTSelectionProfileContentFolder

        .LINK
            Get-HDTWorkspacePath
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @('Applications', 'OperatingSystems', 'Drivers', 'TaskSequences', 'Scripts')
}
