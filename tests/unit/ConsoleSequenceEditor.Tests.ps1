# The task sequence editor, decided in a command and asserted with no window.
#
# WHY IT IS A SEPARATE WINDOW. Deployment Workbench lists task sequences in the
# tree and edits their steps in a properties dialog reached by opening one -
# step tree on the left, properties on the right, Add/Remove/Up/Down across the
# top. CLAUDE.md asks for a console "deliberately close to Deployment Workbench
# so muscle memory transfers", and DESIGN 12 repeats it. Nesting the steps in
# the browser instead would put an editing surface inside a window that opens a
# live share and promises to write nothing to it.
#
# THE SAME RULE AS Get-HDTConsoleTreeNode APPLIES HERE. Everything that reaches
# the screen is decided in this command, so the injected host stays branch-free
# and honestly exempt from TDD (CLAUDE.md rule 1). If the host built these rows,
# the only thing that could check the editor's output would be a person looking
# at a screen.

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

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\192.168.2.108\HDTShare
'@

    # DEMO-M4's shape: two groups, an ordered run, per-type properties, and a
    # step that is allowed to fail.
    $script:sequenceYaml = @'
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

    # A sequence with no groups at all, which is legal and is what a short
    # maintenance sequence looks like.
    $script:flatSequenceYaml = @'
schemaVersion: 1
id: FLAT
name: No groups here
steps:
  - name: Say so
    type: NoOp
  - name: Say it again
    type: NoOp
'@

    function New-HDTConsoleEditorTestSequence {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a projection from an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()]
            [ValidateNotNullOrEmpty()]
            [string] $Root = 'C:\ws',

            [Parameter()]
            [ValidateNotNullOrEmpty()]
            [string] $Id = 'DEMO-M4',

            [Parameter()]
            [AllowNull()]
            [string] $Yaml
        )

        if ([string]::IsNullOrEmpty($Yaml)) { $Yaml = $script:sequenceYaml }

        $workspace = Get-HDTConsoleWorkspace -Path $Root -FileSystem (New-HDTFakeFileSystem -File @{
                ('{0}\workspace.yaml' -f $Root)                          = $script:workspaceYaml
                ('{0}\TaskSequences\{1}\sequence.yaml' -f $Root, $Id)    = $Yaml
            })

        return @($workspace.TaskSequence)[0]
    }
}

