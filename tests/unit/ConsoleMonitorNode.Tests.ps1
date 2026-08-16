# Monitoring, as a place in the tree rather than a command you have to know about.
#
# DESIGN 12 lists it among the categories: "tree navigation mirroring the
# workspace (Operating Systems, Task Sequences, Applications, Drivers, Media,
# Monitoring) - deliberately close to Deployment Workbench so muscle memory
# transfers". An administrator looking for what is running should find it where
# they find everything else about the share.
#
# THE ROWS ARE Get-HDTConsoleMonitor'S; THIS IS WHERE THEY HANG. Nothing here
# re-reads a heartbeat or works out an age - that was decided and asserted in
# ConsoleMonitor.Tests.ps1, and duplicating the judgement here would be a second
# implementation of it that could disagree.
#
# THE CATEGORY SAYS WHAT IT HOLDS WITHOUT BEING OPENED. A tree row reading
# "Monitoring" tells a technician nothing; one reading "Monitoring (2 stalled, 1
# running)" is the whole screen at a glance, and is the row they were going to
# open anyway.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:now = [datetime]::new(2026, 8, 15, 22, 0, 0, [System.DateTimeKind]::Utc)

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\192.168.2.108\HDTShare
'@

    $script:sequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11
steps:
  - name: Apply OS
    type: ApplyImage
'@

    function New-HDTTestBeat {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Returns a JSON string in memory; it changes no state.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)] [string] $RunId,
            [Parameter(Mandatory = $true)] [string] $Updated,
            [Parameter()] [string] $Status = 'Running'
        )

        return (ConvertTo-Json -Depth 4 -InputObject ([ordered] @{
                    schemaVersion = 1
                    runId         = $RunId
                    phase         = 'WinPE'
                    status        = $Status
                    stepIndex     = 2
                    stepName      = 'Format and Partition'
                    stepType      = 'DiskPartition'
                    updated       = $Updated
                }))
    }

    function New-HDTTestShare {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a projection from an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [hashtable] $Beat = @{})

        $file = @{
            'C:\ws\workspace.yaml'                      = $script:workspaceYaml
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml' = $script:sequenceYaml
        }

        foreach ($key in $Beat.Keys) { $file[$key] = $Beat[$key] }

        return Get-HDTConsoleWorkspace -Path 'C:\ws' `
            -FileSystem (New-HDTFakeFileSystem -File $file -Directory @('C:\ws\Logs\_active')) `
            -Clock (New-HDTFakeClock -UtcNow $script:now)
    }
}

Describe 'Get-HDTConsoleWorkspace and the monitor' {

    It 'carries what is running on the share' {
        $share = New-HDTTestShare -Beat @{
            'C:\ws\Logs\_active\RUN-1.json' = (New-HDTTestBeat -RunId 'RUN-1' -Updated '2026-08-15T21:59:40.0000000Z')
        }

        $share.Monitor | Should -Not -BeNullOrEmpty
        @($share.Monitor.Run).Count | Should -Be 1
        $share.Monitor.Run[0].RunId | Should -BeExactly 'RUN-1'
    }

    It 'carries the same shape when nothing is running' {
        # A caller that has to check for two different shapes is a caller that
        # will one day forget.
        $share = New-HDTTestShare

        $share.Monitor | Should -Not -BeNullOrEmpty
        @($share.Monitor.Run).Count | Should -Be 0
    }

    It 'gives a share that could not be opened the same member' {
        # Reached the way the console reaches it - Show-HDTConsole turns a share
        # it could not open into a failure row rather than refusing to start -
        # because New-HDTConsoleShareFailure is private and a test that called
        # it directly would be testing a path no administrator can take.
        $fake = [pscustomobject] @{ Answer = 'Close'; Width = 1800; Height = 900 }
        $fake | Add-Member -MemberType ScriptMethod -Name Show -Value { return 'Close' }

        # The markup is checked through the SAME injected filesystem, so the
        # fake has to hold it - the real file is never read here.
        $xamlPath = Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/UI/HDTConsole.xaml'

        $answer = Show-HDTConsole -Path 'C:\nope' -ConsoleHost $fake `
            -FileSystem (New-HDTFakeFileSystem -File @{ $xamlPath = '<Window />' } -Directory @('C:\')) `
            -Environment (New-HDTFakeEnvironmentProvider -Variable @{ APPDATA = 'C:\appdata' }) `
            -Screen (New-HDTFakeScreen -Width 3840 -Height 2160) `
            -XamlPath $xamlPath

        $failed = @($answer.Workspace)[0]

        $failed.Status | Should -BeExactly 'Error'
        $failed.PSObject.Properties.Name | Should -Contain 'Monitor'
        @($failed.Monitor.Run).Count | Should -Be 0
    }
}

