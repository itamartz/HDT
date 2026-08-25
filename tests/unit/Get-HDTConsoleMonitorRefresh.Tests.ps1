# Which monitoring branches the refresh timer has to rebuild, and what to rebuild
# them with.
#
# THE DECISION CAME OUT OF THE TIMER'S HANDLER. A DispatcherTimer tick used to
# walk the tree itself: find the MonitorCategory row under each share, remember
# which run was highlighted, and hand both back to Get-HDTConsoleMonitorNode.
# That is six branches living inside a WPF event handler, where no test can
# reach them - and the console's last several defects were all found by looking
# at the window because of exactly that.
#
# THE HIGHLIGHT IS READ BEFORE ANYTHING IS REPLACED. Children is an
# ObservableCollection and swapping the object in it is what makes WPF redraw
# the branch; the redraw is also what loses the selection. So the run being
# watched has to be captured first and handed back to the rebuilt node, or a
# technician watching one deployment gets the highlight taken off it every few
# seconds.
#
# ONLY A RUN COUNTS AS SOMETHING BEING WATCHED. The category row and the share
# row are selectable too, and neither names a deployment - reading Name off them
# would hand the rebuild a highlight for a run that does not exist.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {

    # The shape the tree actually carries: Get-HDTConsoleMonitorNode writes
    # HeaderTitle, HeaderRoot and HeaderDeployRoot onto the category row, and
    # the rebuild needs all three back.
    function New-HDTTestMonitorCategory {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()] [string] $Title = 'HDTLab',
            [Parameter()] [string] $Root = 'C:\HDTLab\Share',
            [Parameter()] [string] $DeployRoot = '\\host\Share',
            [Parameter()] [object[]] $Run = @()
        )

        return [pscustomobject] @{
            Kind             = 'MonitorCategory'
            Name             = 'Monitoring'
            HeaderTitle      = $Title
            HeaderRoot       = $Root
            HeaderDeployRoot = $DeployRoot
            Children         = [object[]] $Run
        }
    }

    function New-HDTTestMonitorRun {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter(Mandatory = $true)] [string] $Name)

        return [pscustomobject] @{ Kind = 'MonitorRun'; Name = $Name; Children = @() }
    }

    function New-HDTTestShare {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()] [string] $Name = 'HDTLab',
            [Parameter()] [object[]] $Child = @()
        )

        return [pscustomobject] @{ Kind = 'Share'; Name = $Name; Children = [object[]] $Child }
    }

    function New-HDTTestRoot {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter()] [object[]] $Share = @())

        return [pscustomobject] @{ Kind = 'Root'; Name = 'Deployment Shares'; Children = [object[]] $Share }
    }
}

