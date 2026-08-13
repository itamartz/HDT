# New-HDTStepResult is the ONE shape every step type returns. DESIGN 4.2 gives
# every step the same Test-Applicable / Invoke-Step / Get-StepDescription triple;
# this is the other half of that contract - the loop (03-04) branches on Status
# and nothing else, so the set is closed at three names.
#
#   Completed        the step did its work
#   Failed           the step did not, and ExitCode/Message say why
#   RebootRequested  the machine must restart before the sequence continues.
#                    The step does NOT reboot: arming autologon, saving state,
#                    logging reboot.arm and restarting is one ceremony that
#                    belongs to the loop, which owns the state document.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTStepResult' {

    It 'returns Status, ExitCode, Message and Data' {
        $result = New-HDTStepResult -Status Completed -ExitCode 3010 -Message 'done' -Data ([ordered] @{ index = 1 })

        $result.Status | Should -BeExactly 'Completed'
        $result.ExitCode | Should -Be 3010
        $result.Message | Should -BeExactly 'done'
        $result.Data['index'] | Should -Be 1
    }

    It 'defaults ExitCode to zero' {
        (New-HDTStepResult -Status Completed).ExitCode | Should -Be 0
    }

    It 'defaults Message to an empty string' {
        (New-HDTStepResult -Status Completed).Message | Should -BeExactly ''
    }

    It 'defaults Data to null' {
        (New-HDTStepResult -Status Completed).Data | Should -BeNullOrEmpty
    }

    It 'rejects a status outside the set' {
        # The loop branches on Status and nothing else, so a fourth name would be
        # silently treated as neither success nor failure. The error id is
        # asserted because a missing implementation also throws.
        $record = $null
        try { New-HDTStepResult -Status 'Done' } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
    }

    It 'accepts <_> as a status' -ForEach @('Completed', 'Failed', 'RebootRequested') {
        (New-HDTStepResult -Status $_).Status | Should -BeExactly $_
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name New-HDTStepResult -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTStepResult'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
