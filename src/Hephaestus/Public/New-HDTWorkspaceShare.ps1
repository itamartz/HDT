function New-HDTWorkspaceShare {
    <#
        .SYNOPSIS
            Publishes a deployment share's folder over SMB, and answers with the
            deploy root that reaches it.

        .DESCRIPTION
            THE HALF MDT'S WIZARD DOES AND HDT'S DID NOT. New Deployment Share
            asks for a folder and a share name, creates the share, and derives
            DeployRoot from it. Until this existed the console asked for the UNC
            instead - a box somebody typed a path into, naming a share nothing
            had created, which is a boot image that fails at the Welcome screen.

            IT CHANGES THE MACHINE, WHICH IS WHY IT IS NOT New-HDTWorkspace.
            Writing a folder of YAML and publishing an SMB share are different
            kinds of act - the first needs nothing, the second needs elevation
            and alters what the network can reach - and a command that did both
            could not be run twice, nor run at all by somebody without rights.

            ELEVATION IS SAID, NOT THROWN. Creating a share without it fails
            inside the SmbShare module with an access error naming a CIM class;
            this checks first and says which console to reopen - and says it
            before the folder's name is even judged, because "reopen elevated"
            is the whole answer and a share name complaint on top of it is
            noise.

            THE ACL MATTERS MORE HERE THAN IN MDT. Control\share-credential.json
            is obfuscated rather than encrypted, so read access to this share is
            the deployment account. -Account grants read to one account and
            nothing else; without it the share is created with no grant at all
            and the administrator sets it, which is the safe default because it
            reaches nobody until somebody decides who.

            IT IS NOT A REPAIR. A name already published on this machine is
            refused, naming it, rather than reconfigured - somebody else's share
            is not this command's to change.

        .PARAMETER Path
            The folder to publish. It is not created here: New-HDTWorkspace
            writes it, and this publishes what is there.

        .PARAMETER ShareName
            The name to publish under. Omitted, the folder's leaf with a dollar.

        .PARAMETER ServerName
            The machine the deploy root should name. Defaults to this one.

        .PARAMETER Account
            An account to grant read access to - the deployment account. Omitted,
            no access is granted and the share reaches nobody until somebody
            decides who.

        .PARAMETER Description
            What the share is called in the share list.

        .PARAMETER SmbService
            An ISmbService. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem, which is what writes the NTFS half of the ACL.
            Defaults to the real one.

        .PARAMETER Elevated
            Whether this process can publish a share. Defaults to what
            Test-HDTElevation answers; passed explicitly, the refusal can be
            proved without a second process.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with ShareName, Path and
            DeployRoot.

        .EXAMPLE
            New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -Account 'LAP-AMMSO01\svc-hdt-deploy'

            Publishes the folder over SMB and gives the deployment account read access.
            A share a booted machine cannot read is a deployment that stops at the
            first file.

        .EXAMPLE
            New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -Account 'LAP-AMMSO01\svc-hdt-deploy' -WhatIf

            Describes the share and the rule it would add, and publishes nothing.

        .LINK
            New-HDTWorkspace

        .LINK
            Get-HDTWorkspaceShareName
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $ShareName = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $ServerName = [System.Environment]::MachineName,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Account = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Description = 'HDT deployment share',

        [Parameter()]
        [AllowNull()]
        [object] $SmbService,

        # DEFAULTED, NOT MANDATORY, on New-HDTWorkspace's reasoning: this is a
        # command an administrator types, so a working call is a short one. It is
        # here because the NTFS half of the ACL below is a filesystem act rather
        # than an SMB one, and putting it on ISmbService would have made the
        # service lie about what it is. A test passes the fake, and must.
        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem),

        # WHETHER THIS PROCESS CAN PUBLISH ONE AT ALL. Taken as a parameter
        # rather than asked here, so the refusal is provable without a second
        # process and a UAC prompt - Test-HDTElevation is the adapter that asks.
        [Parameter()]
        [bool] $Elevated = (Test-HDTElevation)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $SmbService) { $SmbService = New-HDTSmbService }

    # ELEVATION FIRST, BEFORE ANYTHING IS SAID ABOUT NAMES. Without it
    # New-SmbShare fails inside the SmbShare module with an access error naming
    # a CIM class, which tells a technician nothing about what to do - and it
    # fails AFTER the folder has been written, so the share is the only half
    # missing and nothing says which half.
    if (-not $Elevated) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path -Category PermissionDenied `
                    -Message 'publishing a folder over SMB needs administrator rights, and this console does not have them. Close it and reopen it as an administrator - right-click, Run as administrator - or create the share yourself and set the deploy root on the share''s properties. The folder itself is already written either way.'))
    }

    $decided = Get-HDTWorkspaceShareName -Path $Path -ShareName $ShareName -ServerName $ServerName

    if (-not $decided.IsValid) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $ShareName -Category InvalidArgument `
                    -Message ([string] $decided.Message)))
    }

    # ALREADY PUBLISHED IS NOT THIS COMMAND'S TO CHANGE.
    if ($SmbService.GetShare([string] $decided.ShareName)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $decided.ShareName -Category ResourceExists `
                    -Message ("'{0}' is already a share on {1}. Choose another name, or point the deploy root at the share that is already there - the folder itself is untouched either way." -f
                        $decided.ShareName, $ServerName)))
    }

    if (-not $PSCmdlet.ShouldProcess(
            ('{0} as \\{1}\{2}' -f $Path, $ServerName, $decided.ShareName),
            'Publish this folder over SMB')) {

        return [pscustomobject] @{
            ShareName  = [string] $decided.ShareName
            Path       = $Path
            DeployRoot = [string] $decided.DeployRoot
        }
    }

    $SmbService.NewShare($Path, [string] $decided.ShareName, $Description)

    # BOTH ACLS, OR NEITHER. SMB gates the connection and NTFS gates the file,
    # and the effective right is the more restrictive of the two - so granting
    # the share half alone produces a share the deployment account can reach and
    # cannot read, which is precisely what Test-HDTShareAcl then reports as
    # Critical at the root. Until this existed the NTFS half lived in three
    # icacls lines in docs/share-account.md that this command never ran, and an
    # administrator who followed the command rather than the document got a boot
    # image that failed at the Welcome screen.
    #
    # NO ACCOUNT, NO GRANT, on either. A share created with nobody named reaches
    # nobody until an administrator decides who, and writing an NTFS row for an
    # account nobody gave would be deciding that for them.
    if (-not [string]::IsNullOrWhiteSpace($Account)) {
        $SmbService.GrantShareAccess([string] $decided.ShareName, $Account, 'Read')

        # READ ON THE TREE, MODIFY ON EXACTLY TWO FOLDERS. That is the posture
        # docs/share-account.md sets out and Test-HDTShareAcl judges: the account
        # reads everything it deploys, writes only where the deployment sends its
        # logs home and lands a capture, and holds FullControl nowhere.
        #
        # Logs\ and Captures\ come after the root on purpose - the root grant is
        # inherited by the tree, so a Modify written first would be flattened
        # back to Read by the one that follows it.
        $FileSystem.GrantAccess($Path, $Account, 'Read')

        foreach ($writable in @('Logs', 'Captures')) {
            $FileSystem.GrantAccess(
                [System.IO.Path]::Combine($Path, $writable), $Account, 'Modify')
        }
    }

    return [pscustomobject] @{
        ShareName  = [string] $decided.ShareName
        Path       = $Path
        DeployRoot = [string] $decided.DeployRoot
    }
}
