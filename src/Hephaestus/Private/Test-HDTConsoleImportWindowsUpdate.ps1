function Test-HDTConsoleImportWindowsUpdate {
    <#
        .SYNOPSIS
            Whether the Import Windows Update dialog's answers can be imported,
            and what to say when they cannot.

        .DESCRIPTION
            THE DIALOG SHOWS THIS; IT DOES NOT DECIDE IT. Deciding is a decision
            and decisions are unit tested, which is the same split every other
            console dialog uses - the window is branch-free because nothing in it
            chooses anything.

            IT SUGGESTS AN ID RATHER THAN REQUIRING ONE, and the suggestion comes
            from the KB in the file name. THIS IS THE ONE PLACE A FILE NAME IS
            READ, and it is worth being clear about why that is not a
            contradiction: the id is a folder name, a label, something an
            administrator can overtype, and it is only a first guess offered
            before the package has been opened. The KB actually recorded in
            update.yaml is read out of the package's own metadata by
            Import-HDTWindowsUpdate, which overwrites this guess. A suggestion is
            allowed to be wrong; a catalog entry is not.

            A RELEASE IS REQUIRED AND HAS NO DEFAULT. Defaulting it to the first
            row would mean an administrator who did not read the field imports
            a server update under a client release, which is the exact mistake
            nothing downstream can detect - both packages share a build, an
            architecture and a baseline.

        .PARAMETER Workspace
            The share being imported into.

        .PARAMETER Path
            The .msu the dialog is pointed at.

        .PARAMETER Release
            The release chosen, or empty when none has been.

        .PARAMETER Id
            The id typed, or empty to take the suggestion.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with CanImport, Message,
            Path and SuggestedId.

        .EXAMPLE
            Test-HDTConsoleImportWindowsUpdate -Workspace 'C:\HDTLab\Share' -Path 'D:\kb5094126.msu' -Release 'Win11-24H2'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [string] $Release = '',

        [Parameter(Position = 3)]
        [AllowEmptyString()]
        [string] $Id = '',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # A FIRST GUESS ONLY - see the description. Import-HDTWindowsUpdate reads the
    # real KB out of the package and that is what reaches update.yaml.
    $suggested = ''
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $kb = [string] ([regex]::Match([System.IO.Path]::GetFileName($Path), '(?i)KB\d+').Value).ToUpperInvariant()

        if (-not [string]::IsNullOrWhiteSpace($kb)) {
            $architecture = 'x64'
            if ([System.IO.Path]::GetFileName($Path) -match '(?i)(x86|arm64)') {
                $architecture = ([string] $Matches[1]).ToLowerInvariant()
            }

            $suggested = '{0}-{1}' -f $kb, $architecture
        }
    }

    $chosen = $Id
    if ([string]::IsNullOrWhiteSpace($chosen)) { $chosen = $suggested }

    $folder = ''
    if (-not [string]::IsNullOrWhiteSpace($chosen)) {
        $folder = Get-HDTWorkspacePath -Root $Workspace -Kind WindowsUpdates -ChildPath $chosen
    }

    $answer = [pscustomobject] @{
        CanImport   = $false
        Message     = ''
        Path        = $folder
        SuggestedId = $suggested
    }

    # A BOX NOBODY HAS FILLED IN YET IS NOT A REFUSAL, and it does not get a
    # message. Import is simply not offered; what a box is FOR is on its hint,
    # and the message line is for what is WRONG.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $answer }

    if (-not $FileSystem.TestPath($Path)) {
        $answer.Message = 'That file does not exist.'
        return $answer
    }

    # A FOLDER IS THE MISTAKE MDT'S OWN WIZARD INVITES, because MDT's Import OS
    # Packages takes a folder and imports every .cab in it. Saying so beats
    # "that file does not exist", which is what a folder would otherwise get.
    if (-not [System.IO.Path]::GetExtension($Path)) {
        $answer.Message = 'Choose the .msu itself, not the folder holding it.'
        return $answer
    }

    $extension = [System.IO.Path]::GetExtension($Path)
    if (-not ($extension -match '(?i)^\.(msu|cab)$')) {
        $answer.Message = ("'{0}' is not an update package. Windows updates are .msu files." -f $extension)
        return $answer
    }

    if ([string]::IsNullOrWhiteSpace($Release)) {
        # NOT AN ERROR MESSAGE, BECAUSE NOTHING IS WRONG YET - the field simply
        # has not been answered, and its hint says what it is for.
        return $answer
    }

    if ([string]::IsNullOrWhiteSpace($chosen)) {
        $answer.Message = 'No KB number could be read from that file name, so an id has to be typed.'
        return $answer
    }

    if ($chosen -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        $answer.Message = 'An id starts with a letter or digit and holds only letters, digits, dot, dash and underscore.'
        return $answer
    }

    $catalogPath = Get-HDTWorkspacePath -Root $Workspace -Kind WindowsUpdates -ChildPath $chosen, 'update.yaml'

    if ($FileSystem.TestPath($catalogPath)) {
        $answer.Message = ("An update with the id '{0}' is already on this share." -f $chosen)
        return $answer
    }

    $answer.CanImport = $true
    return $answer
}
