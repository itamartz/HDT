# W3 OF .planning/WPF-FIRST.md: the task sequence picker, and the command behind
# it.
#
# THE PICKER WAS A HAND-WRITTEN LIST UNTIL NOW. Scripts\UI\TaskSequence.xaml
# carried one <ListBoxItem> per sequence, typed by whoever added the sequence,
# and said so in its own comment. A lab share with eight sequences offered one -
# not as a failure anybody could see, but as a list that was quietly wrong.
#
# SO THE LIST IS THE FOLDER. TaskSequences\<Id>\sequence.yaml is what this
# engine runs, so it is also what the technician may choose from: a picker that
# offers something the share does not carry is a deployment that fails after
# every question has been answered.
#
# IT IS PURE, AND THAT IS WHY IT IS TESTED HERE RATHER THAN ON A VM. The
# command takes an IFileSystem and a variable bag and returns rows; no window,
# no share, no WinPE.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = 'Z:\Deploy'

    $script:document = {
        param([string] $Id, [string] $Name, [string] $Description)

        $text = "schemaVersion: 1`nid: $Id`nname: $Name`n"
        if (-not [string]::IsNullOrWhiteSpace($Description)) { $text += "description: $Description`n" }

        return ($text + "steps:`n  - name: Nothing`n    type: NoOp`n")
    }

    # A share with three sequences, deliberately not in alphabetical order on
    # disk, and one folder that is not a sequence at all.
    $script:share = @{
        'Z:\Deploy\TaskSequences\WIN11-LAB\sequence.yaml'  = (& $script:document 'WIN11-LAB' 'Windows 11 lab build' 'The one the lab runs')
        'Z:\Deploy\TaskSequences\001\sequence.yaml'        = (& $script:document '001' 'TS - Win 11 24H2 LTSC' '')
        'Z:\Deploy\TaskSequences\DEMO-M4\sequence.yaml'    = (& $script:document 'DEMO-M4' 'Windows 11 bare metal' '')
        'Z:\Deploy\TaskSequences\NotASequence\readme.txt'  = 'left here by somebody'
    }

    $script:newFileSystem = { New-HDTFakeFileSystem -File $script:share }

    $script:bag = {
        param([System.Collections.IDictionary] $Value)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $live[[string] $key] = $Value[$key] }
        }

        return $live
    }
}

