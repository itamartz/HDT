# THE WHOLE SUBTREE OF ONE SHARE, ROW BY ROW, IN THE ORDER IT IS DRAWN.
#
# WHY A GOLDEN LIST RATHER THAN SEVEN SEPARATE ASSERTIONS. Get-HDTConsoleShareNode
# is the one place every category's rows are produced, and the thing that breaks
# when it is reorganised is not any single row - it is the ORDER of the rows
# between the categories, and the agreement between the two shapes the function
# emits. A test per category passes happily while the categories have swapped
# places; this one does not.
#
# TWO SHAPES, ONE PASS, AND THEY MUST AGREE. The command returns a FLAT list in
# display order, and every row is also wired into its parent's Children so the
# window has a tree to expand. Nothing asserted that walking the tree reproduces
# the flat list, which is the invariant the file's own comment claims and the one
# a reorganisation of it can silently break: a category that forgets to add its
# rows to the flat reading still draws correctly in the window, and a caller
# counting rows - the selection lookup, the expansion state - finds the branch
# missing.
#
# IT NAMES NO HELPER. The rows are the behaviour; how many functions produce them
# is not.
#
# THE COMMAND UNDER TEST IS PRIVATE, so this file runs in module scope.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # EVERY CATEGORY WITH SOMETHING IN IT, AND THE FOLDER CASE IN THREE OF THEM.
    # A fixture where only one category has content proves nothing about the
    # order of the rest.
    $script:file = @{
        'C:\ws\workspace.yaml'                          = @'
schemaVersion: 1
id: HDT-LAB
name: HDT deployment share
deployRoot: \\hdt-share\HDTShare
logLevel: Info
folders:
  taskSequences:
    - Clients
  operatingSystems:
    - Media
  applications:
    - Utilities
bootImage:
  name: HDTPE_x64
  architecture: amd64
  language: en-us
'@

        'C:\ws\Control\selection-profiles.yaml'         = @'
schemaVersion: 1
profiles:
  - id: winpe-drivers
    name: WinPE drivers
    include:
      - Drivers\WinPE
'@

        'C:\ws\Control\os-releases.yaml'                = @'
schemaVersion: 1
releases:
  - id: Win11-24H2
    name: Windows 11 24H2
    build: 26100
    verified: true
    note: Read off the LTSC 2024 media in this lab.
  - id: WS2025
    name: Windows Server 2025
    verified: false
'@

        'C:\ws\Applications\7Zip-24.09\app.yaml'        = @'
schemaVersion: 1
id: 7Zip-24.09
name: 7-Zip 24.09 x64
folder: Utilities
install: msiexec.exe /i "7z2409-x64.msi" /qn /norestart
runIn: FullOS
'@
        'C:\ws\Applications\Contoso-Suite\app.yaml'     = @'
schemaVersion: 1
id: Contoso-Suite
name: Contoso Suite
install: setup.exe /quiet
'@

        'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml' = @'
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
type: wim
architecture: x64
folder: Media
sourcePath: sources\install.wim
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
    edition: EnterpriseS
    version: 10.0.26100.1742
'@

        'C:\ws\WindowsUpdates\KB5094126-x64\update.yaml' = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: KB5094126 for Windows 11 24H2
release: Win11-24H2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
sizeBytes: 5111500010
baselineVersion: 10.0.26100.1742
targetVersion: 10.0.26100.8655
build: 26100
revision: 8655
enabled: true
'@
        'C:\ws\WindowsUpdates\KB5094126-x64\windows11.0-kb5094126-x64.msu' = 'not really an msu'

        'C:\ws\WindowsUpdates\KB5099999-x64\update.yaml' = @'
schemaVersion: 1
id: KB5099999-x64
kb: KB5099999
name: KB5099999 for Windows Server 2025
release: WS2025
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5099999-x64.msu
sizeBytes: 6111500010
baselineVersion: 10.0.26100.1742
targetVersion: 10.0.26100.8655
build: 26100
revision: 8655
enabled: true
'@
        'C:\ws\WindowsUpdates\KB5099999-x64\windows11.0-kb5099999-x64.msu' = 'not really an msu'

        # A TWO-LEVEL DRIVER STORE, because a flat one cannot show whether the
        # nesting survived.
        'C:\ws\Drivers\WinPE\Dell\e1000.inf'            = '[Version]'
        'C:\ws\Drivers\Clients\hd.inf'                  = '[Version]'

        'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'     = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
folder: Clients
steps:
  - name: Validate
    type: Validate
'@
        'C:\ws\TaskSequences\PNP-TEST\sequence.yaml'    = @'
schemaVersion: 1
id: PNP-TEST
name: Plug and play test
steps:
  - name: Validate
    type: Validate
'@

        'C:\ws\Media\WIN11-FIELD\media.yaml'            = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field build
selectionProfile: winpe-drivers
output: Media\WIN11-FIELD\HDT-WIN11-FIELD.iso
enabled: true
'@
    }

    $script:share = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File $script:file)
    $script:flat = @(Get-HDTConsoleShareNode -Workspace $script:share)

    # HOW A ROW IS IDENTIFIED HERE: the three things a window routes on. Text is
    # deliberately not among them - it carries counts and labels somebody may
    # reword, and this test is about identity and place, not wording.
    $script:describe = {
        param($Row)
        return '{0}|{1}|{2}' -f [int] $Row.Depth, [string] $Row.Kind, [string] $Row.Name
    }

    # PARENTS BEFORE THEIR CHILDREN, which is the order the tree draws.
    $script:walkFrom = {
        param($Row)

        $seen = New-Object -TypeName System.Collections.ArrayList

        $walk = {
            param($Current)

            [void] $seen.Add($Current)
            foreach ($child in @($Current.Children)) { & $walk $child }
        }

        & $walk $Row
        return [object[]] @($seen)
    }
}

