# THE VALIDATE PAGE'S VIEW MODEL - MDT's Validate dialog, answered without a
# window.
#
# THE CHECKS ARE DATA, NOT MARKUP. MDT compiles its list of checkboxes into
# Workbench; here the list is one table, the page binds an ItemsControl over it,
# and adding a check is an entry plus the step reading its key. Nothing in the
# XAML names a check.

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

    Context 'which deployment type a check belongs to' {

        # A CHECK THAT DOES NOTHING ON THIS RUN HAS TO SAY SO ON ITS ROW. Five of
        # the nine are scoped, and a flat list of nine identical rows tells a
        # technician nothing: minDiskGB ticked at 60 reads exactly the same
        # whether it is the floor that picks the target disk or a setting the
        # run will report SKIPPED. The hint behind the ? says it, and a hint
        # behind a ? is read once, when the check is new.
        #
        # THE SCOPES ARE WALKED, NOT NAMED. Get-HDTValidateCheckDefinition is
        # the one place a scope is declared (CLAUDE.md rule 8), so these assert
        # over the SET: a sixth scoped check added to that table has to appear
        # correctly here with nothing in the console edited, and a test that
        # named minDiskGB would pass for it and fail nobody after it.

        BeforeAll {
            $script:scoped = Get-HDTConsoleValidateCheck -Line $script:line -Path $script:path -Name 'Validate'
        }

        It 'the table has scoped checks at all, so the assertions below are not vacuous' {
            @(Get-HDTValidateCheckDefinition | Where-Object { $_.Scope -ne 'Any' }).Count |
                Should -BeGreaterThan 0
        }

        It 'carries every check''s scope through from the table to the row it binds' {
            foreach ($definition in @(Get-HDTValidateCheckDefinition)) {
                $row = @($script:scoped.Check | Where-Object { $_.Key -eq $definition.Key })[0]

                $row | Should -Not -BeNullOrEmpty -Because ("the page offers '{0}'" -f $definition.Key)
                $row.Scope | Should -BeExactly ([string] $definition.Scope) `
                    -Because ("'{0}' is scoped '{1}' in the definition table" -f $definition.Key, $definition.Scope)
            }
        }

        It 'shows the badge on exactly the checks the table scopes, and on no others' {
            # 'Any' IS EVERY RUN, AND A BADGE ON EVERY ROW MARKS NOTHING. The
            # word WPF binds is decided here rather than by a converter in
            # markup - a converter is a decision living in a file no test runs.
            foreach ($definition in @(Get-HDTValidateCheckDefinition)) {
                $row = @($script:scoped.Check | Where-Object { $_.Key -eq $definition.Key })[0]

                $expected = 'Visible'
                if ([string] $definition.Scope -eq 'Any') { $expected = 'Collapsed' }

                $row.ScopeVisibility | Should -BeExactly $expected `
                    -Because ("'{0}' is scoped '{1}'" -f $definition.Key, $definition.Scope)
            }
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


}