Describe 'Get-HDTWizardSequence' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTWizardSequence' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what the share carries' {

        It 'offers every folder that holds a sequence.yaml' {
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            @($answer.Choice | ForEach-Object { [string] $_.Id }) | Should -Be @('001', 'DEMO-M4', 'WIN11-LAB')
        }

        It 'offers nothing for a folder without one' {
            # The lab share has a readme and a stray unattend.xml beside the
            # sequence folders. A picker listing 'NotASequence' would fail the
            # deployment after the technician had answered everything.
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            @($answer.Choice | ForEach-Object { [string] $_.Id }) | Should -Not -Contain 'NotASequence'
        }

        It 'sorts by id, because a list that reorders itself cannot be scanned' {
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            @($answer.Choice | ForEach-Object { [string] $_.Id }) |
                Should -Be (@($answer.Choice | ForEach-Object { [string] $_.Id }) | Sort-Object)
        }

        It 'takes the id off the FOLDER, whatever the document says' {
            # THE TRAP A REAL SHARE CARRIES. The lab's '001' sequence declares
            # `id: 001` and YAML reads that as the number 1, so a picker
            # trusting the document offers '1' - and the deployment then looks
            # for TaskSequences\1\sequence.yaml, which does not exist.
            # HDTTaskSequenceID names a folder; the folder is the id.
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            @($answer.Choice | ForEach-Object { [string] $_.Id }) | Should -Contain '001'
            @($answer.Choice | ForEach-Object { [string] $_.Id }) | Should -Not -Contain '1'
        }

        It 'reads the name out of the document rather than off the folder' {
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            [string] @($answer.Choice | Where-Object { $_.Id -eq '001' })[0].Name |
                Should -BeExactly 'TS - Win 11 24H2 LTSC'
        }

        It 'carries the description when the document has one' {
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            [string] @($answer.Choice | Where-Object { $_.Id -eq 'WIN11-LAB' })[0].Description |
                Should -BeExactly 'The one the lab runs'
        }

        It 'shows the id and the name on one row' {
            # The id is what the deployment records and the name is what a
            # technician recognises; a row with only one of them makes somebody
            # guess.
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            [string] @($answer.Choice | Where-Object { $_.Id -eq 'DEMO-M4' })[0].Text |
                Should -BeExactly 'DEMO-M4  -  Windows 11 bare metal'
        }

        It 'returns an empty list rather than throwing when there is no TaskSequences folder' {
            $answer = Get-HDTWizardSequence -WorkspaceRoot 'Z:\Empty' -FileSystem (New-HDTFakeFileSystem)

            @($answer.Choice) | Should -BeNullOrEmpty
            @($answer.Problem) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'a document that will not parse' {

        BeforeEach {
            $broken = @{} + $script:share
            $broken['Z:\Deploy\TaskSequences\BROKEN\sequence.yaml'] = "schemaVersion: 1`nid: [unclosed`n"

            $script:brokenFileSystem = New-HDTFakeFileSystem -File $broken
        }

        It 'leaves it out of the list' {
            # Offering a sequence that cannot be read is offering a deployment
            # that dies at the first step.
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem $script:brokenFileSystem

            @($answer.Choice | ForEach-Object { [string] $_.Id }) | Should -Not -Contain 'BROKEN'
        }

        It 'says so rather than dropping it in silence' {
            # "Why is mine not in the list?" must be answerable from the log.
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem $script:brokenFileSystem

            (@($answer.Problem) -join ' ') | Should -BeLike '*BROKEN*'
        }

        It 'still offers the ones that do parse' {
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem $script:brokenFileSystem

            @($answer.Choice).Count | Should -Be 3
        }
    }

    Context 'what is already selected' {

        It 'preselects the sequence the rules resolved' {
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) `
                -Variable (& $script:bag ([ordered] @{ HDTTaskSequenceID = 'WIN11-LAB' }))

            [string] $answer.Selected | Should -BeExactly 'WIN11-LAB'
        }

        It 'matches the id case-insensitively, as every other id in this engine is' {
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) `
                -Variable (& $script:bag ([ordered] @{ HDTTaskSequenceID = 'win11-lab' }))

            [string] $answer.Selected | Should -BeExactly 'WIN11-LAB'
        }

        It 'preselects NOTHING when the rules resolved nothing' {
            # IT USED TO OPEN ON THE FIRST ROW, and a real deployment failed
            # because of it. The host records what it puts in a box as a seed
            # and the harvest drops an answer equal to its seed - so the
            # technician who chose the sequence the picker was already sitting
            # on answered nothing, and the machine died before its first step
            # with "nothing in the rules resolved HDTTaskSequenceID for this
            # machine". A value the wizard invented is not a seed.
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            [string] $answer.Selected | Should -BeExactly ''
        }

        It 'reports an id the share does not carry rather than selecting it' {
            # A rule naming a sequence that is not there is a mistake somebody
            # has to be told about; silently selecting the first would deploy
            # the wrong build.
            $answer = Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) `
                -Variable (& $script:bag ([ordered] @{ HDTTaskSequenceID = 'NO-SUCH-TS' }))

            (@($answer.Problem) -join ' ') | Should -BeLike '*NO-SUCH-TS*'
            [string] $answer.Selected | Should -BeExactly ''
        }
    }

    Context 'the field the wizard host applies' {

        It 'names the control the page collects from' {
            # wizard.yaml's TaskSequence page collects HDTTaskSequenceList's
            # SelectedValue into HDTTaskSequenceID, so the field this returns
            # has to name the same control and the same property.
            $field = (Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)).Field

            [string] $field.Name | Should -BeExactly 'HDTTaskSequenceList'
            [string] $field.Property | Should -BeExactly 'SelectedValue'
        }

        It 'carries the rows as Item and the selection as Text' {
            $field = (Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) `
                    -Variable (& $script:bag ([ordered] @{ HDTTaskSequenceID = 'DEMO-M4' }))).Field

            @($field.Item).Count | Should -Be 3
            [string] $field.Text | Should -BeExactly 'DEMO-M4'
        }

        It 'carries the rows and NO selection when the rules chose none' {
            # The rows still have to reach the control - the picker is only
            # empty of a CHOICE, never of the share's sequences.
            $field = (Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)).Field

            @($field.Item).Count | Should -Be 3
            [string] $field.Text | Should -BeExactly ''
        }

        It 'can be told which control to fill' {
            # A site that renamed the control in its own page is not a site that
            # has to fork this command.
            $field = (Get-HDTWizardSequence -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) `
                    -Control 'HDTSequencePicker').Field

            [string] $field.Name | Should -BeExactly 'HDTSequencePicker'
        }
    }
}