Describe 'Get-HDTConsoleSequenceEditor' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTConsoleSequenceEditor' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Get-HDTConsoleSequenceEditor').Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'what the window is called' {

        BeforeAll {
            $script:editor = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence)
        }

        It 'names the task sequence in the title, because several may be open' {
            $script:editor.Title | Should -Match 'DEMO-M4'
        }

        It 'says which document is being edited, because two shares hold the same id' {
            # Both of the lab's shares hold a DEMO-M4. A title that said only
            # "DEMO-M4" would leave an administrator with two identical windows
            # and no way to tell which share they are about to write to.
            $script:editor.DocumentPath | Should -BeExactly 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
        }
    }

    Context 'the step tree' {

        BeforeAll {
            $script:editor = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence)
            $script:node = @($script:editor.Node)
            $script:stepRow = @($script:node | Where-Object { $_.Kind -eq 'Step' })
            $script:groupRow = @($script:node | Where-Object { $_.Kind -eq 'StepGroup' })
        }

        It 'gives every step a row' {
            @($script:stepRow).Count | Should -Be 4
        }

        It 'gives every group a row' {
            @($script:groupRow | ForEach-Object { $_.Text }) | Should -Be @('Preinstall', 'Install')
        }

        It 'puts the steps in the order the engine would run them' {
            @($script:stepRow | ForEach-Object { $_.Text }) |
                Should -Be @('1. Validate', '2. Format and Partition', '3. Apply OS', '4. Prepare Boot  (continues on error)')
        }

        It 'nests a step under its group, and hangs the groups off the root' {
            @($script:editor.Root | ForEach-Object { $_.Text }) | Should -Be @('Preinstall', 'Install')

            $preinstall = @($script:editor.Root)[0]
            @($preinstall.Children | ForEach-Object { $_.Text }) |
                Should -Be @('1. Validate', '2. Format and Partition')
        }

        It 'carries the bare name beside the row''s text, which is what the editing cmdlets take' {
            # Text is prose for a person - a number in front, '(disabled)'
            # behind. Every editing cmdlet takes the NAME, so the row carries it
            # separately rather than making the window peel the decoration back
            # off with a regex it would have to keep in step with this file.
            @($script:stepRow | ForEach-Object { $_.Name }) |
                Should -Be @('Validate', 'Format and Partition', 'Apply OS', 'Prepare Boot')
        }

        It 'names a group by the leg of the path it is, not by the whole path' {
            @($script:groupRow | ForEach-Object { $_.Name }) | Should -Be @('Preinstall', 'Install')
        }

        It 'keeps the name clean on a step that is switched off' {
            $off = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Id 'OFF' -Yaml @'
schemaVersion: 1
id: OFF
name: One step, switched off
steps:
  - name: Apply OS
    type: ApplyImage
    disabled: true
'@)

            $row = @($off.Node | Where-Object { $_.Kind -eq 'Step' })[0]

            $row.Text | Should -BeLike '*(disabled)*'
            $row.Name | Should -BeExactly 'Apply OS'
        }

        It 'hangs an ungrouped step straight off the root' {
            $flat = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Id 'FLAT' -Yaml $script:flatSequenceYaml)

            @($flat.Root | ForEach-Object { $_.Text }) | Should -Be @('1. Say so', '2. Say it again')
            @($flat.Root | ForEach-Object { $_.Kind }) | Should -Be @('Step', 'Step')
        }
    }

    Context 'the properties pane' {

        BeforeAll {
            $script:editor = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence)
            $script:stepRow = @($script:editor.Node | Where-Object { $_.Kind -eq 'Step' })
        }

        It 'says what the step IS, not just what it is called' {
            $applyOs = @($script:stepRow | Where-Object { $_.Text -match 'Apply OS' })[0]

            ($applyOs.Detail -join "`n") | Should -Match 'ApplyImage'
        }

        It 'carries the per-type properties' {
            $validate = @($script:stepRow | Where-Object { $_.Text -match 'Validate' })[0]

            ($validate.Detail -join "`n") | Should -Match '2048'
            ($validate.Detail -join "`n") | Should -Match '60'
        }

        It 'shows the phase a step runs in, the commonest reason one is skipped' {
            $validate = @($script:stepRow | Where-Object { $_.Text -match 'Validate' })[0]

            ($validate.Detail -join "`n") | Should -Match 'WinPE'
        }

        It 'shows that a step is allowed to fail, because it changes what a red run means' {
            $prepareBoot = @($script:stepRow | Where-Object { $_.Text -match 'Prepare Boot' })[0]

            ($prepareBoot.Detail -join "`n") | Should -Match 'Continue on error'
        }

        It 'carries the cmdlet that produced every row' {
            # DESIGN 12: an admin can learn the automation surface by clicking
            # around, and the editor is not exempt from that.
            @($script:editor.Node | Where-Object { [string]::IsNullOrWhiteSpace($_.Command) }) |
                Should -BeNullOrEmpty
        }

        It 'offers no injected service in a line meant to be typed' {
            # The same rule the share tree carries: what the strip shows has to
            # be a line an administrator can paste, and -FileSystem is a seam
            # for the fakes, not a parameter anybody has.
            @($script:editor.Node | Where-Object { $_.Command -match 'New-HDTFileSystem' }) |
                Should -BeNullOrEmpty
        }
    }

    Context 'a sequence that could not be read' {

        It 'opens an editor with no steps rather than throwing' {
            # The browser already shows the engine's error on the sequence's own
            # row. An editor that threw on open would leave an administrator
            # with a dialog they cannot dismiss and no way to see why.
            $broken = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Yaml "schemaVersion: 1`nid: DEMO-M4`n  name: bad`n")

            @($broken.Node) | Should -BeNullOrEmpty
            @($broken.Root) | Should -BeNullOrEmpty
        }
    }

    # TWO SHARES, ONE ID. Both of the lab's shares hold a DEMO-M4, so an editor
    # keyed on the id rather than on the object would open the wrong document -
    # and would look right until the moment it wrote.
    Context 'two shares holding the same task sequence id' {

        It 'edits the document on the share it was opened from' {
            $lab = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Root 'C:\ws')
            $prod = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Root 'C:\prod')

            $lab.DocumentPath | Should -BeExactly 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
            $prod.DocumentPath | Should -BeExactly 'C:\prod\TaskSequences\DEMO-M4\sequence.yaml'
        }

        It 'gives each its own rows rather than sharing one set' {
            $lab = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Root 'C:\ws')
            $prod = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Root 'C:\prod')

            @($lab.Node).Count | Should -Be 6
            @($prod.Node).Count | Should -Be 6

            @($lab.Node)[0] | Should -Not -Be @($prod.Node)[0]
        }
    }
}

