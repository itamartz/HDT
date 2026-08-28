function Test-HDTConsoleImportApplication {
    <#
        .SYNOPSIS
            Says whether the New Application dialog's answers can be used, and
            why not when they cannot.

        .DESCRIPTION
            Import-HDTApplication refuses a bad id, a source that is not there
            and an id the share already has - but it refuses them at the END,
            after four boxes have been filled in and Import has been pressed.
            This asks the same questions WHILE they are typed, so the refusal
            appears beside the box that caused it and Import is simply not
            offered until it would work.

            IT DECIDES NOTHING THE IMPORT DOES NOT. Every rule here mirrors one
            in Import-HDTApplication. A rule that existed only in the dialog
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

            THE SOURCE IS A FOLDER, which is the difference from importing
            media. An operating system comes from one .wim; an application comes
            from the folder holding its installer, because what is copied to the
            share is everything the install command line needs beside it - the
            an .msi and its .mst, the setup.exe and its payload directory.

            THE ID IS SUGGESTED FROM THAT FOLDER: an id is a folder name and the
            payload is already in one, so the source path answers the id box as
            well.

        .PARAMETER Workspace
            The share's root.

        .PARAMETER Id
            The id typed so far. Becomes the folder under Applications\.

        .PARAMETER SourcePath
            The folder holding the installer, typed so far.

        .PARAMETER Install
            The install command line typed so far.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with CanImport, Message,
            Path and SuggestedId.

        .EXAMPLE
            Test-HDTConsoleImportApplication -Workspace 'C:\HDTLab\Share' -Id '7Zip-24.09' -SourcePath 'C:\media\7Zip' -Install 'msiexec.exe /i 7z.msi /qn'

        .LINK
            Import-HDTApplication
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

        [Parameter(Position = 3)]
        [AllowEmptyString()]
        [string] $Install = '',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $suggested = ''

    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $leaf = [System.IO.Path]::GetFileName($SourcePath.TrimEnd('\', '/'))

        if ($leaf -match '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { $suggested = $leaf }
    }

    $folder = ''
    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        $folder = Join-Path -Path (Get-HDTWorkspacePath -Root $Workspace -Kind Applications) -ChildPath $Id
    }

    $answer = [pscustomobject] @{
        CanImport   = $false
        Message     = ''
        Path        = $folder
        SuggestedId = $suggested
    }

    # A BOX NOBODY HAS FILLED IN YET IS NOT A REFUSAL, and it does not get a
    # message. Each of these three is required - Import-HDTApplication makes
    # them mandatory - so Import is not offered without them; but what a box is
    # FOR is on its ?, and this line is for what is WRONG.
    #
    # THE RED LINE HAS TO MEAN SOMETHING. A dialog that complains about work in
    # progress teaches a technician that its message line is noise, and then the
    # message that matters - a source that is not there, an id the share already
    # has - arrives in the same colour as the ones that did not.
    if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($Install) -or
        [string]::IsNullOrWhiteSpace($Id)) {

        # ONE EXCEPTION: a source that WAS typed and is not there is wrong now,
        # not later, and it is the one mistake somebody makes without noticing.
        if (-not [string]::IsNullOrWhiteSpace($SourcePath) -and -not $FileSystem.TestPath($SourcePath)) {
            $answer.Message = "'{0}' is not there." -f $SourcePath
        }

        return $answer
    }

    if (-not $FileSystem.TestPath($SourcePath)) {
        $answer.Message = "'{0}' is not there." -f $SourcePath
        return $answer
    }

    # THE SAME PATTERN Import-HDTApplication ENFORCES.
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        $answer.Message = "'{0}' cannot be an id. It is a folder name: letters, digits, dot, dash and underscore, starting with a letter or a digit." -f $Id
        return $answer
    }

    if ($FileSystem.TestPath($folder)) {
        $answer.Message = "this share already has an application called '{0}'. Choose another id, or change that one with Set-HDTApplication instead of importing over it." -f $Id
        return $answer
    }

    $answer.CanImport = $true

    return $answer
}
