# THE OTHER HALF OF THE BILL Get-HDTConsoleEditorState -Document started, and
# the larger half.
#
# Handing the parse in took four view models down to one parse per refresh.
# What was left was the TREE: Get-HDTConsoleEditorState calls
# Get-HDTConsoleStepNode on every call, and the SELECTION path binds neither
# Node nor Root - measured at 164ms of a 365ms click, building rows that are
# discarded on the next line. On a 17-row sequence. It gets worse linearly.
#
# THE SWITCH IS THE CALLER SAYING IT WILL NOT BIND THEM, the same bargain
# Get-HDTDriver -NoHardwareId makes with the grid it fills. Nothing else may
# change: every button, every option and the status line are worked out from the
# DOCUMENT, not from the rows, and the tests below are mostly about proving
# that - a saving that darkened a button would be no saving at all.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    $script:path = 'C:\ws\TaskSequences\DEMO\sequence.yaml'

    # TWO STEPS OF ONE NAME, ON PURPOSE. The occurrence is what picks the row,
    # and it is the field the tree used to be consulted for.
    $script:line = [string[]] @(
        'schemaVersion: 1'
        'id: DEMO'
        'name: Demo'
        'variables:'
        '  HDTOSImage: Win11-LTSC-2024'
        'steps:'
        '  - group: Preinstall'
        '    runIn: WinPE'
        '    steps:'
        '      - name: Validate'
        '        type: Validate'
        '        minRamMB: 2048'
        '      - name: Format and Partition Disk (UEFI)'
        '        type: DiskPartition'
        '        disk: 0'
        '        layout: UEFI'
        '  - group: Install'
        '    runIn: WinPE'
        '    steps:'
        '      - name: Install Operating System'
        '        type: ApplyImage'
        '        os: "%HDTOSImage%"'
        '        target: primary'
        '      - name: Validate'
        '        type: Validate'
        '        minRamMB: 4096'
        '        disabled: true'
    )


    $script:document = Import-HDTSequenceDocument -Path $script:path -FileSystem (
        New-HDTFileSystemFromText -Path $script:path `
            -Text ($script:line -join [System.Environment]::NewLine))
}

Describe 'Get-HDTConsoleEditorState builds the tree only for a caller that binds it' {

    It 'offers a NoTree switch' {
        $parameter = (Get-Command -Name 'Get-HDTConsoleEditorState' -Module 'Hephaestus').Parameters['NoTree']

        $parameter | Should -Not -BeNullOrEmpty
        $parameter.ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
    }

    It 'still builds the tree when nobody asks it not to' {
        $state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -Document $script:document

        @($state.Node).Count | Should -BeGreaterThan 0
        @($state.Root).Count | Should -BeGreaterThan 0
    }

    It 'returns no rows at all when the caller says it binds none' {
        $state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
            -Document $script:document -NoTree

        @($state.Node).Count | Should -Be 0
        @($state.Root).Count | Should -Be 0
    }

    # THE POINT OF THE SWITCH, ASSERTED AS A CALL AND NOT AS A CLOCK. A timing
    # assertion is flaky on a shared machine and says nothing about WHY the
    # click got shorter; this says exactly which work stopped happening.
    #
    # Mock at the boundary of the command being skipped, which is the one use
    # CLAUDE.md reserves it for - nothing here wants a fake's behaviour, only
    # the count.
    It 'does not call Get-HDTConsoleStepNode' {
        Mock -CommandName 'Get-HDTConsoleStepNode' -ModuleName 'Hephaestus' -MockWith {
            return [pscustomobject] @{ Node = @(); TopLevel = @() }
        }

        [void] (Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
                -SelectedName 'Validate' -SelectedOccurrence 2 -Document $script:document -NoTree)

        Should -Invoke -CommandName 'Get-HDTConsoleStepNode' -ModuleName 'Hephaestus' -Times 0 -Exactly
    }

    It 'still calls it for a caller that did not ask to skip it' {
        # The other half of the pair: if the mock were never reached at all,
        # the assertion above would pass for the wrong reason.
        Mock -CommandName 'Get-HDTConsoleStepNode' -ModuleName 'Hephaestus' -MockWith {
            return [pscustomobject] @{ Node = @(); TopLevel = @() }
        }

        [void] (Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
                -SelectedName 'Validate' -Document $script:document)

        Should -Invoke -CommandName 'Get-HDTConsoleStepNode' -ModuleName 'Hephaestus' -Times 1 -Exactly
    }
}

# EVERYTHING THE SELECTION PATH ACTUALLY READS MUST SURVIVE IT.
Describe 'what the skipped tree must not cost' {

    It 'answers <Field> the same with the tree skipped as with it built' -ForEach @(
        @{ Field = 'Status' }
        @{ Field = 'StatusText' }
        @{ Field = 'StepCount' }
        @{ Field = 'CanRemove' }
        @{ Field = 'CanCopy' }
        @{ Field = 'CanMoveUp' }
        @{ Field = 'CanMoveDown' }
        @{ Field = 'CanPaste' }
        @{ Field = 'CanSave' }
        @{ Field = 'MoveUpTarget' }
        @{ Field = 'MoveDownTarget' }
        @{ Field = 'Option' }
        @{ Field = 'Variable' }
        @{ Field = 'VariableChoice' }
        @{ Field = 'VariableCommandFormat' }
        @{ Field = 'VariableRemoveCommandFormat' }
    ) {
        $with = Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
            -SelectedName 'Validate' -SelectedOccurrence 2 -Document $script:document -HasClipboard -Dirty

        $without = Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
            -SelectedName 'Validate' -SelectedOccurrence 2 -Document $script:document -HasClipboard -Dirty -NoTree

        # COMPARED AS TEXT. MoveUpTarget and Option are freshly built objects,
        # and two of those are never the same instance however equal they are.
        ($without.$Field | Out-String) | Should -BeExactly ($with.$Field | Out-String)
    }

    # THE OCCURRENCE STILL PICKS THE RIGHT STEP, and it used to be the one thing
    # here that could plausibly have needed the rows. The second Validate is
    # disabled and the first is not, so an answer about the wrong one shows.
    It 'follows the selected occurrence rather than the first of the name' {
        $first = Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
            -SelectedName 'Validate' -SelectedOccurrence 1 -Document $script:document -NoTree

        $second = Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
            -SelectedName 'Validate' -SelectedOccurrence 2 -Document $script:document -NoTree

        [bool] $first.Option.Disabled | Should -BeFalse
        [bool] $second.Option.Disabled | Should -BeTrue
    }

    It 'still fills the Options tab with the tree skipped' {
        $state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
            -SelectedName 'Format and Partition Disk (UEFI)' -Document $script:document -NoTree

        $state.Option | Should -Not -BeNullOrEmpty
        @($state.Option.Flag).Count | Should -BeGreaterThan 0
    }

    It 'still fills the Variables tab with the tree skipped' {
        $state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path `
            -Document $script:document -NoTree

        @($state.Variable | ForEach-Object { [string] $_.Name }) | Should -Contain 'HDTOSImage'
        @($state.VariableChoice).Count | Should -BeGreaterThan 0
    }

    # A BROKEN DOCUMENT REPORTS RATHER THAN THROWS, with or without rows - and
    # the error shape already returns an empty tree, so the two paths agree.
    It 'reports an unreadable document rather than throwing' {
        $state = Get-HDTConsoleEditorState -Line ([string[]] @('steps:', '  - name: "')) `
            -Path $script:path -NoTree

        $state.Status | Should -BeExactly 'Error'
        @($state.Node).Count | Should -Be 0
    }

    It 'parses the lines itself when handed no document and told to skip the tree' {
        # THE SWITCH IS ABOUT THE TREE AND NOTHING ELSE. A caller with lines and
        # no parse still gets an answer about the lines.
        $state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -NoTree

        $state.StepCount | Should -Be 4
    }
}

}