# A STEP THAT IS ALLOWED TO FAIL LOOKS DIFFERENT FROM ONE THAT IS NOT.
#
# continueOnError changes what a red deployment MEANS: a sequence carrying one is
# a sequence that can finish having done less than it says. That is a deliberate
# choice an administrator made, and it is invisible in a step tree that draws
# every step as the same grey gear - so it takes its own glyph and its own
# colour, the way a disabled step does.
#
# AMBER, NOT RED. It is not a fault; it is a tolerance somebody chose on purpose,
# and red is reserved for a document that cannot be read (see
# Get-HDTConsoleIconColor). Amber is the console's "worth noticing".
#
# DISABLED WINS WHEN BOTH ARE SET. A step that never runs cannot fail, so
# tolerating its failure is not a fact about this deployment.

# EVERY ROW ON A PROPERTIES SHEET IS LABELLED THE SAME WAY.
#
# Get-HDTConsolePropertyLabel turns a YAML key into a caption - 'includeManagementTools'
# into 'Include management tools' - and two branches of Get-HDTConsoleStepNode
# were passing the raw key straight through instead. The result was a sheet
# where most rows read like English and 'successCodes' and 'features' read like
# the file, side by side, which makes the odd ones look like a different KIND of
# row rather than the same row spelt carelessly.
Describe 'the caption on every properties row' {

    Context 'a key whose value is a table' {

        BeforeAll {
            # A step type carrying a list the console has no dedicated page for,
            # which is what a third-party type out of Modules\ looks like
            # (CLAUDE.md rule 3). It gets the generic sheet and nothing else.
            $script:tableYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
steps:
  - name: Say nothing
    type: NoOp
    retryCodes: [1, 2, 3]
'@

            $script:editor = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Yaml $script:tableYaml)
            $script:row = @($script:editor.Node | Where-Object { $_.Kind -eq 'Step' })[0]
        }

        It 'reads it as English, not as the key it is spelt with in the file' {
            $labelled = @($script:row.Field | Where-Object { $_.Label -eq 'Retry codes' })

            $labelled | Should -Not -BeNullOrEmpty
        }

        It 'still says how many entries, because the sheet cannot edit them here' {
            $labelled = @($script:row.Field | Where-Object { $_.Label -eq 'Retry codes' })[0]

            $labelled.Value | Should -Match '3 entries'
        }

        It 'leaves it read-only, because a box would write those words into the file' {
            $labelled = @($script:row.Field | Where-Object { $_.Label -eq 'Retry codes' })[0]

            $labelled.Editable | Should -BeFalse
        }
    }

    Context 'a key a dedicated page owns' {

        BeforeAll {
            # DiskPartition's keys are reported rather than offered, because the
            # Disk page is that step's properties sheet. Reported is not an
            # excuse to stop labelling them: they are read in the tree summary.
            $script:editor = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence)
            $script:disk = @($script:editor.Node |
                    Where-Object { $_.Kind -eq 'Step' -and $_.Text -match 'Format and Partition' })[0]
        }

        It 'labels it the same way the sheet labels everything else' {
            # CASE-SENSITIVE ON PURPOSE. -Match is not, so 'Wipe' and the raw
            # 'wipe' the file spells it with both satisfy it - which is exactly
            # the difference this test exists to catch.
            ($script:disk.Detail -join "`n") | Should -CMatch '(?m)^Wipe\s'
            ($script:disk.Detail -join "`n") | Should -Not -CMatch '(?m)^wipe\s'
        }
    }
}

