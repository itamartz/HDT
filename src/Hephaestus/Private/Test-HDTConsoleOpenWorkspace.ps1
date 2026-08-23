function Test-HDTConsoleOpenWorkspace {
    <#
        .SYNOPSIS
            Says whether a folder can be added to the console as a deployment
            share, and why not when it cannot.

        .DESCRIPTION
            THE OTHER HALF OF New Deployment Share, and it has one question: is
            there a share there? A folder with no workspace.yaml is not a
            deployment share, and adding it to the tree would put a row in the
            window that can only ever say it failed to open.

            THE CONSOLE STILL SHOWS A SHARE THAT WILL NOT READ, and that is not
            a contradiction. A workspace.yaml that is there but broken is a
            share somebody has to be able to see and fix, and Show-HDTConsole
            makes it a row saying so. A folder that holds no share at all was
            never one, and offering to add it is offering to add a mistake.

            ALREADY OPEN IS REFUSED TOO. The same share twice in one tree is two
            sets of rows that edit the same files, and a technician with no way
            to tell which is which.

        .PARAMETER Path
            The folder chosen so far.

        .PARAMETER Open
            The shares the window already has open, so the same one is not added
            twice. Compared without regard to case, as paths are.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with CanOpen and
            Message.

        .EXAMPLE
            Test-HDTConsoleOpenWorkspace -Path 'C:\HDTLab\Share' -Open $alreadyOpen

        .LINK
            Show-HDTConsole
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter(Position = 1)]
        [AllowEmptyCollection()]
        [string[]] $Open = @(),

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $answer = [pscustomobject] @{
        CanOpen = $false
        Message = ''
    }

    # NOTHING CHOSEN YET IS NOT A REFUSAL.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $answer }

    $already = @(@($Open) | Where-Object {
            [string]::Equals(([string] $_).TrimEnd('\', '/'), $Path.TrimEnd('\', '/'),
                [System.StringComparison]::OrdinalIgnoreCase)
        })

    if (@($already).Count -gt 0) {
        $answer.Message = "'{0}' is already open in this window." -f $Path
        return $answer
    }

    if (-not $FileSystem.TestPath($Path)) {
        $answer.Message = "'{0}' is not there." -f $Path
        return $answer
    }

    if (-not $FileSystem.TestPath((Join-Path -Path $Path -ChildPath 'workspace.yaml'))) {
        $answer.Message = "'{0}' holds no workspace.yaml, so it is not a deployment share. Create one there with New Deployment Share, or choose the folder that has it." -f $Path
        return $answer
    }

    $answer.CanOpen = $true

    return $answer
}
