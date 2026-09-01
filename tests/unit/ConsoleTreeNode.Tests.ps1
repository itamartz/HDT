# C1's second half: everything the window puts on the screen, decided in a
# command and asserted with no window.
#
# WHY THIS COMMAND EXISTS AT ALL. Show-HDTConsole hands an injected IConsoleHost
# a list of rows and the host adds them to a control. If the host built those
# rows itself - looping over sequences, formatting a hash, deciding what a share
# with no boot image says - then the only thing that could ever check the
# console's output would be a human looking at a screen. Every one of those
# decisions is here instead, which is what leaves New-HDTConsoleHost branch-free
# and therefore honestly exempt from TDD (CLAUDE.md rule 1).
#
# THE COMMAND LINE IS PART OF THE OUTPUT, NOT DECORATION. DESIGN 12: "the
# console may not do anything the cmdlets can't. Every action it performs maps
# to a cmdlet invocation, and the console shows that invocation - so an admin can
# learn the automation surface by clicking around". Every row therefore carries
# the module call that produced it, and these tests assert the call is the real
# one rather than a plausible-looking string.

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

    $script:root = 'C:\ws'

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\192.168.2.108\HDTShare
logLevel: Debug
credential:
  username: LAP-AMMSO01\svc-hdt-deploy
bootImage:
  name: HDTPE_x64
  architecture: amd64
  language: en-us
'@

    $script:sequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
description: The M4 exit criterion, as a sequence.
steps:
  - name: Validate
    type: Validate
  - name: Apply OS
    type: ApplyImage
    operatingSystem: Win11-LTSC-2024
'@

    # THE REAL SHAPE OF A DEPLOYMENT SEQUENCE: groups, an ordered run, a
    # condition, a step that may fail, and per-type properties. DEMO-M4 on the
    # lab share is this shape, which is why the tree has to render it rather
    # than a flat list of names.
    $script:groupedSequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
description: The M4 exit criterion, as a sequence.
steps:
  - group: Preinstall
    runIn: WinPE
    steps:
      - name: Validate
        type: Validate
        minRamMB: 2048
        minDiskGB: 60
      - name: Format and Partition
        type: DiskPartition
        layout: uefi-standard
        wipe: true
  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
        os: Win11-LTSC-2024
        index: 1
        target: primary
      - name: Prepare Boot
        type: ConfigureBoot
        continueOnError: true
'@

    $script:osYaml = @'
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
type: wim
architecture: x64
sourcePath: sources\install.wim
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
    edition: EnterpriseS
    version: 10.0.26100.1742
'@

    $script:wimHash = '901369F6F7B4A1D0C7AAA2DCE05B7FB89E5BF5AB51C5FDC0FFF40BD18D1B3507'
    $script:isoHash = 'D2B59F9615F91C00BB234C98CF558C06DF01EEDD06F0A8D2F4073BC2CA3792FA'

    $script:manifestJson = @'
{
  "schemaVersion": 1,
  "buildId": "a9931133-89d9-4784-824c-c96f5519805e",
  "builtUtc": "2026-08-14T07:13:25Z",
  "builtOn": "LAP-AMMSO01",
  "engineVersion": "0.1.0",
  "architecture": "amd64",
  "language": "en-us",
  "artifacts": {
    "wim": { "path": "C:\\ws\\Boot\\HDTPE_x64.wim", "sha256": "901369F6F7B4A1D0C7AAA2DCE05B7FB89E5BF5AB51C5FDC0FFF40BD18D1B3507", "sizeBytes": 495334205 },
    "iso": { "path": "C:\\ws\\Boot\\HDTPE_x64.iso", "sha256": "D2B59F9615F91C00BB234C98CF558C06DF01EEDD06F0A8D2F4073BC2CA3792FA", "sizeBytes": 550909952 },
    "isoBootWimSha256": "901369F6F7B4A1D0C7AAA2DCE05B7FB89E5BF5AB51C5FDC0FFF40BD18D1B3507"
  }
}
'@

    function New-HDTConsoleNodeTestModel {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a projection from an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()]
            [switch] $Empty
        )

        $file = @{ 'C:\ws\workspace.yaml' = $script:workspaceYaml }

        if (-not $Empty) {
            $file['C:\ws\TaskSequences\DEMO-M4\sequence.yaml'] = $script:sequenceYaml
            $file['C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml'] = $script:osYaml
            $file['C:\ws\Boot\HDTPE_x64.manifest.json'] = $script:manifestJson
        }

        return Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTFakeFileSystem -File $file)
    }

    # One share holding the GROUPED sequence, for the step rows.
    function New-HDTConsoleStepTestModel {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a projection from an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()]
            [ValidateNotNullOrEmpty()]
            [string] $Root = 'C:\ws'
        )

        return Get-HDTConsoleWorkspace -Path $Root -FileSystem (New-HDTFakeFileSystem -File @{
                ('{0}\workspace.yaml' -f $Root)                             = $script:workspaceYaml
                ('{0}\TaskSequences\DEMO-M4\sequence.yaml' -f $Root)        = $script:groupedSequenceYaml
            })
    }
}

