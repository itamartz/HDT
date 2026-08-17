# THE VALIDATE PAGE'S VIEW MODEL - MDT's Validate dialog, answered without a
# window.
#
# THE CHECKS ARE DATA, NOT MARKUP. MDT compiles its list of checkboxes into
# Workbench; here the list is one table, the page binds an ItemsControl over it,
# and adding a check is an entry plus the step reading its key. Nothing in the
# XAML names a check.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:path = 'X:\Share\TaskSequences\DEMO\sequence.yaml'

    $script:line = [string[]] @(@'
schemaVersion: 1
id: DEMO-VALIDATE
name: validate page
steps:
  - group: Validation
    steps:
      - name: Validate
        type: Validate
        minRamMB: 2048
        minDiskGB: 60
      - name: Apply OS
        type: ApplyImage
        os: Win11
'@ -split "`r?`n")
}

Describe 'Get-HDTConsoleValidateCheck' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTConsoleValidateCheck' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'a Validate step' {

        BeforeAll {
            $script:view = Get-HDTConsoleValidateCheck -Line $script:line -Path $script:path -Name 'Validate'
        }

        It 'belongs on screen' {
            $script:view.IsValidateStep | Should -BeTrue
        }

        It 'offers every check the engine can make, not only the declared ones' {
            # MDT SHOWS ALL OF THEM, TICKED OR NOT. A page that listed only what
            # the document already says would be a page you cannot add a check
            # on - which is the whole reason to have one.
            @($script:view.Check).Count | Should -BeGreaterOrEqual 6
            @($script:view.Check | ForEach-Object { $_.Key }) | Should -Contain 'requireUefi'
        }

        It 'ticks the ones the document declares, and fills their values' {
            $ram = @($script:view.Check | Where-Object { $_.Key -eq 'minRamMB' })[0]

            $ram.Enabled | Should -BeTrue
            $ram.Value | Should -BeExactly '2048'
            $ram.Unit | Should -BeExactly 'MB'
        }

        It 'leaves the undeclared ones unticked and empty' {
            $uefi = @($script:view.Check | Where-Object { $_.Key -eq 'requireUefi' })[0]

            $uefi.Enabled | Should -BeFalse
            $uefi.Value | Should -BeExactly ''
        }

        It 'says what each check writes, so a press is a command' {
            foreach ($check in @($script:view.Check)) {
                $check.Command | Should -BeLike '*Set-HDTStepProperty*'
                $check.Command | Should -BeLike ('*{0}*' -f $check.Key)
            }
        }

        It 'gives each one a label and a hint rather than the yaml key' {
            foreach ($check in @($script:view.Check)) {
                $check.Label | Should -Not -BeNullOrEmpty
                $check.Label | Should -Not -Be $check.Key
                $check.Hint | Should -Not -BeNullOrEmpty
            }
        }

        It 'names the kind of control each one needs' {
            @($script:view.Check | ForEach-Object { $_.Kind }) | Should -Not -Contain ''

            $uefi = @($script:view.Check | Where-Object { $_.Key -eq 'requireUefi' })[0]
            $uefi.Kind | Should -BeExactly 'Switch'
        }
    }

    Context 'a step of any other type' {

        It 'says the page does not belong to it' {
            $view = Get-HDTConsoleValidateCheck -Line $script:line -Path $script:path -Name 'Apply OS'

            $view.IsValidateStep | Should -BeFalse
        }
    }

    Context 'the check list is the engine''s' {

        It 'names only keys the Validate step actually reads' {
            # A CHECK THE STEP DOES NOT READ IS A BOX THAT WRITES A SETTING
            # NOTHING ACTS ON - the exact failure the console rule exists to
            # prevent, and invisible from the window.
            $source = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                    -ChildPath 'src/Hephaestus/Public/Steps/Invoke-HDTValidateStep.ps1') -Raw

            $view = Get-HDTConsoleValidateCheck -Line $script:line -Path $script:path -Name 'Validate'

            foreach ($check in @($view.Check)) {
                $source | Should -BeLike ("*-Name '{0}'*" -f $check.Key) `
                    -Because ("the page offers '{0}'" -f $check.Key)
            }
        }
    }
}