Describe 'the rows one share draws' {

    # THE GOLDEN LIST. Every row, in the order the tree draws it. A change here is
    # a change an administrator sees, so it has to be a deliberate edit to this
    # list rather than something a reorganisation slid past.
    It 'draws every category and every row under it in the order a share is built' {
        @($script:flat | ForEach-Object { & $script:describe $_ }) | Should -Be @(
            '1|Share|HDT deployment share (HDT-LAB)'

            '2|Category|BootImage'
            '3|BootImage|HDTPE_x64 - not built'

            '2|Category|Applications'
            '3|Folder|Utilities'
            '4|Application|7Zip-24.09'
            '3|Application|Contoso-Suite'

            '2|Category|OperatingSystems'
            '3|Folder|Media'
            '4|OperatingSystem|Win11-LTSC-2024 - Windows 11 Enterprise LTSC 2024'

            '2|Category|WindowsUpdates'
            '3|UpdateRelease|Win11-24H2'
            '4|WindowsUpdate|KB5094126-x64'
            '3|UpdateRelease|WS2025'
            '4|WindowsUpdate|KB5099999-x64'

            '2|Category|Drivers'
            '3|DriverFolder|Drivers\Clients'
            '3|DriverFolder|Drivers\WinPE'
            '4|DriverFolder|Drivers\WinPE\Dell'

            '2|Category|TaskSequences'
            '3|Folder|Clients'
            '4|TaskSequence|DEMO-M4'
            '3|TaskSequence|PNP-TEST'

            # THE BUILT-IN PROFILES ARE ROWS TOO, and they come before the
            # authored one - the engine answers them, so every share has them.
            '2|Category|SelectionProfiles'
            '3|SelectionProfile|all-drivers'
            '3|SelectionProfile|everything'
            '3|SelectionProfile|winpe-drivers'

            '2|Category|Media'
            '3|Media|WIN11-FIELD'

            '2|MonitorCategory|Monitoring'
            '3|Empty|There is no deployment running on this share.'
        )
    }

    # THE INVARIANT THE FILE CLAIMS: the flat list is the display order, and every
    # row is also in its parent's Children. Walking the tree from the share must
    # therefore reproduce the flat list exactly - same rows, same order.
    It 'wires the same rows into the tree that it returns in the flat reading' {
        @((& $script:walkFrom $script:flat[0]) | ForEach-Object { & $script:describe $_ }) |
            Should -Be @($script:flat | ForEach-Object { & $script:describe $_ })
    }

    It 'wires the very objects it returned rather than copies of them' {
        foreach ($current in @($script:flat[0].Children)) {
            @($script:flat | Where-Object { [object]::ReferenceEquals($_, $current) }).Count |
                Should -Be 1 -Because 'a copy in the tree is a row the flat reading cannot find'
        }
    }
}

