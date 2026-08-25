# The Selection Profiles window, worked out without a window.
#
# THE TICK BOX TREE IS THE WHOLE POINT. An administrator knows the folder they
# want by SEEING it, not by typing its path - which is why MDT put a tree with
# tick boxes here and not a text box, and why Get-HDTSelectionProfile's include
# list is a set of paths rather than a pattern.
#
# THE SQUARE IS WHAT MAKES IT WORK. Ticking Drivers\WinPE and leaving
# Drivers\Dell alone has to LOOK different from ticking Drivers, because those
# two are 104 .inf files and 641 respectively, and one of them is a boot image
# that takes four minutes to transfer to every machine that PXE boots.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\HDTLab\Share'

    function New-HDTTestShareFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        return New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64\e1d68x64.inf' = '[Version]'
            'C:\HDTLab\Share\Drivers\WinPE\HP WinPE 11 x64\stornvme.inf'   = '[Version]'
            'C:\HDTLab\Share\Drivers\Dell\Latitude 7450\wifi.inf'          = '[Version]'
            'C:\HDTLab\Share\Applications\7Zip-24.09\app.yaml'             = 'schemaVersion: 1'
            'C:\HDTLab\Share\OperatingSystems\Win11\os.yaml'               = 'schemaVersion: 1'
            'C:\HDTLab\Share\Drivers\driver-index.json'                    = '{}'
            'C:\HDTLab\Share\Logs\PC-0001\hdt.log'                         = 'log'
        }
    }

    $script:call = {
        param([string] $Command, [hashtable] $Splat)

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($Name, $Argument)
            & $Name @Argument
        } $Command $Splat
    }
}

Describe 'Get-HDTShareContentFolder' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTShareContentFolder' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    # THE FIVE CONTENT FOLDERS ARE ALWAYS ROWS, whether or not the share has them
    # yet. A tree that hid Applications because nobody imported one is a tree an
    # administrator cannot tick the day they do.
    It 'roots the tree on the five folders a profile may include from' {
        $folder = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        @($folder | Where-Object { $_.Depth -eq 0 } | ForEach-Object { $_.Path }) |
            Should -Be @('Applications', 'OperatingSystems', 'Drivers', 'TaskSequences', 'Scripts')
    }

    It 'finds the vendor packs two levels down' {
        $folder = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        @($folder | ForEach-Object { $_.Path }) | Should -Contain 'Drivers\WinPE\Dell WinPE 11 x64'
        @($folder | ForEach-Object { $_.Path }) | Should -Contain 'Drivers\WinPE\HP WinPE 11 x64'
    }

    # A PROFILE CANNOT INCLUDE Logs\, so the tree must not offer it. It is where
    # a deployment WRITES, and a boot image built from it would carry every
    # other machine's logs.
    It 'offers nothing a profile is not allowed to include' {
        $folder = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        @($folder | Where-Object { $_.Path -like 'Logs*' }) | Should -BeNullOrEmpty
        @($folder | Where-Object { $_.Path -like 'Control*' }) | Should -BeNullOrEmpty
    }

    It 'lists folders and not the files beside them' {
        $folder = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        @($folder | Where-Object { $_.Path -like '*driver-index.json' }) | Should -BeNullOrEmpty
    }

    It 'says whether each row is actually on the share' {
        $folder = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        @($folder | Where-Object { $_.Path -eq 'Drivers' })[0].Present | Should -BeTrue
        @($folder | Where-Object { $_.Path -eq 'Scripts' })[0].Present | Should -BeFalse
    }

    # A DRIVER STORE IS DEEP AND A TREE IS NOT A FILE BROWSER. The bound is
    # stated rather than silent - see the Truncated flag - because a folder that
    # is simply absent from the tree reads as a folder that is not on the share.
    It 'stops at the depth it was given and says that it did' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\a\b\c\d\e\deep.inf' = '[Version]'
        }

        $folder = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = $fs; Depth = 2 })

        @($folder | ForEach-Object { $_.Path }) | Should -Contain 'Drivers\a\b'
        @($folder | ForEach-Object { $_.Path }) | Should -Not -Contain 'Drivers\a\b\c'
        @($folder | Where-Object { $_.Path -eq 'Drivers\a\b' })[0].Truncated | Should -BeTrue
    }

    It 'does not call a leaf truncated' {
        $folder = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        @($folder | Where-Object { $_.Path -eq 'Drivers\WinPE\Dell WinPE 11 x64' })[0].Truncated | Should -BeFalse
    }
}

