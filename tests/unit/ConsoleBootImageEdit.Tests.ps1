# What one press of Save on the boot image pane writes to workspace.yaml.
#
# TEN NEAR-IDENTICAL DECISIONS LIVED IN THE HANDLER. Every optional setting on
# that pane is the same bargain twice over: a box left empty means CLEAR THE KEY,
# a box with something in it means write that, and the four properties at the top
# are skipped when empty instead of cleared. Fourteen branches inside an
# Add_Click, which is fourteen branches no test could reach.
#
# EMPTY IS NOT THE SAME ANSWER IN BOTH HALVES, and that is the whole reason this
# is worth a command. Clearing the unattend path removes the key; clearing the
# boot image NAME would leave the share with a nameless boot image, so an empty
# name is "not answered" and the key is left alone. Getting those two the same
# way round is a defect nobody sees until a build refuses.
#
# A TICK BOX HAS NO EMPTY. Unticked is an answer, and 'promptForKey: false'
# written into the document is what tells the next reader somebody decided rather
# than never looked - so PromptForKey is always written, whichever way it is set.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Get-HDTConsoleBootImageEdit' {

    Context 'a pane filled in completely' {

        BeforeAll {
            $script:full = Get-HDTConsoleBootImageEdit -BootImageName 'HDT-Boot' -Architecture 'amd64' `
                -Language 'en-us' -ScratchSpaceMB '512' -PromptForKey $true `
                -Unattend 'X:\unattend.xml' -Background 'X:\wall.jpg' -TimeZone 'GMT Standard Time' `
                -ClientCertificate 'X:\client.pfx' -Driver 'WinPE-Net'
        }

        It 'writes every property the boxes carry' {
            $script:full.Property['BootImageName'] | Should -BeExactly 'HDT-Boot'
            $script:full.Property['Architecture'] | Should -BeExactly 'amd64'
            $script:full.Property['Language'] | Should -BeExactly 'en-us'
        }

        It 'writes the scratch space as a number, not as the text of one' {
            # The combo box hands back a string; Set-HDTWorkspaceProperty types
            # the key, and 'scratchSpaceMB: "512"' is not what a build reads.
            $script:full.Property['ScratchSpaceMB'] | Should -Be 512
            $script:full.Property['ScratchSpaceMB'] | Should -BeOfType ([int])
        }

        It 'sets rather than clears each of the five documents' {
            @($script:full.Edit | Where-Object { -not $_.Clear }).Count | Should -Be 5
        }

        It 'names the command each setting is written with' {
            @($script:full.Edit.Command) | Should -Be @(
                'Set-HDTBootImageUnattend'
                'Set-HDTBootImageBackground'
                'Set-HDTBootImageTimeZone'
                'Set-HDTBootImageClientCertificate'
                'Set-HDTBootImageDriver'
            )
        }

        It 'hands each command the parameter it actually takes' {
            # Three of the five take -Path and two take -Name. Handing a path to
            # -Name is a parameter binding failure inside a click handler, where
            # the only symptom is a button that does nothing.
            @($script:full.Edit.Parameter) | Should -Be @('Path', 'Path', 'Name', 'Path', 'Name')
        }

        It 'carries the value each one is to be written with' {
            @($script:full.Edit.Value) | Should -Be @(
                'X:\unattend.xml', 'X:\wall.jpg', 'GMT Standard Time', 'X:\client.pfx', 'WinPE-Net')
        }
    }

    # AN EMPTY BOX IS AN INSTRUCTION HERE, not a blank to skip: it is how a
    # setting gets taken back off a boot image that already had one.
    Context 'a pane whose optional documents were emptied' {

        BeforeAll {
            $script:cleared = Get-HDTConsoleBootImageEdit -BootImageName 'HDT-Boot' -PromptForKey $false
        }

        It 'clears every one of the five' {
            @($script:cleared.Edit | Where-Object { $_.Clear }).Count | Should -Be 5
        }

        It 'offers no value to write with' {
            @($script:cleared.Edit | Where-Object { $_.Value -ne '' }).Count | Should -Be 0
        }
    }

    # THE OTHER WAY ROUND FROM THE DOCUMENTS ABOVE. An unanswered property is
    # left alone; clearing the name would leave the share with a nameless boot
    # image and a build that refuses.
    Context 'a property box left empty' {

        It 'writes no name when the name box is empty' {
            $answer = Get-HDTConsoleBootImageEdit -BootImageName '' -PromptForKey $false

            $answer.Property.Contains('BootImageName') | Should -BeFalse
        }

        It 'writes no architecture when nothing is selected' {
            $answer = Get-HDTConsoleBootImageEdit -Architecture '' -PromptForKey $false

            $answer.Property.Contains('Architecture') | Should -BeFalse
        }

        It 'writes no scratch space when nothing is selected' {
            $answer = Get-HDTConsoleBootImageEdit -ScratchSpaceMB '' -PromptForKey $false

            $answer.Property.Contains('ScratchSpaceMB') | Should -BeFalse
        }

        It 'treats whitespace as empty rather than as an answer' {
            $answer = Get-HDTConsoleBootImageEdit -BootImageName '   ' -Language "`t" -PromptForKey $false

            $answer.Property.Contains('BootImageName') | Should -BeFalse
            $answer.Property.Contains('Language') | Should -BeFalse
        }
    }

    Context 'the prompt-for-key tick box' {

        It 'writes it ticked' {
            (Get-HDTConsoleBootImageEdit -PromptForKey $true).Property['PromptForKey'] | Should -BeTrue
        }

        It 'writes it unticked rather than leaving the key out' {
            $answer = Get-HDTConsoleBootImageEdit -PromptForKey $false

            $answer.Property.Contains('PromptForKey') | Should -BeTrue
            $answer.Property['PromptForKey'] | Should -BeFalse
        }

        It 'writes a boolean, not the string of one' {
            (Get-HDTConsoleBootImageEdit -PromptForKey $false).Property['PromptForKey'] |
                Should -BeOfType ([bool])
        }
    }

    Context 'a pane with nothing filled in at all' {

        It 'still writes the tick box and nothing else' {
            $answer = Get-HDTConsoleBootImageEdit -PromptForKey $false

            @($answer.Property.Keys) | Should -Be @('PromptForKey')
        }

        It 'still asks for all five documents to be cleared' {
            @(Get-HDTConsoleBootImageEdit -PromptForKey $false).Edit.Count | Should -Be 5
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleBootImageEdit -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleBootImageEdit'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