# A COLOURED ICON IS THE ONE THING ON THIS SCREEN READ WITHOUT READING. The tree
# is a wall of near-identical rows; colour is what lets somebody find the broken
# one from across a desk, and it is why every console that shows machine state
# has some.
#
# THE COLOURS ARE LITERALS, NOT THEME RESOURCES, and that is deliberate. Every
# other colour in these windows is a DynamicResource so Get-HDTConsoleTheme can
# repaint it; these cannot be, because WPF resolves a DynamicResource by key at
# parse time and a per-ROW key would need a converter the markup has nowhere to
# load from (see the note in New-HDTConsoleField about IsReadOnly). They are
# therefore chosen to read on both palettes: mid-tone and saturated, dark enough
# for white and light enough for the dark panel.
#
# MEANING BEFORE DECORATION. Red is the only colour that means something is
# wrong, and nothing else is allowed to use it - a screen where four things are
# red is a screen where red means nothing.

# PRIVATE, SO EVERY ASSERTION RUNS INSIDE THE MODULE'S OWN SCOPE - and InModuleScope
# goes INSIDE each It, not around the Describes. Pester expands the file during
# DISCOVERY, before any BeforeAll has run, so a module-scoped block at file level
# is entered before the module has been imported: the whole file then discovers
# nothing and reports a green run of zero tests.
Describe 'Get-HDTConsoleIconColor' {

    It 'gives anything broken the same red, whatever kind it is' {
      InModuleScope 'Hephaestus' {
        # A technician scanning for trouble must not have to learn a palette.
        foreach ($kind in @('Share', 'TaskSequence', 'OperatingSystem', 'BootImage', 'MonitorRun')) {
            Get-HDTConsoleIconColor -Kind $kind -Status 'Error' | Should -BeExactly '#FFC42B1C'
        }
      }
    }

    It 'gives a missing thing amber rather than red, because absent is not broken' {
      InModuleScope 'Hephaestus' {
          Get-HDTConsoleIconColor -Kind 'BootImage' -Status 'Missing' | Should -BeExactly '#FFB77400'
      }
    }

    It 'gives a healthy deployment green, which is the only place green is used' {
      InModuleScope 'Hephaestus' {
          Get-HDTConsoleIconColor -Kind 'MonitorRun' -Status 'Ok' | Should -BeExactly '#FF107C10'
      }
    }

    It 'gives the structural rows the console blue' {
      InModuleScope 'Hephaestus' {
        Get-HDTConsoleIconColor -Kind 'Root' -Status 'Ok' | Should -BeExactly '#FF0E639C'
        Get-HDTConsoleIconColor -Kind 'Share' -Status 'Ok' | Should -BeExactly '#FF0E639C'
        Get-HDTConsoleIconColor -Kind 'Category' -Status 'Ok' | Should -BeExactly '#FF0E639C'
      }
    }

    It 'leaves an empty row grey, so a placeholder does not compete with content' {
      InModuleScope 'Hephaestus' {
          Get-HDTConsoleIconColor -Kind 'Empty' -Status 'Ok' | Should -BeExactly '#FF767676'
      }
    }

    It 'answers for every kind a node can be, so no row is left without one' {
      InModuleScope 'Hephaestus' {
        $kind = @((Get-Command -Name 'New-HDTConsoleNode').Parameters['Kind'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues

        foreach ($current in @($kind)) {
            Get-HDTConsoleIconColor -Kind $current -Status 'Ok' | Should -Match '^#FF[0-9A-F]{6}$'
        }
      }
    }
}

Describe 'a node and its icon colour' {

    It 'carries the colour beside the glyph, so the window binds and decides nothing' {
        $node = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel))

        foreach ($row in $node) {
            $row.IconColor | Should -Match '^#FF[0-9A-F]{6}$'
        }
    }
}

