function Test-HDTConsoleImportOperatingSystem {
    <#
        .SYNOPSIS
            Says whether the Import Operating System dialog's answers can be
            used, and why not when they cannot.

        .DESCRIPTION
            Import-HDTOperatingSystem refuses a bad id, a source that is not
            there and an id the share already has - but it refuses them at the
            END, after four boxes have been filled in and Import has been
            pressed. This asks the same questions WHILE they are typed, so the
            refusal appears beside the box that caused it and Import is simply
            not offered until it would work.

            IT DECIDES NOTHING THE IMPORT DOES NOT. Every rule here mirrors one
            in Import-HDTOperatingSystem. A rule that existed only in the dialog
            would be a rule the command line has not got, and the console would
            be describing a toolkit that does not exist (DESIGN 12).

            A BOX NOBODY HAS FILLED IN YET IS NOT A MISTAKE, and gets no
            message. A required box that is empty simply does not offer Import;
            what the box is FOR is on its hint, and the message line is for what
            is WRONG. A window that complains about work in progress teaches a
            technician that its message line is noise, and then the one that
            matters arrives in the same text as the ones that did not.

            THE EXCEPTION IS A SOURCE THAT WAS TYPED AND IS NOT THERE. That is
            wrong now rather than later, and it is the mistake somebody makes
            without noticing.

            THE ID IS SUGGESTED FROM THE MEDIA. MDT's import wizard fills the
            destination folder in from the source; an id is a folder name and
            the media is already in one, so 'C:\media\WS2025\sources\install.wim'
            offers WS2025 rather than asking somebody to invent a name.

        .PARAMETER Workspace
            The share's root.

        .PARAMETER Id
            The id typed so far. Becomes the folder under OperatingSystems\.

        .PARAMETER SourcePath
            The .wim or .ffu typed so far.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with CanImport, Message,
            Path and SuggestedId.

        .EXAMPLE
            Test-HDTConsoleImportOperatingSystem -Workspace 'C:\HDTLab\Share' -Id 'WS2025-Std' -SourcePath 'D:\sources\install.wim'

        .LINK
            Import-HDTOperatingSystem
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $Id = '',

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [string] $SourcePath = '',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # THE FOLDER THE MEDIA SITS IN, minus the sources\ Windows media always
    # keeps its image under - the folder above is the one named after the build.
    $suggested = ''

    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $holding = [System.IO.Path]::GetDirectoryName($SourcePath)

        if (-not [string]::IsNullOrWhiteSpace($holding)) {
            $leaf = [System.IO.Path]::GetFileName($holding.TrimEnd('\', '/'))

            if ([string]::Equals($leaf, 'sources', [System.StringComparison]::OrdinalIgnoreCase)) {
                $above = [System.IO.Path]::GetDirectoryName($holding)
                if (-not [string]::IsNullOrWhiteSpace($above)) {
                    $leaf = [System.IO.Path]::GetFileName($above.TrimEnd('\', '/'))
                }
            }

            if ($leaf -match '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { $suggested = $leaf }
        }
    }

    $folder = ''
    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        $folder = Join-Path -Path (Get-HDTWorkspacePath -Root $Workspace -Kind OperatingSystems) -ChildPath $Id
    }

    $answer = [pscustomobject] @{
        CanImport   = $false
        Message     = ''
        Path        = $folder
        SuggestedId = $suggested
    }

    # A BOX NOBODY HAS FILLED IN YET IS NOT A REFUSAL, and it does not get a
    # message. Both are required, so Import is not offered without them; but
    # what a box is FOR is on its hint, and this line is for what is WRONG.
    #
    # THE RED LINE HAS TO MEAN SOMETHING. A dialog that complains about work in
    # progress teaches a technician that its message line is noise, and then the
    # message that matters - media that is not there, an id the share already
    # has - arrives in the same colour as the ones that did not.
    if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($SourcePath)) {

        # ONE EXCEPTION: media that WAS typed and is not there is wrong now,
        # not later, and it is the mistake somebody makes without noticing.
        if (-not [string]::IsNullOrWhiteSpace($SourcePath) -and -not $FileSystem.TestPath($SourcePath)) {
            $answer.Message = "'{0}' is not there." -f $SourcePath
        }

        return $answer
    }

    if (-not $FileSystem.TestPath($SourcePath)) {
        $answer.Message = "'{0}' is not there." -f $SourcePath
        return $answer
    }

    # THE IMAGE LIST IS READ FROM THE FILE, so a folder or a setup.exe is an
    # import that dies at GetImageInfo - after the catalog folder has been made.
    $extension = [System.IO.Path]::GetExtension($SourcePath)

    if (@('.wim', '.ffu', '.esd') -notcontains $extension.ToLowerInvariant()) {
        $answer.Message = "'{0}' is not an image file. Choose the .wim or .ffu itself - on Windows media it is sources\install.wim." -f $SourcePath
        return $answer
    }


    # THE SAME PATTERN Import-HDTOperatingSystem ENFORCES.
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        $answer.Message = "'{0}' cannot be an id. It is a folder name: letters, digits, dot, dash and underscore, starting with a letter or a digit." -f $Id
        return $answer
    }

    if ($FileSystem.TestPath($folder)) {
        $answer.Message = "this share already has an operating system called '{0}'. Choose another id, or remove that one first." -f $Id
        return $answer
    }

    $answer.CanImport = $true

    return $answer
}
