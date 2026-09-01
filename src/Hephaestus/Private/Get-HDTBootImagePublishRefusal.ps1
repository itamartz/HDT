function Get-HDTBootImagePublishRefusal {
    <#
        .SYNOPSIS
            What a technician reads when a boot image builds and then cannot be
            renamed over the artifact it replaces.

        .DESCRIPTION
            THE BUILD SUCCEEDED AND THE RENAME DID NOT, and those are two very
            different things to be told. Update-HDTBootImage does every expensive
            part of its work into staging names - <name>.wim.new and
            <name>.iso.new - and publishes by renaming them over the artifacts a
            technician boots. Everything up to that point can be perfect and the
            last two lines can still fail.

            WHAT IT SAID BEFORE THIS EXISTED was the filesystem's own sentence:

                Exception calling "MoveItem" with "2" argument(s): "... Cannot
                create a file when that file already exists."

            measured on this lab on 2026-09-02. The cause was a running virtual
            machine with Boot\HDTPE_x64.iso in its DVD drive. Move-Item -Force
            deletes the destination before renaming; the delete failed because
            the file was open; the rename that followed then found the file still
            there and reported THAT. So the message named the second symptom of
            the first symptom of the actual cause, and named the cause nowhere.

            THE RECOVERY IS A RENAME, NOT A REBUILD, which is the half that saves
            the six minutes. Both artifacts are on disk, finished, under their
            staging names. Close whatever holds the file and move them into
            place - or run the build again, which will simply rewrite what is
            already there. A technician who is not told this runs the build
            again, because that is what you do with a failed build.

            IT OFFERS A LIKELY CAUSE AND DOES NOT ASSERT ONE. Nothing here can
            see which process holds a handle, and a message that named one would
            be wrong the first time the cause was a permission or a full disk.
            The underlying error travels intact for exactly that case.

        .PARAMETER Path
            The artifact that could not be replaced.

        .PARAMETER Staged
            The staging file holding the finished build.

        .PARAMETER Reason
            The underlying exception message, carried through rather than
            replaced.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - one sentence-per-fact refusal.

        .EXAMPLE
            Get-HDTBootImagePublishRefusal -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.iso' -Staged 'C:\HDTLab\Share\Boot\HDTPE_x64.iso.new' -Reason 'Cannot create a file when that file already exists.'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Staged,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Reason
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return ("the boot image was built but '{0}' could not be replaced: {1}. The build itself succeeded and is complete in '{2}' - the usual cause is that the file is open somewhere, and in a lab that is a virtual machine holding the ISO in its DVD drive. Close whatever has it, then rename the staging file over it or run this build again." -f
        $Path, $Reason, $Staged)
}