Describe 'Get-HDTConsoleTreeNode' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTConsoleTreeNode' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Get-HDTConsoleTreeNode').Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the tree a technician reads' {

        BeforeAll {
            $script:node = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel))
        }

        It 'opens with the Deployment Shares root, then the share, then the eight categories' {
            # Workbench's shape: the root is there with one share as well as with
            # six, so the console does not change layout as shares are added.
            @($script:node | Where-Object { $_.Depth -le 2 } | ForEach-Object { $_.Kind }) |
                Should -Be @('Root', 'Share', 'Category', 'Category', 'Category', 'Category', 'Category', 'Category', 'Category', 'MonitorCategory')
        }

        It 'orders the categories the way a share is built, not alphabetically' {
            # Boot image, then the applications and the OS it lays down, then
            # the drivers that make it work on the hardware, then the task
            # sequence that ties them together - which is the only one that
            # cannot be written first.
            #
            # APPLICATIONS SIT DIRECTLY UNDER THE BOOT IMAGE because that is
            # where the work is: media is imported once and sequences are
            # written once, and the application list moves every time somebody
            # ships a new version.
            @($script:node | Where-Object { $_.Kind -in 'Category', 'MonitorCategory' } | ForEach-Object { $_.Text }) |
                Should -Be @('Boot Image', 'Applications (0)', 'Operating Systems (1)', 'Windows Updates (0)', 'Drivers', 'Task Sequences (1)', 'Selection Profiles (2)', 'Monitoring')
        }

        It 'counts the shares on the root row' {
            @($script:node | Where-Object { $_.Kind -eq 'Root' })[0].Text |
                Should -BeExactly 'Deployment Shares (1)'
        }

        It 'counts what is under each category that has a count' {
            $category = @($script:node | Where-Object { $_.Kind -in 'Category', 'MonitorCategory' } | ForEach-Object { $_.Text })

            $category | Should -Contain 'Task Sequences (1)'
            $category | Should -Contain 'Operating Systems (1)'
        }

        # THIS ROW USED TO READ '(not supported yet)' AND IT WAS TRUE: nothing
        # could read the folder and nothing could inject from it. Both exist now
        # - Import-HDTDriver fills it, a selection profile names a folder in it,
        # and Update-HDTBootImage injects that folder - so the branch says what
        # is actually there and how to put something in it.
        It 'says what the driver store has, and how to fill it when it has nothing' {
            $driver = @($script:node | Where-Object { $_.Text -like '(no *' -and $_.Kind -eq 'Empty' })[0]

            $driver | Should -Not -BeNullOrEmpty
            $driver.Detail | Should -Match 'Right-click Drivers'
            $driver.Detail | Should -Match ([regex]::Escape('C:\ws\Drivers'))
            # THE COMMAND IS THE READ THAT PRODUCED THE ROW, which is DESIGN 12's
            # rule. It used to echo an Import-HDTDriver line with
            # '<the extracted pack>' in it - a placeholder, so not runnable, and
            # not what produced the row either. What to DO is in the detail.
            $driver.Command | Should -BeLike '*Get-HDTWorkspacePath*Drivers*'
        }

        It 'indents by depth, so a flat list reads as a tree' {
            $root = @($script:node | Where-Object { $_.Kind -eq 'Root' })[0]
            $share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $root.Depth | Should -Be 0
            $root.Display | Should -BeExactly $root.Text

            $share.Depth | Should -Be 1
            $share.Display | Should -Match '^\s{4}\S'

            $sequence.Depth | Should -Be 3
            $sequence.Display | Should -Match '^\s{12}\S'
            $sequence.Display.Trim() | Should -BeExactly $sequence.Text
        }

        It 'puts the deployRoot on the share row, because that is the one fact a wrong share looks like' {
            $share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]

            $share.Text | Should -Match 'HDT deployment share'
            $share.Detail | Should -Match ([regex]::Escape('\\192.168.2.108\HDTShare'))
            $share.Detail | Should -Match ([regex]::Escape('C:\ws'))
        }

        # DESIGN 12's inline validation, on the one document that had none.
        # rules.yaml belongs to the SHARE - it is what CustomSettings.ini was -
        # so a broken one breaks every deployment from it rather than one task
        # sequence, and the share row is where that has to show.
        It 'says on the share row how many rules the share carries' {
            $share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]

            $share.Detail | Should -Match 'Rules'
        }

        # A SHARE WITH NO RULES FILE IS NOT A BROKEN ONE. Every variable falls
        # to its default, which is a share nobody has configured yet - and that
        # is every new share, so drawing it red would make red mean nothing.
        It 'leaves a share with no rules file alone' {
            $share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]

            $share.Status | Should -BeExactly 'Ok'
        }

        It 'marks the share when its rules document will not parse' {
            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTFakeFileSystem -File @{
                    'C:\ws\workspace.yaml' = $script:workspaceYaml
                    'C:\ws\rules.yaml'     = "schemaVersion: 1`nrules:`n  - name: Nothing to set`n"
                })

            $node = @(Get-HDTConsoleTreeNode -Workspace @($model))
            $share = @($node | Where-Object { $_.Kind -eq 'Share' })[0]

            $share.Status | Should -BeExactly 'Error'
            $share.Detail | Should -Match 'Rules'
        }

        It 'nests the rows, so the window can expand and collapse them' {
            $root = @($script:node | Where-Object { $_.Kind -eq 'Root' })[0]
            $share = @($root.Children)[0]

            $share.Kind | Should -BeExactly 'Share'
            @($share.Children | ForEach-Object { $_.Text }) |
                Should -Be @('Boot Image', 'Applications (0)', 'Operating Systems (1)', 'Windows Updates (0)', 'Drivers', 'Task Sequences (1)', 'Selection Profiles (2)', 'Monitoring')

            # THE INDICES MOVED ON 2026-09-01, when Windows Updates went in at
            # position 3 - between Operating Systems and Drivers, where the order
            # a share is built puts it.
            @($share.Children)[0].Children[0].Kind | Should -BeExactly 'BootImage'
            @($share.Children)[5].Children[0].Kind | Should -BeExactly 'TaskSequence'
            @($share.Children)[6].Children[0].Kind | Should -BeExactly 'SelectionProfile'
            @($share.Children)[7].Children[0].Kind | Should -BeExactly 'Empty'          # Monitoring, with nothing running
        }

        It 'opens every branch that has one, because C1 is one screen and not a search' {
            foreach ($row in @($script:node | Where-Object { @($_.Children).Count -gt 0 })) {
                $row.IsExpanded | Should -BeTrue -Because $row.Text
            }
        }

        It 'gives every row an icon' {
            @($script:node | Where-Object { [string]::IsNullOrWhiteSpace($_.Icon) }).Count | Should -Be 0
        }

        It 'gives the share, the task sequence, the OS and the boot image each a different one' {
            # An icon column where every row looks the same costs space and says
            # nothing. The categories are excluded here: they share a folder
            # except for Drivers, which is asserted below.
            $icon = @($script:node |
                    Where-Object { $_.Kind -in 'Root', 'Share', 'TaskSequence', 'OperatingSystem', 'BootImage' } |
                    ForEach-Object { $_.Icon } |
                    Sort-Object -Unique)

            @($icon).Count | Should -Be 5
        }

        It 'draws a task sequence as a list of steps rather than a clipboard' {
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.Icon | Should -BeExactly ([char]::ConvertFromUtf32(0x1F5D2))
        }

        It 'draws the driver store as a network card, not as another folder' {
            # It is the category an administrator scans the tree for by eye, and
            # a machine with no NIC driver is the failure it exists to prevent.
            $drivers = @($script:node | Where-Object { $_.Text -eq 'Drivers' })[0]
            $others = @($script:node |
                    Where-Object { $_.Kind -eq 'Category' -and $_.Text -ne 'Drivers' } |
                    ForEach-Object { $_.Icon } | Sort-Object -Unique)

            $drivers.Icon | Should -BeExactly ([char]::ConvertFromUtf32(0x1F5A7))
            $others | Should -Not -Contain $drivers.Icon
        }

        It 'carries its share banner on every row beneath that share' {
            foreach ($row in @($script:node | Where-Object { $_.Depth -ge 1 })) {
                $row.HeaderTitle | Should -BeExactly 'HDT deployment share'
                $row.HeaderRoot | Should -BeExactly 'C:\ws'
                $row.HeaderDeployRoot | Should -BeExactly '\\192.168.2.108\HDTShare'
            }
        }

        It 'names the task sequence by id and title' {
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.Text | Should -BeExactly 'DEMO-M4 - Deploy Windows 11 LTSC'
            $sequence.Detail | Should -Match 'Steps\s*:\s*2'
        }

        It 'offers the name and the description for typing, and nothing else on the row' {
            # WHERE A SEQUENCE IS RENAMED: the detail pane, off the tree, not a
            # window that has to be opened first. Both are keys in the document
            # and Set-HDTTaskSequenceProperty writes them; everything else on
            # this row is a reading - a count, a validation result, a path - and
            # a box that took typing would be a box that threw it away.
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $typeable = @($sequence.Field | Where-Object { $_.Editable })

            @($typeable | ForEach-Object { $_.Label }) | Should -Be @('Name', 'Version', 'Description')
            @($typeable | ForEach-Object { $_.Property }) | Should -Be @('name', 'version', 'description')
        }

        It 'shows the description a sequence has not got as an empty box, not as (none)' {
            # THE FALLBACK IS FOR READING, and this box is for typing: leaving
            # '(none)' in it and tabbing away would write the word into the
            # document as the description.
            $model = New-HDTConsoleNodeTestModel
            @($model.TaskSequence)[0].Description = ''

            $row = @(Get-HDTConsoleTreeNode -Workspace $model |
                    Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            [string] @($row.Field | Where-Object { $_.Label -eq 'Description' })[0].Value |
                Should -BeExactly ''
        }

        It 'offers the share its own three, which used to live on the Windows PE window' {
            # THE BOOTSTRAP TAB CARRIED THEM and should not have: a share's
            # name, where clients reach it and how much it logs are the SHARE's
            # settings, not the boot image's. They were a second block on a tab
            # whose subject is the rules file, and this row is where they belong.
            #
            # THE CREDENTIAL IS NOT AMONG THEM. Setting it writes two things -
            # a line in workspace.yaml and a protected file beside it - so a box
            # that wrote one of them would leave a share declaring an account no
            # secret exists for, which is a build that refuses.
            $share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]

            $typeable = @($share.Field | Where-Object { $_.Editable })

            @($typeable | ForEach-Object { $_.Label }) | Should -Be @('Share', 'Deploy root', 'Log level')
            @($typeable | ForEach-Object { $_.Property }) | Should -Be @('name', 'deployRoot', 'logLevel')
        }

        It 'carries the workspace document, because the pane writes to it' {
            $share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]

            [string] $share.Subject.WorkspacePath | Should -BeExactly 'C:\ws\workspace.yaml'
        }

        It 'offers an operating system its name and description for typing too' {
            # THE SAME PANE, THE SAME RULE. Workbench edits both on an imported
            # OS's Properties sheet; here they are the two rows that name a key
            # in os.yaml, and everything else on the row is a reading of the
            # media - an index list, a source path, a document path.
            $operatingSystem = @($script:node | Where-Object { $_.Kind -eq 'OperatingSystem' })[0]

            $typeable = @($operatingSystem.Field | Where-Object { $_.Editable })

            @($typeable | ForEach-Object { $_.Label }) | Should -Be @('Name', 'Description')
            @($typeable | ForEach-Object { $_.Property }) | Should -Be @('name', 'description')
        }

        It 'carries the operating system it names, because the pane writes to it' {
            # THE DETAIL PANE WRITES THE DOCUMENT THE ROW POINTS AT. Without a
            # Subject the window had nothing to open but a label, and the first
            # rename attempt came back as "the path is not of a legal form".
            $operatingSystem = @($script:node | Where-Object { $_.Kind -eq 'OperatingSystem' })[0]

            [string] $operatingSystem.Subject.Path | Should -BeExactly 'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml'
        }

        It 'carries the id as its Name, which is what a menu acts on' {
            # Name FALLS BACK TO Text WHEN IT IS NOT GIVEN, and Text is a label:
            # 'DEMO-M4 - Deploy Windows 11 LTSC'. The tree's Remove passed that
            # whole string to Remove-HDTTaskSequence as an id, which refused it
            # for having spaces in it - so the row would not go and the reason
            # was in the command box rather than anywhere near the row.
            #
            # The id is also what survives a reword of the label.
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.Name | Should -BeExactly 'DEMO-M4'
        }

        It 'names the operating system and the images the media carries' {
            $os = @($script:node | Where-Object { $_.Kind -eq 'OperatingSystem' })[0]

            $os.Text | Should -BeExactly 'Win11-LTSC-2024 - Windows 11 Enterprise LTSC 2024'
            $os.Detail | Should -Match 'EnterpriseS'
            $os.Detail | Should -Match '10\.0\.26100\.1742'
        }
    }

    Context 'the boot image row, which is why this increment names hashes at all' {

        BeforeAll {
            $script:bootNode = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel) |
                    Where-Object { $_.Kind -eq 'BootImage' })[0]
        }

        It 'is named after the image and nothing else' {
            # THE BUILD DATE USED TO BE IN THE ROW as well, on the argument that
            # "is this image current?" is asked in front of a bench and should
            # not need a click. It does not need one: the row opens on a single
            # click and the detail's Built field is right there. Two copies of
            # one timestamp is one of them wrong the first time a rebuild lands
            # while the tree is open.
            $script:bootNode.Text | Should -BeExactly 'HDTPE_x64'
        }

        It 'still carries the build date in the detail' {
            $script:bootNode.Detail | Should -Match '2026-08-14 07:13:25'
        }

        It 'shows both hashes in full, because a truncated hash cannot be compared' {
            $script:bootNode.Detail | Should -Match $script:wimHash
            $script:bootNode.Detail | Should -Match $script:isoHash
        }

        It 'states the DESIGN 6.1.1 verdict in words rather than leaving the reader to compare 64 hex digits' {
            $script:bootNode.Detail | Should -Match 'matches'
        }

        It 'shows both artifact paths and sizes' {
            $script:bootNode.Detail | Should -Match ([regex]::Escape('C:\ws\Boot\HDTPE_x64.wim'))
            $script:bootNode.Detail | Should -Match ([regex]::Escape('C:\ws\Boot\HDTPE_x64.iso'))
            $script:bootNode.Detail | Should -Match '495,334,205'
        }
    }

    Context 'every row shows the command that produced it (DESIGN 12)' {

        BeforeAll {
            $script:node = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel))
        }

        It 'gives every row a command' {
            @($script:node | Where-Object { [string]::IsNullOrWhiteSpace($_.Command) }).Count | Should -Be 0
        }

        It 'names the real module command for a task sequence' {
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.Command | Should -Match '^Import-HDTSequenceDocument '
            $sequence.Command | Should -Match ([regex]::Escape('C:\ws\TaskSequences\DEMO-M4\sequence.yaml'))
        }

        It 'names the real module command for an operating system' {
            $os = @($script:node | Where-Object { $_.Kind -eq 'OperatingSystem' })[0]

            $os.Command | Should -Match '^Get-HDTOperatingSystem '
            $os.Command | Should -Match "-Id 'Win11-LTSC-2024'"
        }

        It 'names a command that actually exists in the engine' {
            # A console that teaches the automation surface must not teach a
            # command nobody can run. The module imported in BeforeAll is the
            # one that has to answer, because it is the only one there is.

            $verb = @($script:node |
                    Where-Object { $_.Command -match '^[A-Z][a-z]+-HDT' } |
                    ForEach-Object { ($_.Command -split ' ')[0] } |
                    Sort-Object -Unique)

            @($verb).Count | Should -BeGreaterThan 0

            foreach ($name in $verb) {
                Get-Command -Name $name -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                    Should -Not -BeNullOrEmpty -Because "$name is offered to an administrator as something to type"
            }
        }

        It 'offers no injected service in a line meant to be typed' {
            # -FileSystem is a test seam (DESIGN 13.2.1), and the strip used to
            # spell it out because sixteen commands declared it Mandatory: drop
            # it from the line and the paste stopped on a parameter prompt.
            # They default now, so printing it teaches an administrator a
            # parameter they do not have and cannot usefully answer.
            @($script:node | Where-Object { $_.Command -match 'New-HDTFileSystem' }) |
                Should -BeNullOrEmpty
        }
    }

    Context 'an empty share' {

        BeforeAll {
            $script:node = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel -Empty))
        }

        It 'still shows the share and all eight categories' {
            @($script:node | Where-Object { $_.Kind -in 'Category', 'MonitorCategory' }).Count | Should -Be 8
        }

        It 'says a category is empty rather than showing nothing under it' {
            # Four '(none)' rows for the four catalogs - applications, operating
            # systems, Windows updates and task sequences - plus the drivers row
            # that says why there is nothing there at all.
            @($script:node | Where-Object { $_.Kind -eq 'Empty' }).Count | Should -Be 6
            @($script:node | Where-Object { $_.Text -eq '(none)' }).Count | Should -Be 4
        }

        It 'says the boot image has never been built, and says what to run' {
            $boot = @($script:node | Where-Object { $_.Kind -eq 'BootImage' })[0]

            $boot.Text | Should -Match 'not built'
            $boot.Detail | Should -Match 'Update-HDTBootImage'
        }
    }

    Context 'more than one deployment share' {

        BeforeAll {
            $second = $script:workspaceYaml.Replace('HDT-LAB-SMB', 'HDT-PROD')
            $second = $second.Replace('HDT deployment share', 'Production share')
            $second = $second.Replace('\\192.168.2.108\HDTShare', '\\prod-01\HDTShare')

            $lab = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File @{
                    'C:\ws\workspace.yaml' = $script:workspaceYaml
                })
            $prod = Get-HDTConsoleWorkspace -Path 'C:\prod' -FileSystem (New-HDTFakeFileSystem -File @{
                    'C:\prod\workspace.yaml' = $second
                })

            $script:many = @(Get-HDTConsoleTreeNode -Workspace @($lab, $prod))
        }

        It 'roots them together and counts them' {
            @($script:many | Where-Object { $_.Kind -eq 'Root' })[0].Text |
                Should -BeExactly 'Deployment Shares (2)'
        }

        It 'lists both shares, in the order they were given' {
            @($script:many | Where-Object { $_.Kind -eq 'Share' } | ForEach-Object { $_.Text }) |
                Should -Be @('HDT deployment share (HDT-LAB-SMB)', 'Production share (HDT-PROD)')
        }

        It 'gives each share its own categories rather than merging them' {
            @($script:many | Where-Object { $_.Kind -in 'Category', 'MonitorCategory' }).Count | Should -Be 16
        }

        It 'banners each row with ITS OWN share, which is the point of carrying it on the row' {
            $labRow = @($script:many | Where-Object { $_.Kind -eq 'BootImage' })[0]
            $prodRow = @($script:many | Where-Object { $_.Kind -eq 'BootImage' })[1]

            $labRow.HeaderDeployRoot | Should -BeExactly '\\192.168.2.108\HDTShare'
            $prodRow.HeaderDeployRoot | Should -BeExactly '\\prod-01\HDTShare'
        }

        It 'says the root row belongs to no single share' {
            $root = @($script:many | Where-Object { $_.Kind -eq 'Root' })[0]

            $root.HeaderRoot | Should -BeExactly '(select a share)'
            $root.Detail | Should -Match ([regex]::Escape('C:\prod'))
        }
    }

    Context 'a broken document' {

        It 'marks the row rather than hiding it, and puts the reason in the detail' {
            $file = @{
                'C:\ws\workspace.yaml'                      = $script:workspaceYaml
                'C:\ws\TaskSequences\DEMO-M4\sequence.yaml' = "schemaVersion: 1`nid: DEMO-M4`n  name: bad`n"
            }

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTFakeFileSystem -File $file)
            $node = @(Get-HDTConsoleTreeNode -Workspace $model | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $node.Status | Should -BeExactly 'Error'
            $node.Text | Should -Match 'DEMO-M4'
            $node.Detail | Should -Not -BeNullOrEmpty
        }

        It 'marks it with the warning icon, whatever kind of thing it is' {
            # The eye finds a warning in a tree of folders without reading a
            # word, which is the one thing an icon column is genuinely good at.
            $file = @{
                'C:\ws\workspace.yaml'                          = $script:workspaceYaml
                'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml' = "schemaVersion: 1`nid: Win11-LTSC-2024`n"
            }

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTFakeFileSystem -File $file)
            $node = @(Get-HDTConsoleTreeNode -Workspace $model)

            $broken = @($node | Where-Object { $_.Kind -eq 'OperatingSystem' })[0]
            $healthy = @($node | Where-Object { $_.Kind -eq 'Category' })[0]

            $broken.Icon | Should -Not -BeExactly $healthy.Icon
            $broken.Icon | Should -BeExactly ([string] ([char] 0x26A0))
        }

        It 'does not mark a boot image that was never built as a fault' {
            # 'Missing' is a share partway through being set up, and its row
            # already says 'not built' in words. Marking it would train an
            # administrator to ignore the mark.
            $node = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel -Empty))

            $boot = @($node | Where-Object { $_.Kind -eq 'BootImage' })[0]

            $boot.Status | Should -BeExactly 'Missing'
            $boot.Icon | Should -Not -BeExactly ([string] ([char] 0x26A0))
        }
    }

    # THE BROWSER TREE STOPS AT THE TASK SEQUENCE, and that is Deployment
    # Workbench's shape rather than an omission. MDT lists task sequences in the
    # tree and edits their steps in a SEPARATE properties window; CLAUDE.md asks
    # for a console "deliberately close to Deployment Workbench so muscle memory
    # transfers", so the steps belong to Get-HDTConsoleSequenceEditor and not
    # here.
    #
    # A browser that expanded every step of every sequence of every share would
    # also be unusable at the size an administrator actually runs: four
    # sequences on the lab share alone is over thirty rows before a single
    # operating system.
    Context 'the steps are NOT in the browser tree' {

        BeforeAll {
            $script:stepNode = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleStepTestModel))
        }

        It 'keeps the steps on the workspace, so the editor has something to open' {
            # Get-HDTConsoleWorkspace recorded StepCount and threw the steps
            # away, so no amount of work downstream could have shown them.
            $sequence = @((New-HDTConsoleStepTestModel).TaskSequence)[0]

            @($sequence.Step).Count | Should -Be 4
            @($sequence.Step)[0].Name | Should -BeExactly 'Validate'
        }

        It 'puts no step row in the browser' {
            @($script:stepNode | Where-Object { $_.Kind -eq 'Step' }) | Should -BeNullOrEmpty
        }

        It 'puts no group row in the browser' {
            @($script:stepNode | Where-Object { $_.Kind -eq 'StepGroup' }) | Should -BeNullOrEmpty
        }

        It 'leaves the task sequence as a leaf' {
            $sequence = @($script:stepNode | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.Depth | Should -Be 3
            @($sequence.Children) | Should -BeNullOrEmpty
        }

        It 'still says how many steps there are, since that is now the only hint' {
            $sequence = @($script:stepNode | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            ($sequence.Detail -join "`n") | Should -Match '4'
        }

        # DOUBLE-CLICKING A TASK SEQUENCE OPENS THE EDITOR, which is what
        # Deployment Workbench does and what an administrator will try first.
        # The window may not work out for itself which rows those are - that is
        # a decision, and decisions do not go in an adapter (CLAUDE.md rule 1) -
        # so the row says whether it opens and carries the object the editor
        # needs.
        It 'marks a task sequence as a row that opens' {
            $sequence = @($script:stepNode | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.CanOpen | Should -BeTrue
        }

        It 'carries the task sequence itself, because the editor takes the object and never an id' {
            # Two shares commonly hold a sequence with the same id - both of
            # this lab's do - so an editor opened by id could edit one share's
            # document while showing the other's.
            $sequence = @($script:stepNode | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.Subject | Should -Not -BeNullOrEmpty
            $sequence.Subject.Path | Should -BeExactly 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
        }

        # AND DOUBLE-CLICKING THE BOOT IMAGE OPENS THE WINDOWS PE WINDOW, which
        # is Deployment Workbench's deployment share Properties. Same mechanism:
        # the row says it opens and carries what the window needs, and the
        # adapter routes on the Kind it already has rather than working out for
        # itself which rows are which.
        It 'marks the boot image as a row that opens' {
            $boot = @($script:stepNode | Where-Object { $_.Kind -eq 'BootImage' })[0]

            $boot.CanOpen | Should -BeTrue
        }

        It 'carries the workspace document the Windows PE window edits' {
            # THE DOCUMENT, NOT THE SHARE ROOT. Two shares in this lab hold an
            # HDTPE_x64; the window's banner and its Save both need to name the
            # file, not the image.
            $boot = @($script:stepNode | Where-Object { $_.Kind -eq 'BootImage' })[0]

            $boot.Subject | Should -BeExactly 'C:\ws\workspace.yaml'
        }

        It 'marks every other row as one that does not open' {
            @($script:stepNode |
                    Where-Object { $_.Kind -notin @('TaskSequence', 'BootImage') -and $_.CanOpen }) |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'the category a window can act on' {

    # RIGHT-CLICKING Task Sequences IS WHERE Workbench PUTS New Task Sequence,
    # so the window has to be able to tell that row from the other three
    # categories. Its TEXT carries a count - 'Task Sequences (5)' - and routing
    # on that means a window parsing a label, in the one place a label is most
    # likely to be reworded.
    #
    # THE NAME IS THE STABLE ONE. Text is for reading; Name is for matching.

    BeforeAll {
        $script:categoryNode = @($script:node | Where-Object { $_.Kind -eq 'Category' })
    }

    It 'gives the task sequence category a name with no count in it' {
        $row = @($script:categoryNode | Where-Object { $_.Name -eq 'TaskSequences' })

        @($row).Count | Should -Be 1
        $row[0].Text | Should -BeLike 'Task Sequences*'
    }

    It 'carries the share root, so a window knows which share to write into' {
        $row = @($script:categoryNode | Where-Object { $_.Name -eq 'TaskSequences' })[0]

        $row.HeaderRoot | Should -Not -BeNullOrEmpty
    }

    # AND Boot Image IS ONE OF THOSE ROWS. Right-clicking it is where somebody
    # looks for the thing that BUILDS the WinPE: the Windows PE window was
    # reachable only by double-clicking the image row underneath, which is a
    # route nobody finds - and the row underneath is the one that says 'not
    # built', so the first build was the hardest thing in the console to reach.
    #
    # IT CARRIES THE DOCUMENT ITSELF, not the share root, because that window
    # takes workspace.yaml - the same thing the image row hands it.
    It 'gives the boot image category a name and the document the Windows PE window edits' {
        $row = @($script:categoryNode | Where-Object { $_.Name -eq 'BootImage' })

        @($row).Count | Should -Be 1
        $row[0].Text | Should -BeExactly 'Boot Image'
        $row[0].Subject | Should -BeExactly 'C:\ws\workspace.yaml'
    }
}


}
