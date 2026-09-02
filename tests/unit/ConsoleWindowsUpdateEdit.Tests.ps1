# EDITING AN IMPORTED UPDATE FROM THE CONSOLE, asserted with no window.
#
# The pane showed an update as a report and nothing on it could be changed - so
# an administrator who mistyped a name at import, or who left the description
# box blank and later wanted a note, had no way back to either. Every other
# catalog in this window has had that for milestones: a sequence, an operating
# system, a share and an application all write their own document from the
# details pane, and updates were the one that did not.
#
# TWO ROWS AND NO MORE. Everything else in update.yaml was read out of the
# package's own CompDB metadata - the kb, the kind, the architecture, the builds
# - and a pane that let those be typed over would turn a catalog of measured
# facts into a catalog of guesses. The id is left alone for a harder reason: it
# is the folder name under WindowsUpdates\, so changing it is a move.
#
# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:workspaceYaml = "schemaVersion: 1`nid: HDT`nname: HDT share`n"

    # The shape the real share carries, from C:\HDTLab\Share - imported with the
    # description box left blank, which is the case that sent somebody looking
    # for a way to add one afterwards.
    $script:updateYaml = @'
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

    $script:newFileSystem = {
        New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                                              = $script:workspaceYaml
            'C:\ws\WindowsUpdates\KB5094126-x64\update.yaml'                    = $script:updateYaml
            'C:\ws\WindowsUpdates\KB5094126-x64\windows11.0-kb5094126-x64.msu'  = 'not really an msu'
        }
    }
}

Describe 'the details pane for an imported update' {

    BeforeAll {
        $script:share = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (& $script:newFileSystem)
        $script:node = @(Get-HDTConsoleShareNode -Workspace $script:share)
        $script:row = @($script:node | Where-Object { [string] $_.Kind -eq 'WindowsUpdate' })[0]
    }

    It 'draws the update it read' {
        $script:row | Should -Not -BeNullOrEmpty
        [string] $script:row.Name | Should -BeExactly 'KB5094126-x64'
    }

    # THE ROW WAS THERE AND READ-ONLY. Set-HDTWindowsUpdate writes it.
    It 'lets the name be typed' {
        $name = @($script:row.Field | Where-Object { [string] $_.Label -eq 'Name' })[0]

        $name.Editable | Should -BeTrue
        [string] $name.Property | Should -BeExactly 'name'
    }

    # THERE WAS NO ROW AT ALL, which is the half-feature: the import dialog
    # collects a description, update.yaml declares one and the schema allows it,
    # and the pane showed it nowhere - so a description typed at import was
    # invisible for ever afterwards.
    It 'shows a description, which the pane never had' {
        $description = @($script:row.Field | Where-Object { [string] $_.Label -eq 'Description' })

        $description.Count | Should -Be 1
        $description[0].Editable | Should -BeTrue
        [string] $description[0].Property | Should -BeExactly 'description'
    }

    It 'shows the description a document carries' {
        $fileSystem = & $script:newFileSystem
        $fileSystem.WriteAllText('C:\ws\WindowsUpdates\KB5094126-x64\update.yaml',
            ($script:updateYaml -replace 'release: Win11-24H2',
                "description: Held back until the June window.`nrelease: Win11-24H2"))

        $described = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fileSystem
        $drawn = @(Get-HDTConsoleShareNode -Workspace $described |
                Where-Object { [string] $_.Kind -eq 'WindowsUpdate' })[0]

        [string] @($drawn.Field | Where-Object { [string] $_.Label -eq 'Description' })[0].Value |
            Should -BeExactly 'Held back until the June window.'
    }

    # THE SET, NOT THE TWO THAT WERE ADDED. Everything else on this pane came out
    # of the package's own metadata, and the id is a folder name - so a row that
    # becomes typeable later has to be a deliberate change to this list rather
    # than something that arrives unnoticed.
    It 'lets nothing else on the pane be typed' {
        $typeable = @($script:row.Field | Where-Object { $_.Editable } |
                ForEach-Object { [string] $_.Property })

        @($typeable | Sort-Object) | Should -Be @('description', 'name')
    }

    It 'keeps the id, the kb and the release read-only, because they are not labels' {
        foreach ($label in @('KB', 'Id', 'Release', 'Kind', 'Architecture', 'Package')) {
            $field = @($script:row.Field | Where-Object { [string] $_.Label -eq $label })[0]

            $field.ReadOnly | Should -BeTrue -Because ("{0} is not an administrator's own words" -f $label)
        }
    }

    # AN UNREADABLE DOCUMENT IS STILL A ROW, and it must not offer to edit a file
    # nothing could parse: the write path reads, splices and validates, so a
    # rename typed here would be refused with the parse error rather than the
    # reason.
    It 'offers no edit on an update that would not parse' {
        $fileSystem = & $script:newFileSystem
        $fileSystem.WriteAllText('C:\ws\WindowsUpdates\KB5094126-x64\update.yaml', "schemaVersion: 1`nid: KB5094126-x64`n")

        $broken = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fileSystem
        $drawn = @(Get-HDTConsoleShareNode -Workspace $broken |
                Where-Object { [string] $_.Kind -eq 'WindowsUpdate' })[0]

        @($drawn.Field | Where-Object { $_.Editable }).Count | Should -Be 0
    }
}

}