Describe 'Get-HDTConsoleMonitorRefresh' {

    Context 'a share whose monitoring branch is on screen' {

        BeforeAll {
            $script:run = New-HDTTestMonitorRun -Name 'run-0007'
            $script:category = New-HDTTestMonitorCategory -Run @($script:run)
            $script:share = New-HDTTestShare -Child @(
                [pscustomobject] @{ Kind = 'TaskSequence'; Name = 'Sequences'; Children = @() }
                $script:category
            )
            $script:tree = @(New-HDTTestRoot -Share @($script:share))
        }

        It 'asks for one rebuild' {
            @(Get-HDTConsoleMonitorRefresh -Root $script:tree -Selected $null).Count |
                Should -Be 1
        }

        It 'names the share the rows are to be read from' {
            $answer = @(Get-HDTConsoleMonitorRefresh -Root $script:tree -Selected $null)

            $answer[0].Path | Should -BeExactly 'C:\HDTLab\Share'
        }

        It 'points at the row it is replacing, not at the share' {
            # The category is the SECOND child here on purpose: an index that
            # assumed position zero would overwrite the task sequence folder.
            $answer = @(Get-HDTConsoleMonitorRefresh -Root $script:tree -Selected $null)

            $answer[0].Index | Should -Be 1
        }

        It 'hands back the branch that owns the row' {
            $answer = @(Get-HDTConsoleMonitorRefresh -Root $script:tree -Selected $null)

            $answer[0].Parent | Should -Be $script:share
        }

        It 'carries the header the rebuilt row has to keep wearing' {
            $answer = @(Get-HDTConsoleMonitorRefresh -Root $script:tree -Selected $null)

            $answer[0].Header.Title | Should -BeExactly 'HDTLab'
            $answer[0].Header.Root | Should -BeExactly 'C:\HDTLab\Share'
            $answer[0].Header.DeployRoot | Should -BeExactly '\\host\Share'
        }
    }

    Context 'nothing selected in the tree' {

        It 'watches no run' {
            $tree = @(New-HDTTestRoot -Share @(New-HDTTestShare -Child @(New-HDTTestMonitorCategory)))

            $answer = @(Get-HDTConsoleMonitorRefresh -Root $tree -Selected $null)

            $answer[0].SelectedName | Should -BeExactly ''
        }
    }

    Context 'a deployment the technician is watching' {

        It 'hands the highlight back to the run it was on' {
            $run = New-HDTTestMonitorRun -Name 'run-0007'
            $tree = @(New-HDTTestRoot -Share @(New-HDTTestShare -Child @(New-HDTTestMonitorCategory -Run @($run))))

            $answer = @(Get-HDTConsoleMonitorRefresh -Root $tree -Selected $run)

            $answer[0].SelectedName | Should -BeExactly 'run-0007'
        }
    }

    # THE CATEGORY ROW AND THE SHARE ROW ARE SELECTABLE TOO, and neither is a
    # deployment. Reading Name off them would ask the rebuild to highlight a run
    # called 'Monitoring'.
    Context 'a row selected that is not a run' {

        It 'watches no run when the category itself is selected' {
            $category = New-HDTTestMonitorCategory
            $tree = @(New-HDTTestRoot -Share @(New-HDTTestShare -Child @($category)))

            $answer = @(Get-HDTConsoleMonitorRefresh -Root $tree -Selected $category)

            $answer[0].SelectedName | Should -BeExactly ''
        }

        It 'watches no run when the share is selected' {
            $share = New-HDTTestShare -Child @(New-HDTTestMonitorCategory)
            $tree = @(New-HDTTestRoot -Share @($share))

            $answer = @(Get-HDTConsoleMonitorRefresh -Root $tree -Selected $share)

            $answer[0].SelectedName | Should -BeExactly ''
        }
    }

    Context 'a share with no monitoring branch built yet' {

        It 'asks for nothing' {
            $tree = @(New-HDTTestRoot -Share @(New-HDTTestShare -Child @(
                        [pscustomobject] @{ Kind = 'TaskSequence'; Name = 'Sequences'; Children = @() })))

            @(Get-HDTConsoleMonitorRefresh -Root $tree -Selected $null).Count | Should -Be 0
        }
    }

    # THE TREE, NOT THE COLLECTION THE METHOD WAS HANDED. A console with two
    # shares open refreshes both, and the timer that only rebuilt the first one
    # left the second showing a deployment that finished ten minutes ago.
    Context 'more than one share open' {

        It 'asks for a rebuild under each of them' {
            $tree = @(New-HDTTestRoot -Share @(
                    (New-HDTTestShare -Name 'One' -Child @(New-HDTTestMonitorCategory -Root 'C:\One'))
                    (New-HDTTestShare -Name 'Two' -Child @(New-HDTTestMonitorCategory -Root 'C:\Two'))
                ))

            $answer = @(Get-HDTConsoleMonitorRefresh -Root $tree -Selected $null)

            $answer.Count | Should -Be 2
            @($answer.Path) | Should -Be @('C:\One', 'C:\Two')
        }

        It 'crosses every root the tree carries' {
            $tree = @(
                (New-HDTTestRoot -Share @(New-HDTTestShare -Child @(New-HDTTestMonitorCategory -Root 'C:\One')))
                (New-HDTTestRoot -Share @(New-HDTTestShare -Child @(New-HDTTestMonitorCategory -Root 'C:\Two')))
            )

            @(Get-HDTConsoleMonitorRefresh -Root $tree -Selected $null).Count | Should -Be 2
        }
    }

    Context 'a tree that has not been filled yet' {

        It 'asks for nothing rather than failing' {
            @(Get-HDTConsoleMonitorRefresh -Root @() -Selected $null).Count | Should -Be 0
        }

        It 'accepts a null tree' {
            @(Get-HDTConsoleMonitorRefresh -Root $null -Selected $null).Count | Should -Be 0
        }

        It 'accepts a share with no children at all' {
            $tree = @(New-HDTTestRoot -Share @(New-HDTTestShare))

            @(Get-HDTConsoleMonitorRefresh -Root $tree -Selected $null).Count | Should -Be 0
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleMonitorRefresh -ErrorAction Stop

        # The name is asserted first: Get-Help falls back to a fuzzy search and
        # will answer for a different command rather than fail.
        $help.Name | Should -BeExactly 'Get-HDTConsoleMonitorRefresh'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
