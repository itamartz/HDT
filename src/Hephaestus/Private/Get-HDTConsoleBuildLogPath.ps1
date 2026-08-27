function Get-HDTConsoleBuildLogPath {
    <#
        .SYNOPSIS
            Where the boot image build's log is written, so the window's Open Log
            button has something to open.

        .DESCRIPTION
            THE LOG LIVED IN THE LIST AND NOWHERE ELSE. Every line the build
            reported was in a WPF ItemsControl and was thrown away when the
            window closed - so the record of what a build did, including the one
            that failed, existed only while somebody was looking at it.

            BESIDE THE MANIFEST, because they describe the same build and a
            technician looking for one finds the other. Boot\ already holds the
            image, the ISO and the manifest; this is the fourth file of the set
            and sorts with them.

            NAMED FOR THE IMAGE AND NOT FOR THE RUN. One file per boot image,
            overwritten by each build, which is what somebody means by "the log"
            - the last build's. A dated file per run would make Boot\ grow
            without bound on a share nobody prunes, and the manifest beside it
            already carries the build id if a particular run has to be pinned.

        .PARAMETER WorkspaceRoot
            The deployment share's root.

        .PARAMETER Name
            The boot image's name, as workspace.yaml gives it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleBuildLogPath -WorkspaceRoot 'C:\HDTLab\Share' -Name 'HDTPE_wiz_x64'

            C:\HDTLab\Share\Boot\HDTPE_wiz_x64.build.log
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $Name = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A BUILD THAT FAILED BEFORE READING THE DOCUMENT HAS NO IMAGE NAME, and
    # that is exactly the build whose log is worth keeping. It gets one anyway.
    $leaf = $Name
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'bootimage' }

    $folder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Boot

    return [string] [System.IO.Path]::Combine($folder, ('{0}.build.log' -f $leaf))
}