Describe 'the Monitoring node' {

    Context 'a share with deployments on it' {

        BeforeAll {
            $script:node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @(New-HDTTestShare -Beat @{
                            'C:\ws\Logs\_active\RUN-1.json' = (New-HDTTestBeat -RunId 'RUN-1' -Updated '2026-08-15T21:59:40.0000000Z')
                            'C:\ws\Logs\_active\RUN-2.json' = (New-HDTTestBeat -RunId 'RUN-2' -Updated '2026-08-15T20:00:00.0000000Z')
                        })))

            $script:category = @($script:node | Where-Object { $_.Kind -eq 'MonitorCategory' })[0]
        }

        It 'is a category in the tree, where DESIGN 12 puts it' {
            $script:category | Should -Not -BeNullOrEmpty
            $script:category.Depth | Should -Be 2
        }

        It 'says what it holds without being opened' {
            $script:category.Text | Should -BeLike '*stalled*'
            $script:category.Text | Should -BeLike '*running*'
        }

        It 'gives every run a row beneath it' {
            @($script:category.Children | ForEach-Object { $_.Kind }) | Should -Be @('MonitorRun', 'MonitorRun')
        }

        It 'puts the one that spoke most recently first, as the command decided' {
            @($script:category.Children | ForEach-Object { $_.Name }) | Should -Be @('RUN-1', 'RUN-2')
        }

        It 'shows the step and the age on the row' {
            $row = @($script:category.Children)[0]

            $row.Text | Should -BeLike '*RUN-1*'
            $row.Text | Should -BeLike '*Format and Partition*'
        }

        It 'fills the detail pane with what a technician would ask next' {
            $row = @($script:category.Children)[0]
            $label = @($row.Field | ForEach-Object { $_.Label })

            $label | Should -Contain 'Run'
            $label | Should -Contain 'Phase'
            $label | Should -Contain 'Step'
            $label | Should -Contain 'Last heartbeat'
            $label | Should -Contain 'Health'
        }

        It 'shows the cmdlet behind the row, like every other row in this console' {
            @($script:category.Children)[0].Command | Should -BeLike '*RUN-1.json*'
        }

        It 'marks a stalled run so it reads as one at a glance' {
            $stalled = @($script:category.Children | Where-Object { $_.Name -eq 'RUN-2' })[0]

            $stalled.Status | Should -BeExactly 'Error'
        }

        It 'leaves a healthy one alone' {
            $live = @($script:category.Children | Where-Object { $_.Name -eq 'RUN-1' })[0]

            $live.Status | Should -BeExactly 'Ok'
        }
    }

    Context 'a share with nothing running' {

        It 'still shows the category, so the answer is where it was last time' {
            $node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @(New-HDTTestShare)))
            $category = @($node | Where-Object { $_.Kind -eq 'MonitorCategory' })[0]

            $category | Should -Not -BeNullOrEmpty
        }

        It 'says so in a row rather than looking broken' {
            $node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @(New-HDTTestShare)))
            $category = @($node | Where-Object { $_.Kind -eq 'MonitorCategory' })[0]

            @($category.Children).Count | Should -Be 1
            @($category.Children)[0].Kind | Should -BeExactly 'Empty'
            @($category.Children)[0].Text | Should -BeLike '*no deployment*'
        }
    }
}