Describe 'Get-HDTConsoleSelectionProfileTree' {

    BeforeAll {
        $script:flat = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        $script:buildTree = {
            param([string[]] $Include)

            return @(& $script:call 'Get-HDTConsoleSelectionProfileTree' @{
                    Folder = [object[]] $script:flat
                    Include = [string[]] $Include
                })
        }

        # The tree is nested; most assertions want it flat again.
        function Get-HDTTestFlatNode {
            [CmdletBinding()]
            [OutputType([object])]
            param([Parameter(Mandatory = $true)] [AllowNull()] [object[]] $Node)

            foreach ($current in @($Node)) {
                $current
                if (@($current.Children).Count -gt 0) { Get-HDTTestFlatNode -Node ([object[]] @($current.Children)) }
            }
        }
    }

    It 'hands back roots, with the rest hanging off them as Children' {
        $tree = & $script:buildTree @()

        @($tree | ForEach-Object { $_.Name }) |
            Should -Be @('Applications', 'OperatingSystems', 'Drivers', 'TaskSequences', 'Scripts')
    }

    It 'ticks a folder the profile includes' {
        $tree = & $script:buildTree @('Drivers\WinPE\Dell WinPE 11 x64')
        $node = @(Get-HDTTestFlatNode -Node $tree | Where-Object { $_.Path -eq 'Drivers\WinPE\Dell WinPE 11 x64' })

        $node[0].State | Should -BeTrue
    }

    # AN INCLUDE MEANS THAT FOLDER AND EVERYTHING UNDER IT, so a child of an
    # included folder is ticked even though its own path is not in the list.
    It 'ticks everything under an included folder' {
        $tree = & $script:buildTree @('Drivers\WinPE')
        $node = @(Get-HDTTestFlatNode -Node $tree | Where-Object { $_.Path -eq 'Drivers\WinPE\HP WinPE 11 x64' })

        $node[0].State | Should -BeTrue
    }

    # THE SQUARE. This is the state that says "the two vendor packs, not the 641
    # .inf files in the model folders below" - and it is the one an
    # administrator reads to know they did not tick the whole store by mistake.
    It 'gives a parent a square when only some of it is ticked' {
        $tree = & $script:buildTree @('Drivers\WinPE')
        $node = @(Get-HDTTestFlatNode -Node $tree | Where-Object { $_.Path -eq 'Drivers' })

        $node[0].State | Should -BeNullOrEmpty
    }

    It 'leaves a branch with nothing ticked unticked' {
        $tree = & $script:buildTree @('Drivers\WinPE')
        $node = @(Get-HDTTestFlatNode -Node $tree | Where-Object { $_.Path -eq 'Applications' })

        $node[0].State | Should -BeFalse
    }

    It 'ticks a whole content folder when the profile names it outright' {
        $tree = & $script:buildTree @('Drivers')
        $node = @(Get-HDTTestFlatNode -Node $tree | Where-Object { $_.Path -eq 'Drivers' })

        $node[0].State | Should -BeTrue
    }

    # THE BRANCH AN ADMINISTRATOR IS LOOKING AT OPENS ITSELF. A tree that
    # answered with every branch shut would hide the ticks that are the reason
    # they opened the window.
    It 'opens the branches that lead to something ticked' {
        $tree = & $script:buildTree @('Drivers\WinPE\Dell WinPE 11 x64')

        @($tree | Where-Object { $_.Name -eq 'Drivers' })[0].IsExpanded | Should -BeTrue
        @($tree | Where-Object { $_.Name -eq 'Applications' })[0].IsExpanded | Should -BeFalse
    }

    It 'says on the row when a folder is not on the share' {
        $tree = & $script:buildTree @()
        $node = @($tree | Where-Object { $_.Name -eq 'Scripts' })

        $node[0].Detail | Should -BeLike '*not on the share*'
    }
}