Describe 'a step that carries continueOnError' {

    BeforeAll {
        $script:tolerantYaml = @'
schemaVersion: 1
id: TOLERANT
name: One tolerant step, one ordinary, one off
steps:
  - name: Ordinary
    type: Validate

  - name: Tolerant
    type: CommandLine
    continueOnError: true

  - name: Off And Tolerant
    type: CommandLine
    continueOnError: true
    disabled: true
'@

        $script:tolerantEditor = Get-HDTConsoleSequenceEditor -Sequence (New-HDTConsoleEditorTestSequence -Id 'TOLERANT' -Yaml $script:tolerantYaml)
        $script:tolerantStep = @($script:tolerantEditor.Node | Where-Object { $_.Kind -eq 'Step' })
    }

    It 'gives it a glyph of its own, not the ordinary gear' {
        $ordinary = @($script:tolerantStep | Where-Object { $_.Name -eq 'Ordinary' })[0]
        $tolerant = @($script:tolerantStep | Where-Object { $_.Name -eq 'Tolerant' })[0]

        $tolerant.Icon | Should -Not -BeExactly $ordinary.Icon
        $tolerant.Icon | Should -Not -BeNullOrEmpty
    }

    It 'draws it amber, because a tolerance is worth noticing and is not a fault' {
        $tolerant = @($script:tolerantStep | Where-Object { $_.Name -eq 'Tolerant' })[0]

        $tolerant.IconColor | Should -BeExactly '#FFB77400'
    }

    It 'leaves an ordinary step exactly as it was' {
        $ordinary = @($script:tolerantStep | Where-Object { $_.Name -eq 'Ordinary' })[0]

        $ordinary.IconColor | Should -BeExactly '#FF6E7781'
    }

    It 'says so in words too, so the mark is not a symbol nobody can look up' {
        $tolerant = @($script:tolerantStep | Where-Object { $_.Name -eq 'Tolerant' })[0]

        $tolerant.Text | Should -BeLike '*continues on error*'
    }

    It 'lets disabled win, because a step that never runs cannot fail' {
        $both = @($script:tolerantStep | Where-Object { $_.Name -eq 'Off And Tolerant' })[0]
        $off = [string] ([char] 0x2298)

        $both.Icon | Should -BeExactly $off
        $both.Text | Should -BeLike '*(disabled)*'
        $both.Text | Should -Not -BeLike '*continues on error*'
    }

    It 'draws a disabled step grey, because it is inert rather than interesting' {
        $both = @($script:tolerantStep | Where-Object { $_.Name -eq 'Off And Tolerant' })[0]

        $both.IconColor | Should -BeExactly '#FF767676'
    }
}

Describe 'the name and description the editor can change' {

    # THE EDITOR SHOWED THEM AND COULD NOT CHANGE THEM until
    # Set-HDTTaskSequenceProperty existed, which is the console's rule producing
    # a hole rather than breaking. Now the view carries the calls, so the window
    # computes nothing.

    BeforeAll {
        $script:headerText = @'
schemaVersion: 1
id: DEMO-05
name: Windows 11 bare metal
description: The standard client build.

steps:
  - group: Install
    steps:
      - name: Install Operating System
        type: ApplyImage
'@

        # THE SUITE'S OWN HELPER, because the editor takes what
        # Get-HDTConsoleWorkspace projects - Status and all - not the bare
        # document Import-HDTSequenceDocument returns.
        $script:headerDocument = New-HDTConsoleEditorTestSequence -Id 'DEMO-05' -Yaml $script:headerText

        $script:headerView = Get-HDTConsoleSequenceEditor -Sequence $script:headerDocument
    }

    It 'reads both off the document' {
        [string] $script:headerView.Name | Should -BeExactly 'Windows 11 bare metal'
        [string] $script:headerView.Description | Should -BeExactly 'The standard client build.'
    }

    It 'carries the call that renames it' {
        $script:headerView.NameCommandFormat | Should -BeLike 'Set-HDTTaskSequenceProperty*-Name ''{0}''*'
    }

    It 'carries the call that rewrites the description' {
        $script:headerView.DescriptionCommandFormat |
            Should -BeLike 'Set-HDTTaskSequenceProperty*-Description ''{0}''*'
    }

    It 'answers empty for a sequence that describes itself with nothing' {
        $document = New-HDTConsoleEditorTestSequence -Id 'BARE' -Yaml @'
schemaVersion: 1
id: BARE
name: Bare
steps:
  - name: Say so
    type: NoOp
'@

        [string] (Get-HDTConsoleSequenceEditor -Sequence $document).Description | Should -BeExactly ''
    }
}

