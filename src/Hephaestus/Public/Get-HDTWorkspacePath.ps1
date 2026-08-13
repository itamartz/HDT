function Get-HDTWorkspacePath {
    <#
        .SYNOPSIS
            Builds a path to a folder inside an HDT workspace.

        .DESCRIPTION
            The workspace layout in DESIGN 2.1 is fixed, and every component that
            reads or writes the share has to agree on it. This command is the one
            place the folder names are written down in code.

            It exists because they were not. Start-HDTResume.ps1 built its
            sequence path from the literal 'Sequences' while the documents, the
            sample tree and the sequence flattener all said 'TaskSequences'. The
            unit suite was green: nothing in it resolved a real workspace path.
            A deployment would have died at its first reboot, unable to find the
            sequence it was halfway through.

            Passing a folder name that is not part of the layout is an error
            rather than a path, so a typo fails where it is made instead of
            surfacing later as a missing file.

        .PARAMETER Root
            The workspace root - a local path or a UNC share.

        .PARAMETER Kind
            The top-level folder, from the DESIGN 2.1 layout.

        .PARAMETER ChildPath
            Further segments beneath the folder, appended in order.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTWorkspacePath -Root '\\server\HdtShare' -Kind TaskSequences

            Returns \\server\HdtShare\TaskSequences.

        .EXAMPLE
            Get-HDTWorkspacePath -Root 'X:\Deploy' -Kind TaskSequences -ChildPath 'STD-CLIENT', 'sequence.yaml'

            Returns the sequence document for the STD-CLIENT task sequence.

        .EXAMPLE
            Get-HDTWorkspacePath -Root $deployRoot -Kind Logs -ChildPath $env:COMPUTERNAME

            Returns this machine's log folder on the share.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        # The set is closed on purpose: an unknown folder is a defect, not a path.
        [Parameter(Mandatory = $true)]
        [ValidateSet('TaskSequences', 'OperatingSystems', 'Applications', 'Drivers',
            'Boot', 'Logs', 'Captures', 'Control', 'Scripts', 'Modules')]
        [string] $Kind,

        [Parameter()]
        [AllowNull()]
        [string[]] $ChildPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # [IO.Path]::Combine, not Join-Path. Join-Path resolves the drive qualifier
    # and throws "Cannot find drive" for a drive that is not currently mounted -
    # but a workspace root is routinely a share or a volume that does not exist
    # in the session doing the building (an admin authoring on a workstation, a
    # test naming X:\ outside WinPE). Building a path must not require the path
    # to exist.
    $path = [System.IO.Path]::Combine($Root, $Kind)

    if ($null -ne $ChildPath) {
        foreach ($segment in $ChildPath) {
            if ([string]::IsNullOrWhiteSpace($segment)) {
                continue
            }

            # A rooted segment makes Combine discard everything to its left, so a
            # stray leading separator would silently return the segment alone.
            $path = [System.IO.Path]::Combine($path, $segment.TrimStart('\', '/'))
        }
    }

    return $path
}
