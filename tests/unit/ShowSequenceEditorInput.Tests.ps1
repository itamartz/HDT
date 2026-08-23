# THE EDITOR HAS TO BE OPENABLE BY THE PERSON WHO OWNS THE SHARE.
#
# THE REGRESSION THIS FILE EXISTS FOR. Show-HDTSequenceEditor is exported, and
# its only input was -Sequence: one task sequence row out of a console workspace,
# carrying Status, Finding, ErrorCount and WarningCount alongside the steps. The
# only command that builds such a row is Get-HDTConsoleWorkspace, and when the
# console's helpers stopped being exported, the row became something nobody
# outside the module could produce. A public command that takes an object only a
# private command can make is not a public command.
#
# Import-HDTSequenceDocument is NOT that object and does not stand in for it: it
# reads one sequence.yaml and reports Path, SchemaVersion, Id, Name, Version,
# Description, Folder, Variable, Step and Group - no Status, which is the first
# property the editor's node builder reads. Handing one over throws
# "The property 'Status' cannot be found on this object" from three frames down.
#
# SO THE COMMAND READS THE SHARE ITSELF. -WorkspaceRoot and -Id are what an
# administrator has; -Sequence stays for the console, which already holds the row
# it drew the tree from and must not read the share a second time to open a
# window on it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # The same shape ConsoleEditorWindow.Tests.ps1 uses: the adapter is not unit
    # tested, so the double records what reached it and decides nothing.
    function New-HDTFakeEditorHost {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()

        $fake = [pscustomobject] @{
            ShowCount = 0
            Title     = ''
            Path      = ''
            Node      = @()
        }

        $fake | Add-Member -MemberType ScriptMethod -Name ShowEditor -Value {
            param(
                [string] $Xaml, [string] $Title, [string] $Path,
                [object[]] $Node, [string[]] $Line, [object[]] $Catalog, [object] $Theme,
                [object] $Size
            )

            $this.ShowCount = $this.ShowCount + 1
            $this.Title = $Title
            $this.Path = $Path
            $this.Node = $Node

            return 'Close'
        }

        return $fake
    }
}

Describe 'Show-HDTSequenceEditor input' {

    Context 'the shape of the command' {

        It 'takes a workspace root and an id' {
            $parameter = (Get-Command -Name 'Show-HDTSequenceEditor').Parameters
            $parameter.ContainsKey('WorkspaceRoot') | Should -BeTrue
            $parameter.ContainsKey('Id') | Should -BeTrue
        }

        It 'still takes the row the console already holds' {
            (Get-Command -Name 'Show-HDTSequenceEditor').Parameters.ContainsKey('Sequence') |
                Should -BeTrue
        }

        It 'offers the two as separate parameter sets' {
            $sets = @((Get-Command -Name 'Show-HDTSequenceEditor').ParameterSets |
                    ForEach-Object { $_.Name })

            $sets.Count | Should -BeGreaterThan 1
        }

        # The point of the whole change: everything the command needs has to be
        # reachable from a session that only imported the module.
        It 'names no parameter default that an administrator cannot produce' {
            $sets = @((Get-Command -Name 'Show-HDTSequenceEditor').ParameterSets |
                    Where-Object { $_.IsDefault })

            @($sets).Count | Should -Be 1
            @($sets)[0].Parameters |
                Where-Object { $_.IsMandatory } |
                ForEach-Object { $_.Name } |
                Should -Not -Contain 'Sequence'
        }
    }

    Context 'opening it by share and id' {

        BeforeAll {
            $script:share = 'C:\HDTLab\Share'
            $script:hasShare = Test-Path -LiteralPath (Join-Path -Path $script:share -ChildPath 'workspace.yaml')
        }

        It 'reads the share and finds the sequence' -Skip:(-not (Test-Path -LiteralPath 'C:\HDTLab\Share\workspace.yaml')) {
            $consoleHost = New-HDTFakeEditorHost

            $null = Show-HDTSequenceEditor -WorkspaceRoot $script:share -Id 'DEMO-05' -ConsoleHost $consoleHost

            $consoleHost.ShowCount | Should -Be 1
            [string] $consoleHost.Title | Should -BeLike '*DEMO-05*'
        }

        It 'refuses an id the share does not hold, naming it' -Skip:(-not (Test-Path -LiteralPath 'C:\HDTLab\Share\workspace.yaml')) {
            $consoleHost = New-HDTFakeEditorHost

            { Show-HDTSequenceEditor -WorkspaceRoot $script:share -Id 'NO-SUCH-SEQUENCE' -ConsoleHost $consoleHost } |
                Should -Throw '*NO-SUCH-SEQUENCE*'
        }
    }

    Context 'what the help tells the reader to type' {

        # THE HELP SAID Import-HDTSequenceDocument, WHICH THROWS. An example that
        # cannot be run is the defect this whole exercise started from.
        It 'shows no example that hands a raw sequence document to -Sequence' {
            $help = Get-Help -Name 'Show-HDTSequenceEditor' -Full

            $code = @($help.examples.example | ForEach-Object { [string] $_.code }) -join "`n"

            $code | Should -Not -Match 'Import-HDTSequenceDocument[^\n]*\n?[^\n]*-Sequence'
        }

        It 'shows an example an administrator can run as written' {
            $help = Get-Help -Name 'Show-HDTSequenceEditor' -Full

            $code = @($help.examples.example | ForEach-Object { [string] $_.code }) -join "`n"

            $code | Should -Match '-WorkspaceRoot'
        }
    }
}
