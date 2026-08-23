function Test-HDTConsoleNewWorkspace {
    <#
        .SYNOPSIS
            Says whether the New Deployment Share dialog's answers can be used,
            and why not when they cannot.

        .DESCRIPTION
            New-HDTWorkspace refuses a bad id and a folder that already holds a
            share - but it refuses them at the END, after the boxes have been
            filled in and Create has been pressed. This asks the same questions
            while they are typed, so the refusal appears beside the box that
            caused it and Create is simply not offered until it would work.

            IT DECIDES NOTHING New-HDTWorkspace DOES NOT. Every rule here
            mirrors one there. A rule that existed only in the dialog would be a
            rule the command line has not got, and the console would be
            describing a toolkit that does not exist (DESIGN 12).

            A BOX NOBODY HAS FILLED IN YET IS NOT A REFUSAL - the rule the New
            Application and Import Operating System dialogs were fixed to
            follow. The message line is for what is WRONG, and a disabled Create
            is what says "not yet".

            A FOLDER THAT IS NOT THERE IS FINE, because creating it is the whole
            point. What is refused is a folder that already holds a
            workspace.yaml: New-HDTWorkspace will not write over one, and
            finding that out after typing four boxes is finding it out too late.

            THE ID IS SUGGESTED FROM THE FOLDER NAME, as every other dialog here
            suggests one from what was browsed to.

        .PARAMETER Path
            The folder the share would be created in.

        .PARAMETER Id
            The share's id, which is carried into every boot image and written
            into log and artifact names.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with CanCreate, Message
            and SuggestedId.

        .EXAMPLE
            Test-HDTConsoleNewWorkspace -Path 'C:\HDTLab\Share2' -Id 'HDT-LAB-2'

        .LINK
            New-HDTWorkspace
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $Id = '',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $suggested = ''

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $leaf = [System.IO.Path]::GetFileName($Path.TrimEnd('\', '/'))

        if ($leaf -match '^[A-Za-z0-9][A-Za-z0-9_-]*$') { $suggested = $leaf }
    }

    $answer = [pscustomobject] @{
        CanCreate   = $false
        Message     = ''
        SuggestedId = $suggested
    }

    # A FOLDER THAT ALREADY HOLDS A SHARE IS WRONG NOW, not after four boxes -
    # the same exception the source-that-is-not-there gets in the other dialogs.
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $existing = Join-Path -Path $Path -ChildPath 'workspace.yaml'

        if ($FileSystem.TestPath($existing)) {
            $answer.Message = "'{0}' already holds a deployment share. Open that one instead, or choose a folder with no workspace.yaml in it." -f $Path
            return $answer
        }
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Id)) { return $answer }

    # THE SAME PATTERN New-HDTWorkspace ENFORCES. The id is carried into every
    # boot image and written into log and artifact names.
    if ($Id -notmatch '^[A-Za-z0-9_-]{1,64}$') {
        $answer.Message = "'{0}' cannot be a share id. It is letters, digits, underscore and hyphen, up to 64 of them - it is carried into every boot image built here and written into log and artifact names." -f $Id
        return $answer
    }

    $answer.CanCreate = $true

    return $answer
}
