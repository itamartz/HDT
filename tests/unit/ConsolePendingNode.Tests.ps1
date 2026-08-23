# THE ROW THE CONSOLE SHOWS WHILE IT IS STILL READING.
#
# Opening the console costs about a second on the lab share before anything is
# on screen, and 820ms of it is Get-HDTConsoleWorkspace: every sequence in the
# share is read and validated before the window exists. Measured.
#
# SO THE WINDOW OPENS FIRST AND READS SECOND. This is what it holds in between -
# one row, saying what it is doing and which share it is doing it to, because a
# window that appears empty for a second is a window somebody clicks again.
#
# IT IS NOT AN ERROR ROW AND IT IS NOT A SHARE. Nothing downstream should treat
# it as either: it carries no HeaderRoot, so the refresh timer and the rebuild
# find nothing to re-read, which is exactly right until the real rows arrive.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function Get-HDTTestPendingNode {
        [CmdletBinding()]
        [OutputType([object])]
        param([string[]] $Path)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ P = $Path } {
            param($P)
            New-HDTConsolePendingNode -Path ([string[]] $P)
        }
    }
}

Describe 'New-HDTConsolePendingNode' {

    It 'is one row, at the depth the real root sits at' {
        $node = @(Get-HDTTestPendingNode -Path @('C:\HDTLab\Share'))

        @($node).Count | Should -Be 1
        [int] $node[0].Depth | Should -Be 0
    }

    It 'says it is reading, rather than looking like an empty console' {
        $node = @(Get-HDTTestPendingNode -Path @('C:\HDTLab\Share'))

        [string] $node[0].Text | Should -BeLike '*eading*'
    }

    It 'names the share it is reading' {
        $node = @(Get-HDTTestPendingNode -Path @('C:\HDTLab\Share'))

        (@($node[0].Field | ForEach-Object { [string] $_.Value }) -join ' ') |
            Should -BeLike '*C:\HDTLab\Share*'
    }

    It 'names all of them when there are several' {
        $node = @(Get-HDTTestPendingNode -Path @('C:\one', 'C:\two'))

        $said = (@($node[0].Field | ForEach-Object { [string] $_.Value }) -join ' ')

        $said | Should -BeLike '*C:\one*'
        $said | Should -BeLike '*C:\two*'
    }

    It 'carries no share root, so nothing tries to re-read it' {
        # The refresh timer and the rebuild both walk the tree looking for
        # HeaderRoot. A placeholder that had one would be re-read as a share.
        $node = @(Get-HDTTestPendingNode -Path @('C:\HDTLab\Share'))

        [string] $node[0].HeaderRoot | Should -BeExactly ''
    }

    It 'names the command that is running, like every other row' {
        $node = @(Get-HDTTestPendingNode -Path @('C:\HDTLab\Share'))

        [string] $node[0].Command | Should -BeLike '*Show-HDTConsole*'
    }

    # THE PREVIEW IS THERE TO BE TYPED. A row that names a command the module
    # does not export teaches an administrator something that answers with a red
    # line, which is worse than naming nothing - and the reader behind this row
    # is internal to the window now.
    It 'names a command the module actually exports' {
        $node = @(Get-HDTTestPendingNode -Path @('C:\HDTLab\Share'))

        $named = ([string] $node[0].Command -split '\s+')[0]

        Get-Command -Name $named -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty -Because "the row offers '$named' to be typed"
    }
}
