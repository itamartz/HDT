# Tailing: the monitoring rows change while the window is open.
#
# ROADMAP M8 says "Monitoring view TAILING Logs\_active\". A view that reads the
# directory once and then shows an hour-old answer is a report, not a monitor -
# and worse, it is a report that looks like a monitor, which is how somebody
# comes to believe a machine is fine.
#
# ONLY THE MONITORING BRANCH IS REBUILT, AND THAT IS THE WHOLE DESIGN. Rebuilding
# the tree would re-read workspace.yaml, every sequence document and the boot
# image manifest - over SMB, every few seconds, for a number that lives in one
# small directory. It would also throw away the expansion and selection an
# administrator had set up. So the refresh reads Logs\_active\ and nothing else,
# and produces one replacement node.
#
# THE NODE IS REPLACED, NOT MUTATED. A PSCustomObject raises no change
# notification, so editing Text on a row already on screen changes nothing a
# person can see. Handing WPF a NEW object in an observable collection is what
# makes the row redraw - which is why Children is an ObservableCollection and
# why this returns a whole category rather than a list of runs.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:now = [datetime]::new(2026, 8, 15, 22, 0, 0, [System.DateTimeKind]::Utc)

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\192.168.2.108\HDTShare
'@

    function New-HDTRefreshBeat {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Returns a JSON string in memory; it changes no state.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)] [string] $RunId,
            [Parameter(Mandatory = $true)] [string] $Updated,
            [Parameter()] [string] $StepName = 'Apply OS',
            [Parameter()] [int] $StepIndex = 3
        )

        return (ConvertTo-Json -Depth 4 -InputObject ([ordered] @{
                    schemaVersion = 1
                    runId         = $RunId
                    phase         = 'WinPE'
                    status        = 'Running'
                    stepIndex     = $StepIndex
                    stepCount     = 12
                    stepName      = $StepName
                    stepType      = 'ApplyImage'
                    updated       = $Updated
                }))
    }

    function New-HDTRefreshFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [hashtable] $Beat = @{})

        $file = @{ 'C:\ws\workspace.yaml' = $script:workspaceYaml }
        foreach ($key in $Beat.Keys) { $file[$key] = $Beat[$key] }

        return New-HDTFakeFileSystem -File $file -Directory @('C:\ws\Logs\_active')
    }
}

Describe 'a node and its children' {

    It 'holds them in a collection WPF is told about when it changes' {
        # An ArrayList is invisible to a binding: rows added to one after the
        # tree was drawn never appear, and the tail would silently do nothing.
        $share = Get-HDTConsoleWorkspace -Path 'C:\ws' `
            -FileSystem (New-HDTRefreshFileSystem) -Clock (New-HDTFakeClock -UtcNow $script:now)

        $node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($share)))

        # Named rather than piped: Should -BeOfType unrolls a collection and would
        # test the first ROW instead of the collection holding it.
        $node[0].Children.GetType().Name | Should -BeExactly 'ObservableCollection`1'
    }
}

Describe 'Get-HDTConsoleMonitorNode' {

    It 'builds the monitoring category on its own, without re-reading the share' {
        $fs = New-HDTRefreshFileSystem -Beat @{
            'C:\ws\Logs\_active\RUN-1.json' = (New-HDTRefreshBeat -RunId 'RUN-1' -Updated '2026-08-15T21:59:40.0000000Z')
        }

        $category = Get-HDTConsoleMonitorNode -Path 'C:\ws' -FileSystem $fs `
            -Clock (New-HDTFakeClock -UtcNow $script:now)

        $category.Kind | Should -BeExactly 'MonitorCategory'
        $category.Text | Should -BeLike 'Monitoring*'
        @($category.Children).Count | Should -Be 1
        @($category.Children)[0].Name | Should -BeExactly 'RUN-1'
    }

    It 'reads only the heartbeat directory' {
        # The point of a separate builder: over SMB, every few seconds, this must
        # not re-read workspace.yaml and every sequence document.
        $fs = New-HDTRefreshFileSystem -Beat @{
            'C:\ws\Logs\_active\RUN-1.json' = (New-HDTRefreshBeat -RunId 'RUN-1' -Updated '2026-08-15T21:59:40.0000000Z')
        }

        [void] (Get-HDTConsoleMonitorNode -Path 'C:\ws' -FileSystem $fs `
                -Clock (New-HDTFakeClock -UtcNow $script:now))

        $touched = @($fs.Operations | ForEach-Object { $_.Arguments[0] })

        @($touched | Where-Object { $_ -like '*workspace.yaml' }) | Should -BeNullOrEmpty
        @($touched | Where-Object { $_ -like '*_active*' }).Count | Should -BeGreaterThan 0
    }

    It 'is the same node the tree already shows, so the two cannot drift' {
        $fs = New-HDTRefreshFileSystem -Beat @{
            'C:\ws\Logs\_active\RUN-1.json' = (New-HDTRefreshBeat -RunId 'RUN-1' -Updated '2026-08-15T21:59:40.0000000Z')
        }
        $clock = New-HDTFakeClock -UtcNow $script:now

        $share = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fs -Clock $clock
        $inTree = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($share)) |
                Where-Object { $_.Kind -eq 'MonitorCategory' })[0]

        $rebuilt = Get-HDTConsoleMonitorNode -Path 'C:\ws' -FileSystem $fs -Clock $clock

        $rebuilt.Text | Should -BeExactly $inTree.Text
        @($rebuilt.Children | ForEach-Object { $_.Text }) |
            Should -Be @($inTree.Children | ForEach-Object { $_.Text })
    }

    It 'shows a run that has appeared since the window opened' {
        $clock = New-HDTFakeClock -UtcNow $script:now

        $before = Get-HDTConsoleMonitorNode -Path 'C:\ws' -Clock $clock `
            -FileSystem (New-HDTRefreshFileSystem)

        $after = Get-HDTConsoleMonitorNode -Path 'C:\ws' -Clock $clock `
            -FileSystem (New-HDTRefreshFileSystem -Beat @{
                    'C:\ws\Logs\_active\RUN-NEW.json' = (New-HDTRefreshBeat -RunId 'RUN-NEW' -Updated '2026-08-15T21:59:55.0000000Z')
                })

        @($before.Children)[0].Kind | Should -BeExactly 'Empty'
        @($after.Children)[0].Name | Should -BeExactly 'RUN-NEW'
    }

    It 'moves a run on to its next step' {
        $clock = New-HDTFakeClock -UtcNow $script:now

        $later = Get-HDTConsoleMonitorNode -Path 'C:\ws' -Clock $clock `
            -FileSystem (New-HDTRefreshFileSystem -Beat @{
                    'C:\ws\Logs\_active\RUN-1.json' = (New-HDTRefreshBeat -RunId 'RUN-1' -StepIndex 8 `
                            -StepName 'Install Applications' -Updated '2026-08-15T21:59:58.0000000Z')
                })

        @($later.Children)[0].Text | Should -BeLike '*Install Applications*'
    }

    It 'opens on a share whose heartbeat folder is not there' {
        $bare = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:workspaceYaml } -Directory @('C:\ws')

        $category = Get-HDTConsoleMonitorNode -Path 'C:\ws' -FileSystem $bare `
            -Clock (New-HDTFakeClock -UtcNow $script:now)

        $category.Text | Should -BeExactly 'Monitoring'
        @($category.Children)[0].Kind | Should -BeExactly 'Empty'
    }
}


}
