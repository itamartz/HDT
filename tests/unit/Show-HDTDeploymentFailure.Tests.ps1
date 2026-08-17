# THE FAILURE SCREEN, AND THE ONLY DECISION IN IT: what the three buttons mean.
#
# The window itself is Show-HDTWizard's - a XAML path, fields applied by name,
# an answer reported - so this command adds no WPF and no new host. What it adds
# is the mapping from a button to what the machine does next, and that is the
# part a payload acts on: a machine that powers off while the technician is
# still reading is the failure this whole screen exists to stop.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:xamlPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTFailure.xaml'

    $script:failure = [pscustomobject] @{
        IsFailure  = $true
        RunId      = 'run-20260818-090000'
        SequenceId = 'STD-CLIENT'
        StepNumber = 1
        StepCount  = 12
        StepName   = 'Validate'
        StepType   = 'Validate'
        Message    = 'disk 0 carries existing data'
        Status     = 'Failed'
        LogPath    = 'X:\HDT\Logs'
        Field      = @(
            [pscustomobject] @{ Name = 'HDTFailureStepText'; Text = 'Validate  (step 1 of 12)' }
            [pscustomobject] @{ Name = 'HDTFailureMessageText'; Text = 'disk 0 carries existing data' }
            [pscustomobject] @{ Name = 'HDTFailureLogText'; Text = 'X:\HDT\Logs' }
        )
    }
}

Describe 'Show-HDTDeploymentFailure' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Show-HDTDeploymentFailure' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what the three buttons mean' {

        It 'reads Restart as Restart' {
            $answer = Show-HDTDeploymentFailure -Failure $script:failure -XamlPath $script:xamlPath `
                -WizardHost (New-HDTFakeWizardHost -Action 'Next')

            [string] $answer.Action | Should -BeExactly 'Restart'
        }

        It 'reads Shut down as Shutdown' {
            $answer = Show-HDTDeploymentFailure -Failure $script:failure -XamlPath $script:xamlPath `
                -WizardHost (New-HDTFakeWizardHost -Action 'Cancel')

            [string] $answer.Action | Should -BeExactly 'Shutdown'
        }

        It 'reads Open CMD as CommandPrompt, which is what this screen is for' {
            $answer = Show-HDTDeploymentFailure -Failure $script:failure -XamlPath $script:xamlPath `
                -WizardHost (New-HDTFakeWizardHost -Action 'CommandPrompt')

            [string] $answer.Action | Should -BeExactly 'CommandPrompt'
        }

        It 'reads anything else as Shutdown' {
            # A window that answered nothing must not leave a failed machine
            # running for a week in a room nobody visits - but see the payload:
            # it is the technician's press that keeps it on, never a silence.
            $answer = Show-HDTDeploymentFailure -Failure $script:failure -XamlPath $script:xamlPath `
                -WizardHost (New-HDTFakeWizardHost -Action '')

            [string] $answer.Action | Should -BeExactly 'Shutdown'
        }
    }

    Context 'what it puts on the screen' {

        It 'hands the failure fields to the host' {
            $fakeHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTDeploymentFailure -Failure $script:failure -XamlPath $script:xamlPath -WizardHost $fakeHost | Out-Null

            @($fakeHost.LastField | ForEach-Object { [string] $_.Name }) | Should -Contain 'HDTFailureMessageText'
        }

        It 'shows the shipped failure window' {
            $fakeHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTDeploymentFailure -Failure $script:failure -XamlPath $script:xamlPath -WizardHost $fakeHost | Out-Null

            [string] $fakeHost.LastXaml | Should -BeLike '*HDTFailureMessageText*'
        }
    }

    Context 'a failure it was handed nothing about' {

        It 'refuses a window it cannot fill' {
            { Show-HDTDeploymentFailure -Failure $null -XamlPath $script:xamlPath `
                    -WizardHost (New-HDTFakeWizardHost -Action 'Cancel') } | Should -Throw
        }

        It 'reports Shutdown rather than throwing when the window will not open' {
            # A BOOT IMAGE WITH NO WPF STILL HAS TO END THE MACHINE. The failure
            # is already a failure; a screen that cannot be drawn must not
            # become a second one.
            $answer = Show-HDTDeploymentFailure -Failure $script:failure -XamlPath $script:xamlPath `
                -WizardHost (New-HDTFakeWizardHost -FailShow)

            [string] $answer.Action | Should -BeExactly 'Shutdown'
            [bool] $answer.Shown | Should -BeFalse
        }
    }
}