Describe 'the editor s Variables tab' {

    # THE BLOCK THE NEW SEQUENCE WINDOW FILLS AND NOTHING COULD CHANGE. Its
    # window asks for the administrator password, the OS image and the
    # organisation, writes them into variables:, and until Set-HDTSequenceVariable
    # existed that was the end of it - an administrator who mistyped the
    # password re-created the sequence.
    #
    # SECRETS ARE SHOWN, NOT MASKED, AND THE HINT SAYS WHY. HDTAdminPassword is
    # stored readable in the document because WinPE uses it with nobody present;
    # a masked box over a readable file is theatre, and it stops an
    # administrator checking what they typed.

    BeforeAll {
        $script:variableSequence = New-HDTConsoleEditorTestSequence -Yaml (([string[]] @(
                        'schemaVersion: 1'
                        'id: DEMO-M4'
                        'name: Demo'
                        'variables:'
                        '  HDTOSImage: Win11-LTSC-2024'
                        '  HDTAdminPassword: P@ssw0rd!'
                        'steps:'
                        '  - name: Gather'
                        '    type: Gather'
                    )) -join "`r`n")

        $script:variableView = Get-HDTConsoleSequenceEditor -Sequence $script:variableSequence
    }

    It 'lists what the sequence declares, in document order' {
        @($script:variableView.Variable | ForEach-Object { [string] $_.Name }) |
            Should -Be @('HDTOSImage', 'HDTAdminPassword')
    }

    It 'carries the value, so the row shows what will be used' {
        @($script:variableView.Variable | Where-Object { $_.Name -eq 'HDTOSImage' })[0].Value |
            Should -BeExactly 'Win11-LTSC-2024'
    }

    It 'says what each one means where the map knows' {
        # Get-HDTVariableMap carries the description and the MDT name; a row
        # showing only HDTOSImageIndex teaches nothing.
        @($script:variableView.Variable | Where-Object { $_.Name -eq 'HDTAdminPassword' })[0].Hint |
            Should -Not -BeNullOrEmpty
    }

    It 'offers every variable a sequence may set, to type against' {
        # A NAME TYPED FROM MEMORY IS A NAME TYPED WRONG. HDTOSImageIndex,
        # HDTAdminPassword, HDTJoinWorkgroup - close enough to guess and far
        # enough to get wrong, and a misspelt one sets something nothing reads.
        # The list is Get-HDTVariableMap's, which is the same list the
        # catalogue in rules.yaml is generated from.
        @($script:variableView.VariableChoice) | Should -Contain 'HDTAdminPassword'
        @($script:variableView.VariableChoice) | Should -Contain 'HDTComputerName'
    }

    It 'offers no engine-owned name, which a document may not assign' {
        @($script:variableView.VariableChoice) | Should -Not -Contain '_HDTStepName'
    }

    It 'runs the command that owns the block' {
        $script:variableView.VariableCommandFormat | Should -BeLike 'Set-HDTSequenceVariable -Line $line -Name*-Value*'
    }

    It 'offers a way to take one out' {
        $script:variableView.VariableRemoveCommandFormat | Should -BeLike 'Set-HDTSequenceVariable -Line $line -Name*-Remove'
    }

    It 'is empty rather than absent on a sequence that declares none' {
        $bare = New-HDTConsoleEditorTestSequence -Yaml (([string[]] @(
                        'schemaVersion: 1'; 'id: DEMO-M4'; 'name: Bare'
                        'steps:'; '  - name: Gather'; '    type: Gather')) -join "`r`n")

        @((Get-HDTConsoleSequenceEditor -Sequence $bare).Variable).Count | Should -Be 0
    }
}


}
