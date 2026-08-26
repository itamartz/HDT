# THE CONSOLE OPENS FOLDED, AND STAYS AS IT WAS LEFT.
#
# A share with two operating systems, seventy drivers and a task sequence draws
# about thirty rows fully expanded - so the tree that is supposed to reveal the
# share hid everything below the fold. Deployment Workbench opens folded, and
# now so does this.
#
# THE HARD HALF IS NOT THE FOLDING. The tree is rebuilt from scratch after every
# edit - what is on screen has to be what the ENGINE reads back rather than a
# patched copy - so every node is a new object and IsExpanded goes with the old
# ones. While every branch opened expanded that never showed; folded, a rename
# would fold the tree back up around the person doing it. These two commands are
# what carries the expansion across.

$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    function New-HDTTestBranch {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an object in a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([string] $Text, [int] $Depth = 0)

        $header = [pscustomobject] @{ Title = ''; Root = ''; DeployRoot = '' }

        return New-HDTConsoleNode -Depth $Depth -Kind 'Category' -Status 'Ok' -Text $Text `
            -Field @() -Command 'Get-HDTConsoleWorkspace' -Header $header
    }

    # Root -> Share -> (Applications, Drivers -> WinPE)
    function New-HDTTestTree {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an object in a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        $root = New-HDTTestBranch -Text 'Deployment Shares (1)' -Depth 0
        $share = New-HDTTestBranch -Text 'HDT deployment share' -Depth 1
        $apps = New-HDTTestBranch -Text 'Applications (2)' -Depth 2
        $drivers = New-HDTTestBranch -Text 'Drivers' -Depth 2
        $winpe = New-HDTTestBranch -Text 'WinPE (70)' -Depth 3

        [void] $drivers.Children.Add($winpe)
        [void] $share.Children.Add($apps)
        [void] $share.Children.Add($drivers)
        [void] $root.Children.Add($share)

        return $root
    }
}

Describe 'Get-HDTConsoleExpandedPath' {

    It 'names every branch that is open, by the path the tree draws' {
        $root = New-HDTTestTree

        # New-HDTConsoleNode builds expanded, so this is the whole tree.
        $open = @(Get-HDTConsoleExpandedPath -Node ([object[]] @($root)))

        $open | Should -Contain 'Deployment Shares (1)'
        $open | Should -Contain 'Deployment Shares (1)\HDT deployment share'
        $open | Should -Contain 'Deployment Shares (1)\HDT deployment share\Drivers'
        $open | Should -Contain 'Deployment Shares (1)\HDT deployment share\Drivers\WinPE (70)'
    }

    It 'says nothing about a branch that is folded' {
        $root = New-HDTTestTree
        @($root.Children)[0].IsExpanded = $false

        $open = @(Get-HDTConsoleExpandedPath -Node ([object[]] @($root)))

        $open | Should -Not -Contain 'Deployment Shares (1)\HDT deployment share'
    }

    It 'answers nothing for a folded tree rather than failing' {
        $root = New-HDTTestTree
        $root.IsExpanded = $false
        foreach ($child in @($root.Children)) { $child.IsExpanded = $false }

        @(Get-HDTConsoleExpandedPath -Node ([object[]] @($root))) |
            Should -Not -Contain 'Deployment Shares (1)'
    }
}

Describe 'Set-HDTConsoleExpandedPath' {

    It 'reopens exactly the branches it was given' {
        $root = New-HDTTestTree

        # Fold the lot, the way a fresh -Collapsed build arrives.
        $root.IsExpanded = $false
        @($root.Children)[0].IsExpanded = $false
        foreach ($node in @(@($root.Children)[0].Children)) { $node.IsExpanded = $false }

        $count = Set-HDTConsoleExpandedPath -Node ([object[]] @($root)) -Path @(
            'Deployment Shares (1)'
            'Deployment Shares (1)\HDT deployment share\Drivers')

        $count | Should -Be 2
        $root.IsExpanded | Should -BeTrue
        @(@($root.Children)[0].Children | Where-Object { $_.Text -eq 'Drivers' })[0].IsExpanded |
            Should -BeTrue
    }

    It 'leaves a branch it was not given exactly as it found it' {
        $root = New-HDTTestTree
        @($root.Children)[0].IsExpanded = $false

        [void] (Set-HDTConsoleExpandedPath -Node ([object[]] @($root)) -Path @('Deployment Shares (1)'))

        # NEVER CLEARS: the share was folded and stays folded, and the root was
        # already open and stays open.
        @($root.Children)[0].IsExpanded | Should -BeFalse
    }

    It 'ignores a path the rebuilt tree no longer has' {
        # Deleting a folder is an ordinary reason for this, and a refusal would
        # turn a successful delete into a message about the tree.
        $root = New-HDTTestTree

        { Set-HDTConsoleExpandedPath -Node ([object[]] @($root)) -Path @('Nowhere\At\All') } |
            Should -Not -Throw
    }

    It 'does nothing at all when nothing was open' {
        $root = New-HDTTestTree

        Set-HDTConsoleExpandedPath -Node ([object[]] @($root)) -Path @() | Should -Be 0
    }
}

Describe 'Get-HDTConsoleTreeNode -Collapsed' {

    BeforeAll {
        # A REAL WORKSPACE, READ THROUGH A FAKE FILESYSTEM. A hand-built stand-in
        # would have to keep up with every property the share node reads, and
        # would pass while the real shape drifted away from it.
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $repo -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        $fileSystem = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab`ndeployRoot: \\host\share"
        }

        $script:workspace = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fileSystem
    }

    It 'folds the categories and everything under them' {
        $node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($script:workspace)) -Collapsed)

        @($node).Count | Should -BeGreaterThan 1
        @($node | Where-Object { [int] $_.Depth -ge 2 -and $_.IsExpanded }) | Should -BeNullOrEmpty
    }

    It 'leaves the window and the share open, so the categories are the map' {
        # FOLDING EVERYTHING IS ONE ROW. The reason to fold was that thirty
        # expanded rows hid what mattered, not that the share is noise - so
        # Boot Image, Applications, Operating Systems, Drivers, Task Sequences,
        # Selection Profiles and Monitoring are all on screen and all shut.
        $node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($script:workspace)) -Collapsed)

        @($node | Where-Object { [int] $_.Depth -eq 0 })[0].IsExpanded | Should -BeTrue

        foreach ($row in @($node | Where-Object { [int] $_.Depth -eq 1 })) {
            $row.IsExpanded | Should -BeTrue -Because 'a share nobody can see is a window with nothing in it'
        }

        @($node | Where-Object { [int] $_.Depth -eq 2 }).Count |
            Should -BeGreaterThan 0 -Because 'the categories have to exist to be the map'
    }

    It 'leaves the tree open when not asked, because a REBUILD must not fold it' {
        $node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($script:workspace)))

        @($node | Where-Object { $_.IsExpanded }).Count | Should -BeGreaterThan 0
    }
}

}
