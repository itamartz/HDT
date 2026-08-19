function Get-HDTWorkspaceShareName {
    <#
        .SYNOPSIS
            The share name a deployment share should be published under, and the
            deploy root that follows from it.

        .DESCRIPTION
            A DEPLOYMENT SHARE IS A SHARE. MDT's New Deployment Share wizard
            asks for a folder AND a share name, creates the SMB share, and
            Bootstrap.ini's DeployRoot is \\<server>\<share> derived from the
            two. HDT asked for the UNC instead - a box somebody filled in by
            hand, naming a share nothing had created.

            THE SERVER IS THE COMPUTER NAME, NOT AN IP ADDRESS, and this
            repository has the argument written down twice: a lab host's address
            is a DHCP lease that moves when somebody changes the Wi-Fi, and
            DeployRoot is baked into the boot image. A name survives what an
            octet does not. MDT derives \\%servername%\Share$ for exactly this
            reason.

            THE DOLLAR IS NOT DECORATION. MDT's default share name ends in one,
            which keeps it out of network browsing - and a deployment share
            holds Control\share-credential.json, which is obfuscated rather than
            encrypted. A name given without one gets one.

            IT DECIDES; IT DOES NOT PUBLISH. Creating the share is
            New-HDTWorkspaceShare's job, through an injected ISmbService. This
            is the decision that command and the New Deployment Share dialog
            both read, which is why it can be asserted with no SMB stack at all.

        .PARAMETER Path
            The folder the share is over. Its leaf is the suggested share name.

        .PARAMETER ShareName
            The name to publish under. Omitted, the folder's leaf is used.

        .PARAMETER ServerName
            The machine the share lives on, as it will be WRITTEN into the
            deploy root. Defaults to this one.

            NOT -ComputerName, deliberately: nothing here connects to anything,
            and a parameter by that name reads as a remoting target - the
            analyzer says so too, since every call with a literal is a finding
            about exposing a machine name.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with ShareName,
            DeployRoot, IsValid and Message.

        .EXAMPLE
            Get-HDTWorkspaceShareName -Path 'C:\HDTLab\Share'

            Share$ on this machine, and \\<thismachine>\Share$.

        .LINK
            New-HDTWorkspaceShare
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $ShareName = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $ServerName = [System.Environment]::MachineName
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $wanted = $ShareName.Trim()

    if ([string]::IsNullOrWhiteSpace($wanted) -and -not [string]::IsNullOrWhiteSpace($Path)) {
        $wanted = [System.IO.Path]::GetFileName($Path.TrimEnd('\', '/'))
    }

    $answer = [pscustomobject] @{
        ShareName  = ''
        DeployRoot = ''
        IsValid    = $false
        Message    = ''
    }

    if ([string]::IsNullOrWhiteSpace($wanted)) { return $answer }

    # HIDDEN BY DEFAULT, which is MDT's default and the right one here.
    if (-not $wanted.EndsWith('$')) { $wanted = '{0}$' -f $wanted }

    $answer.ShareName = $wanted

    # WHAT WINDOWS ACCEPTS AS A SHARE NAME: no path separators, no spaces, none
    # of the reserved characters, and 80 characters at most. Checked here rather
    # than left to New-SmbShare, whose refusal names a parameter.
    $bare = $wanted.TrimEnd('$')

    if ($wanted.Length -gt 80 -or $bare -notmatch '^[A-Za-z0-9._-]+$') {
        $answer.Message = "'{0}' is not a share name. It is letters, digits, dot, dash and underscore - no spaces and no backslashes - up to 80 characters, ending in `$ so it does not appear in network browsing." -f $ShareName
        return $answer
    }

    if ([string]::IsNullOrWhiteSpace($ServerName)) {
        # A DEPLOY ROOT WITH AN EMPTY SERVER IN IT is the shape that reaches the
        # boot image and fails at the Welcome screen, hours later.
        $answer.Message = 'this machine did not say what it is called, so the deploy root cannot be worked out. Type one on the share''s properties instead.'
        return $answer
    }

    $answer.DeployRoot = '\\{0}\{1}' -f $ServerName, $wanted
    $answer.IsValid = $true

    return $answer
}