Describe 'Get-HDTConsoleSelectionProfileInclude' {

    BeforeAll {
        $script:flat3 = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        $script:roundTrip = {
            param([string[]] $Include)

            $tree = @(& $script:call 'Get-HDTConsoleSelectionProfileTree' @{
                    Folder = [object[]] $script:flat3; Include = [string[]] $Include
                })

            return @(& $script:call 'Get-HDTConsoleSelectionProfileInclude' @{ Tree = [object[]] $tree })
        }
    }

    # THE ROUND TRIP IS THE CONTRACT. Ticks are drawn from an include list and
    # saved back to one, so opening a profile and pressing Save without touching
    # anything must not change what it means.
    It 'gives back the two vendor packs it was drawn from' {
        & $script:roundTrip @('Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64') |
            Should -Be @('Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64')
    }

    It 'gives back a whole content folder as itself' {
        & $script:roundTrip @('Drivers') | Should -Be @('Drivers')
    }

    It 'answers nothing for a profile that ticks nothing' {
        & $script:roundTrip @() | Should -BeNullOrEmpty
    }

    # AN INCLUDE ALREADY MEANS "and everything under it", so naming a ticked
    # child of a ticked parent as well would be two ways to say one thing.
    It 'never lists a folder underneath one it already listed' {
        $path = @(& $script:roundTrip @('Drivers'))

        @($path | Where-Object { $_ -like 'Drivers\*' }) | Should -BeNullOrEmpty
    }

    # THE ONE THAT WOULD SILENTLY CHANGE A PROFILE'S MEANING. Drivers\WinPE has
    # exactly two children; ticking both must NOT collapse into 'Drivers\WinPE',
    # because that folder would then swallow a third vendor pack dropped in next
    # month - into a boot image, unasked.
    It 'does not collapse every child up into the parent' {
        $path = @(& $script:roundTrip @('Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64'))

        $path | Should -Not -Contain 'Drivers\WinPE'
        @($path).Count | Should -Be 2
    }
}

Describe 'ConvertTo-HDTSelectionProfileId' {

    BeforeAll {
        $script:slug = {
            param([string] $Name)

            $module = Get-Module -Name Hephaestus
            return & $module { param($Text) ConvertTo-HDTSelectionProfileId -Name $Text } $Name
        }
    }

    # A PROFILE HAS TWO NAMES AND ONLY ONE IS TYPED. Asking an administrator to
    # invent the slug as well is asking for a field people leave wrong.
    It 'turns what was typed into something a document can carry' {
        & $script:slug 'Boot critical - Dell and HP' | Should -BeExactly 'boot-critical-dell-and-hp'
    }

    It 'collapses a run of separators rather than leaving four dashes' {
        & $script:slug 'Dell  /  HP' | Should -BeExactly 'dell-hp'
    }

    It 'keeps digits, because a version is part of a name' {
        & $script:slug 'HP WinPE 11 x64' | Should -BeExactly 'hp-winpe-11-x64'
    }

    It 'lower-cases, because an id is compared' {
        & $script:slug 'DELL' | Should -BeExactly 'dell'
    }

    # THE PATTERN DEMANDS A LETTER OR A DIGIT FIRST, and a name that starts with
    # punctuation would otherwise produce an id the validator refuses.
    It 'never starts or ends with a dash' {
        & $script:slug '- Dell -' | Should -BeExactly 'dell'
    }

    It 'answers empty rather than inventing a name nobody chose' {
        & $script:slug '???' | Should -BeExactly ''
        & $script:slug '' | Should -BeExactly ''
    }

    It 'produces an id Assert-HDTSelectionProfileDocument would accept' {
        foreach ($name in @('Boot critical - Dell and HP', 'HP WinPE 11 x64', 'Dell  /  HP')) {
            & $script:slug $name | Should -Match '^[A-Za-z0-9][A-Za-z0-9_.-]*$'
        }
    }
}