Describe 'what a window can act on' {

    # THE ACTIONS ARE ROUTED ON Name AND Subject. A category that loses its Name
    # loses the menu item hung off it; one that loses its Subject keeps the menu
    # item and the handler does nothing, which is worse. Both have happened.
    It 'gives every category the name and the subject its menu needs' {
        $subjectOf = {
            param([string] $Name)

            $row = @($script:flat | Where-Object { [string] $_.Name -eq $Name })[0]
            if ($null -eq $row.PSObject.Properties['Subject'] -or $null -eq $row.Subject) { return '(none)' }
            if ($row.Subject -is [string]) { return [string] $row.Subject }
            return $row.Subject.GetType().Name
        }

        & $subjectOf 'BootImage' | Should -BeExactly 'C:\ws\workspace.yaml'
        & $subjectOf 'Applications' | Should -BeExactly '(none)'
        & $subjectOf 'OperatingSystems' | Should -BeExactly '(none)'
        & $subjectOf 'WindowsUpdates' | Should -BeExactly 'PSCustomObject'
        & $subjectOf 'Drivers' | Should -BeExactly 'C:\ws'
        & $subjectOf 'TaskSequences' | Should -BeExactly '(none)'
        & $subjectOf 'SelectionProfiles' | Should -BeExactly 'C:\ws'
    }

    # EVERY ROW ECHOES THE COMMAND THAT PRODUCED IT - DESIGN 12, and the reason
    # the console is a teaching surface rather than a black box.
    It 'gives every row the module command that produced it' {
        foreach ($row in $script:flat) {
            [string] $row.Command | Should -Not -BeNullOrEmpty
            [string] $row.Command | Should -Match 'HDT'
        }
    }

    It 'names the real read behind each category' {
        $commandOf = {
            param([string] $Name)
            return [string] @($script:flat | Where-Object { [string] $_.Name -eq $Name })[0].Command
        }

        & $commandOf 'Applications' | Should -BeExactly "Get-HDTApplication -WorkspaceRoot 'C:\ws'"
        & $commandOf 'OperatingSystems' | Should -BeExactly "Get-HDTWorkspacePath -Root 'C:\ws' -Kind OperatingSystems"
        & $commandOf 'WindowsUpdates' | Should -BeExactly "Get-HDTWindowsUpdate -WorkspaceRoot 'C:\ws'"
        & $commandOf 'Drivers' | Should -BeExactly "Get-HDTWorkspacePath -Root 'C:\ws' -Kind Drivers"
        & $commandOf 'TaskSequences' | Should -BeExactly "Get-HDTWorkspacePath -Root 'C:\ws' -Kind TaskSequences"
    }
}

Describe 'a share with nothing on it' {

    BeforeAll {
        $script:bare = Get-HDTConsoleWorkspace -Path 'C:\bare' -FileSystem (New-HDTFakeFileSystem -File @{
                'C:\bare\workspace.yaml' = "schemaVersion: 1`nid: BARE`nname: Bare share`n"
            })

        $script:bareFlat = @(Get-HDTConsoleShareNode -Workspace $script:bare)
    }

    # AN EMPTY CATEGORY SAYS SO. A branch that draws nothing reads as a branch
    # nobody has looked at, and the row is where the "add one with..." sentence
    # lives.
    It 'puts a row under every category that has nothing in it' {
        @($script:bareFlat | ForEach-Object { '{0}|{1}' -f [int] $_.Depth, [string] $_.Kind }) | Should -Be @(
            '1|Share'
            '2|Category'; '3|BootImage'
            '2|Category'; '3|Empty'
            '2|Category'; '3|Empty'
            '2|Category'; '3|Empty'
            '2|Category'; '3|Empty'
            '2|Category'; '3|Empty'
            '2|Category'; '3|SelectionProfile'; '3|SelectionProfile'
            '2|Category'; '3|Empty'
            '2|MonitorCategory'; '3|Empty'
        )
    }

    It 'still agrees with its own tree' {
        @(& $script:walkFrom $script:bareFlat[0]).Count | Should -Be @($script:bareFlat).Count
    }
}

Describe 'a share that would not open' {

    It 'is one row that says which path failed, and no categories' {
        $failure = New-HDTConsoleShareFailure -Path 'C:\gone' -Message 'The network path was not found.'
        $row = @(Get-HDTConsoleShareNode -Workspace $failure)

        @($row).Count | Should -Be 1
        [string] $row[0].Kind | Should -BeExactly 'Share'
        [string] $row[0].Status | Should -BeExactly 'Error'
        [string] $row[0].Text | Should -BeExactly 'C:\gone - (could not be opened)'
    }
}

}
