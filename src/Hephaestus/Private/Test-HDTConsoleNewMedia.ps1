function Test-HDTConsoleNewMedia {
    <#
        .SYNOPSIS
            Whether a new media definition can be created with this id and
            name.

        .DESCRIPTION
            THE REFUSALS New-HDTMedia WOULD MAKE, MADE ON THE PAGE. That
            command refuses an id it cannot use as a folder name, and an id
            this share already has a Media\<id>\media.yaml for, at the moment
            it would write - a dialog that only found out then is a wizard
            that fails on its last press, after every other answer has been
            given.

            THE ID PATTERN IS New-HDTMedia's OWN, copied rather than
            reinvented: '^[A-Za-z0-9][A-Za-z0-9_.-]*$'. A dialog that accepted
            an id the command then refused would be a wizard whose last press
            fails for a reason the page never named.

            IT IS A QUERY, AND IT WRITES NOTHING. The window calls it on every
            keystroke to light or dark the Create button.

        .PARAMETER Workspace
            The deployment share's root.

        .PARAMETER Id
            The proposed id, which is also the folder name under Media\.

        .PARAMETER Name
            The proposed name.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with CanCreate,
            Message and Path.

        .EXAMPLE
            Test-HDTConsoleNewMedia -Workspace C:\HDTLab\Share -Id WIN11-FIELD -Name 'Windows 11 field media'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Media is a mass noun here and the singular name of one object, matching New-HDTMedia (DESIGN 6.2) and the dialog this answers for. The analyzer reads it as the Latin plural of medium.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Id,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $path = Get-HDTWorkspacePath -Root $Workspace -Kind Media -ChildPath $Id, 'media.yaml'

    $refuse = {
        param([string] $Message)

        return [pscustomobject] @{
            CanCreate = $false
            Message   = $Message
            Path      = $path
        }
    }

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return (& $refuse 'A media definition needs an id. It is the folder name under Media\, and it is what Remove-HDTMedia and Update-HDTMediaContent name to select this one.')
    }

    # NEW-HDTMEDIA'S OWN PATTERN, COPIED RATHER THAN INVENTED. A looser check
    # here would accept an id the command then refuses on its last press.
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        return (& $refuse ("'{0}' is not a legal media id. An id is a folder name under Media\: it starts with a letter or a digit and holds only letters, digits, underscore, dot and hyphen - no separators, no spaces." -f $Id))
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return (& $refuse 'A media definition needs a name. It is what the console''s Media node and a build log show; the id is what selects it.')
    }

    if ($FileSystem.TestPath($path)) {
        return (& $refuse ("this share already has a media definition called '{0}'. Choose another id, or edit that one with Set-HDTMedia." -f $Id))
    }

    return [pscustomobject] @{
        CanCreate = $true
        Message   = ''
        Path      = $path
    }
}