Describe 'Get-HDTConsoleSelectionProfileSetting' {

    BeforeAll {
        $script:profileList = @(
            [pscustomobject] @{
                Id = 'boot-critical'; Name = 'Boot critical - Dell and HP'
                Include = [string[]] @('Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64')
                IsBuiltIn = $false; Path = 'C:\HDTLab\Share\Control\selection-profiles.yaml'
            }
            [pscustomobject] @{
                Id = 'everything'; Name = 'Everything'
                Include = [string[]] @('Applications', 'OperatingSystems', 'Drivers', 'TaskSequences', 'Scripts')
                IsBuiltIn = $true; Path = ''
            }
        )

        $script:flat2 = @(& $script:call 'Get-HDTShareContentFolder' @{ Root = $script:root; FileSystem = (New-HDTTestShareFileSystem) })

        $script:ask = {
            param([string] $Id)

            return & $script:call 'Get-HDTConsoleSelectionProfileSetting' @{
                Root = $script:root
                SelectionProfile = [object[]] $script:profileList
                Folder = [object[]] $script:flat2
                SelectedId = $Id
            }
        }
    }

    It 'lists every profile the share has, built-ins included' {
        $view = & $script:ask 'boot-critical'

        @($view.Profile | ForEach-Object { $_.Id }) | Should -Be @('boot-critical', 'everything')
    }

    It 'says how many paths each profile carries, under its name' {
        $view = & $script:ask 'boot-critical'
        $row = @($view.Profile | Where-Object { $_.Id -eq 'boot-critical' })

        $row[0].Detail | Should -BeLike '2 paths*'
    }

    # A BUILT-IN CANNOT BE RENAMED OR DELETED, and the window has to know before
    # it enables the buttons rather than after the command refuses.
    It 'marks a built-in as one so the buttons can go grey' {
        $view = & $script:ask 'everything'

        @($view.Profile | Where-Object { $_.Id -eq 'everything' })[0].IsBuiltIn | Should -BeTrue
        $view.CanEdit | Should -BeFalse
    }

    It 'lets an authored profile be edited' {
        $view = & $script:ask 'boot-critical'

        $view.CanEdit | Should -BeTrue
    }

    It 'builds the tree against the selected profile' {
        $view = & $script:ask 'boot-critical'
        $drivers = @($view.Tree | Where-Object { $_.Name -eq 'Drivers' })

        # Two of its grandchildren, not all of it.
        $drivers[0].State | Should -BeNullOrEmpty
    }

    It 'carries the command Save would run' {
        $view = & $script:ask 'boot-critical'

        $view.SaveCommandFormat | Should -BeLike '*Set-HDTSelectionProfile*'
    }

    It 'names the document every button writes to' {
        $view = & $script:ask 'boot-critical'

        $view.DocumentPath | Should -BeExactly 'C:\HDTLab\Share\Control\selection-profiles.yaml'
    }

    # A SHARE WITH NOTHING SELECTED IS THE FIRST-RUN CASE, not an error: the
    # window opens before anybody has clicked a row.
    It 'answers with an empty tree and no edit when nothing is selected' {
        $view = & $script:ask ''

        $view.CanEdit | Should -BeFalse
        @($view.Tree) | Should -BeNullOrEmpty
    }
}
