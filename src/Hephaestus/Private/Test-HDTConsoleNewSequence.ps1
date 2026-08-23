function Test-HDTConsoleNewSequence {
    <#
        .SYNOPSIS
            Whether a new task sequence can be created with this id and name.

        .DESCRIPTION
            THE REFUSALS New-HDTTaskSequence WOULD MAKE, MADE ON THE PAGE. That
            command refuses an id this workspace already has, at the moment it
            would write; a wizard that only found out then is a wizard that fails
            on its last press, after every other answer has been given.

            IT ALSO REFUSES AN ID A FOLDER CANNOT CARRY. The id IS the folder
            name - TaskSequences\<id>\sequence.yaml - so a backslash or a colon
            in it is a path, not a name, and the failure it produces names a
            directory nobody typed.

            IT IS A QUERY, AND IT WRITES NOTHING. The window calls it on every
            keystroke to light or dark the Create button.

        .PARAMETER Workspace
            The deployment share's root.

        .PARAMETER Id
            The proposed id, which is also the folder name.

        .PARAMETER Name
            The proposed name.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with CanCreate, Message
            and Path.

        .EXAMPLE
            Test-HDTConsoleNewSequence -Workspace C:\HDTLab\Share -Id WIN11 -Name 'Windows 11'
    #>
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

    $path = Join-Path -Path (Join-Path -Path (Join-Path -Path $Workspace -ChildPath 'TaskSequences') `
            -ChildPath $Id) -ChildPath 'sequence.yaml'

    $refuse = {
        param([string] $Message)

        return [pscustomobject] @{
            CanCreate = $false
            Message   = $Message
            Path      = $path
        }
    }

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return (& $refuse 'A task sequence needs an id. It is the folder name, and it is what a rule or a boot image names to select this sequence.')
    }

    # THE ID IS A FOLDER NAME. A backslash or a colon in it is a path rather
    # than a name, and the failure it produces names a directory nobody typed.
    if ($Id -match '[\\/:*?"<>|]' -or $Id -match '\s') {
        return (& $refuse ("'{0}' cannot be a folder name. An id has no spaces and none of \\ / : * ? "" < > |." -f $Id))
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return (& $refuse 'A task sequence needs a name. It is what the console and the deployment wizard show; the id is what selects it.')
    }

    if ($FileSystem.TestPath($path)) {
        return (& $refuse ("this workspace already has a task sequence called '{0}'. Choose another id, or remove that one first." -f $Id))
    }

    return [pscustomobject] @{
        CanCreate = $true
        Message   = ''
        Path      = $path
    }
}
