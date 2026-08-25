# What the Apply OS pane writes when a box on it is left.
#
# UNCHANGED MEANS UNCHANGED, and this is the trap the pane exists around. The
# image box shows what the step RESOLVES TO, not what the step says. A step that
# names its image through '%HDTOSImage%' shows today's answer in the box, so
# writing back whatever the box holds would silently replace the variable with a
# literal - on a press meant for the time limit. The box has to be compared
# against what it was FILLED with, and left alone when they match.
#
# THE VARIABLE, NOT THE TOKEN. When the image really was changed and the step
# names it through a variable this sequence sets, the new choice belongs in the
# variables block. Writing the literal into the step would delete the
# indirection the whole sequence was built on and leave the Variables tab
# showing an image the step no longer uses.
#
# THE INDEX IS THE NUMBER, NEVER THE LABEL. A selected editable ComboBox reports
# its display text - '1  -  Windows 11 Enterprise LTSC' - and that is not an
# index. The selected item wins over the typed text when there is one.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Get-HDTConsoleImageWrite' {

    Context 'a step whose image was not touched' {

        BeforeAll {
            # The box shows what '%HDTOSImage%' resolved to, and nobody changed it.
            $script:same = Get-HDTConsoleImageWrite -Step 'Apply OS' `
                -Image '%HDTOSImage%' -ImageShown 'Win11-LTSC-2024' -ImageVariable 'HDTOSImage' `
                -Chosen 'Win11-LTSC-2024' `
                -IndexTyped '1' -IndexShown '1' -IndexWritten '%HDTOSIndex%' `
                -Target 'C:' -TimeoutMinutes '90'
        }

        It 'reports the image as unchanged' {
            $script:same.ImageChanged | Should -BeFalse
        }

        It 'writes the token back, not the image it resolved to' {
            ($script:same.Property | Where-Object { $_.Key -eq 'os' }).Value |
                Should -BeExactly '%HDTOSImage%'
        }

        It 'writes no variable' {
            $script:same.VariableName | Should -BeExactly ''
        }

        It 'writes the index the file had, not the number the box showed' {
            ($script:same.Property | Where-Object { $_.Key -eq 'index' }).Value |
                Should -BeExactly '%HDTOSIndex%'
        }
    }

    Context 'a step whose image was changed, named through a variable' {

        BeforeAll {
            $script:viaVariable = Get-HDTConsoleImageWrite -Step 'Apply OS' `
                -Image '%HDTOSImage%' -ImageShown 'Win11-LTSC-2024' -ImageVariable 'HDTOSImage' `
                -Chosen 'WS2025-Std' `
                -IndexTyped '1' -IndexShown '1' -IndexWritten '%HDTOSIndex%' `
                -Target 'C:' -TimeoutMinutes '90'
        }

        It 'reports the image as changed' {
            $script:viaVariable.ImageChanged | Should -BeTrue
        }

        It 'puts the new choice in the variables block' {
            $script:viaVariable.VariableName | Should -BeExactly 'HDTOSImage'
            $script:viaVariable.VariableValue | Should -BeExactly 'WS2025-Std'
        }

        It 'leaves the step still saying the token' {
            # Writing 'WS2025-Std' here would delete the indirection.
            ($script:viaVariable.Property | Where-Object { $_.Key -eq 'os' }).Value |
                Should -BeExactly '%HDTOSImage%'
        }

        It 'echoes the variable write, which is the command that ran' {
            $script:viaVariable.Command |
                Should -BeExactly "Set-HDTSequenceVariable -Line `$line -Name 'HDTOSImage' -Value 'WS2025-Std'"
        }
    }

    Context 'a step whose image was changed and names it directly' {

        BeforeAll {
            $script:direct = Get-HDTConsoleImageWrite -Step 'Apply OS' `
                -Image 'Win11-LTSC-2024' -ImageShown 'Win11-LTSC-2024' -ImageVariable '' `
                -Chosen 'WS2025-Std' `
                -IndexTyped '2' -IndexShown '1' -IndexWritten '1' `
                -Target 'C:' -TimeoutMinutes '90'
        }

        It 'writes the image into the step itself' {
            ($script:direct.Property | Where-Object { $_.Key -eq 'os' }).Value |
                Should -BeExactly 'WS2025-Std'
        }

        It 'writes no variable, because the step names no variable' {
            $script:direct.VariableName | Should -BeExactly ''
        }

        It 'echoes the step property write' {
            $script:direct.Command |
                Should -BeExactly "Set-HDTStepProperty -Line `$line -Name 'Apply OS' -Property 'os' -Value 'WS2025-Std'"
        }
    }

    # THE LABEL IS NOT AN INDEX.
    Context 'an index picked from the list rather than typed' {

        It 'writes the number off the selected row, not its display text' {
            $answer = Get-HDTConsoleImageWrite -Step 'Apply OS' `
                -Image 'Win11-LTSC-2024' -ImageShown 'Win11-LTSC-2024' -ImageVariable '' `
                -Chosen 'Win11-LTSC-2024' `
                -IndexTyped '1  -  Windows 11 Enterprise LTSC' -IndexSelected '3' `
                -IndexShown '1' -IndexWritten '1' `
                -Target 'C:' -TimeoutMinutes '90'

            ($answer.Property | Where-Object { $_.Key -eq 'index' }).Value | Should -BeExactly '3'
        }

        It 'falls back to the typed text when nothing is selected' {
            $answer = Get-HDTConsoleImageWrite -Step 'Apply OS' `
                -Image 'Win11-LTSC-2024' -ImageShown 'Win11-LTSC-2024' -ImageVariable '' `
                -Chosen 'Win11-LTSC-2024' `
                -IndexTyped '4' -IndexShown '1' -IndexWritten '1' `
                -Target 'C:' -TimeoutMinutes '90'

            ($answer.Property | Where-Object { $_.Key -eq 'index' }).Value | Should -BeExactly '4'
        }
    }

    Context 'the properties one press writes' {

        BeforeAll {
            $script:all = Get-HDTConsoleImageWrite -Step 'Apply OS' `
                -Image 'Win11-LTSC-2024' -ImageShown 'Win11-LTSC-2024' -ImageVariable '' `
                -Chosen 'Win11-LTSC-2024' `
                -IndexTyped '1' -IndexShown '1' -IndexWritten '1' `
                -Target 'D:' -TimeoutMinutes '45'
        }

        It 'writes all four, in the order the pane reads' {
            @($script:all.Property.Key) | Should -Be @('os', 'index', 'target', 'timeoutMinutes')
        }

        It 'carries the target and the time limit as typed' {
            ($script:all.Property | Where-Object { $_.Key -eq 'target' }).Value | Should -BeExactly 'D:'
            ($script:all.Property | Where-Object { $_.Key -eq 'timeoutMinutes' }).Value | Should -BeExactly '45'
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleImageWrite -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleImageWrite'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
