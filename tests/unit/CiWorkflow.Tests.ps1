# DESIGN 12.2.5: unit + contract + PSScriptAnalyzer on every push, on a Windows
# runner, and a red suite blocks merge.
#
# ONE EDITION, AND IT IS 5.1. The engine runs inside WinPE, which has no pwsh,
# so 5.1 is the edition that decides whether HDT works. CI used to run a matrix
# over both; a pwsh leg proves nothing WinPE cares about and can block a merge
# over a shell the product never runs under, so the matrix came out. Which
# edition the runner uses is therefore asserted here rather than eyeballed in a
# review - a silent drift back to pwsh would move the gate off the only edition
# that counts.
#
# YAML 1.1 gotcha: ConvertFrom-Yaml turns the GitHub Actions 'on:' key into the
# BOOLEAN $true. Never assert on a key named 'on' - trigger assertions are made
# against the raw file text.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
$script:HDTYamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')

Describe 'CI workflow (DESIGN 12.2.5)' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

        $script:workflowPath = Join-Path -Path $script:repoRoot -ChildPath '.github/workflows/ci.yml'

        $script:workflowText = ''
        if (Test-Path -Path $script:workflowPath -PathType Leaf) {
            $script:workflowText = Get-Content -Path $script:workflowPath -Raw
        }

        $script:workflow = $null
        if ($script:workflowText -and (Test-HDTModuleAvailable -Name 'powershell-yaml')) {
            $script:workflow = ConvertFrom-Yaml $script:workflowText
        }

        $script:job = $null
        if ($script:workflow -and $script:workflow.ContainsKey('jobs')) {
            $script:job = $script:workflow['jobs']['windows']
        }
    }

    It 'exists at .github/workflows/ci.yml' {
        Test-Path -Path $script:workflowPath -PathType Leaf | Should -BeTrue
    }

    It 'is valid YAML' -Skip:$script:HDTYamlMissing {
        $script:workflowText | Should -Not -BeNullOrEmpty
        { ConvertFrom-Yaml $script:workflowText } | Should -Not -Throw
        $script:workflow | Should -Not -BeNullOrEmpty
    }

    It 'runs on a Windows runner' -Skip:$script:HDTYamlMissing {
        $script:job | Should -Not -BeNullOrEmpty
        $script:job['runs-on'] | Should -BeExactly 'windows-latest'
    }

    It 'runs every step under Windows PowerShell 5.1' -Skip:$script:HDTYamlMissing {
        # shell: powershell on windows-latest IS Windows PowerShell 5.1. This is
        # what makes the 5.1 constraint enforced rather than aspirational.
        #
        # It is set once on defaults.run and inherited by every run: step. A
        # step-level shell: key cannot read the matrix context - GitHub rejects
        # the whole workflow with "Unrecognized named-value: 'matrix'" and
        # produces a run with zero jobs - which is why it lives here even now
        # that there is no matrix to read.
        $script:job['defaults']['run']['shell'] | Should -BeExactly 'powershell'
    }

    It 'runs no second edition' -Skip:$script:HDTYamlMissing {
        # A matrix leg over pwsh gates a merge on a shell WinPE does not ship.
        $script:job.ContainsKey('strategy') | Should -BeFalse
        $script:workflowText | Should -Not -Match '(?m)^\s*shell:\s*\[?.*pwsh'
    }

    It 'checks out the repository' {
        $script:workflowText | Should -Match 'actions/checkout'
    }

    It 'pins Pester to version 5' {
        # A bare Install-Module Pester pulls Pester 6, which breaks the 5.x
        # configuration API. That hazard has already been hit locally.
        $script:workflowText | Should -Match 'Install-Module\s+Pester\s+-RequiredVersion\s+5\.'
    }

    It 'installs PSScriptAnalyzer' {
        $script:workflowText | Should -Match 'Install-Module\s+PSScriptAnalyzer'
    }

    It 'does not measure coverage on the gate' {
        # Pester traces every command the suite executes to measure it: 10
        # minutes becomes 98 on a developer machine, which on a hosted runner
        # stands a multi-hour job in front of every push. It is nightly, in
        # coverage.yml. A gate nobody waits for is not a gate.
        $script:workflowText | Should -Match '(?m)\./build\.ps1\s+-Task\s+ci\s*$'
        $script:workflowText | Should -Not -Match '-Task\s+ci\s+-Coverage'
    }

    It 'writes the run its own summary' {
        # Twenty thousand lines of Pester output is not a report. The two
        # numbers belong on the run page.
        $script:workflowText | Should -Match 'GITHUB_STEP_SUMMARY'
    }

    Context 'the badges branch' {

        BeforeAll {
            $script:badgeStep = @($script:job['steps'] | Where-Object {
                    $_.ContainsKey('name') -and $_['name'] -eq 'Publish badges'
                })
        }

        It 'has a step that publishes them' {
            $script:badgeStep.Count | Should -Be 1
        }

        It 'publishes only from a push to main' {
            # A pull request from a fork has a read-only token, and a badge that
            # moved with every PR would report whatever was proposed last rather
            # than what is on main.
            $script:badgeStep[0]['if'] | Should -BeLike '*refs/heads/main*'
            $script:badgeStep[0]['if'] | Should -BeLike "*push*"
        }

        It 'pushes to a branch and never to the checkout the build ran from' {
            # An orphan checkout of THIS working tree is one `git rm -rf .` away
            # from deleting the tree the build just ran in.
            $script:badgeStep[0]['run'] | Should -BeLike '*RUNNER_TEMP*'
            $script:badgeStep[0]['run'] | Should -Not -BeLike '*checkout --orphan*'
        }

        It 'asks for write on contents and nothing else' {
            $permission = $script:workflow['permissions']

            $permission | Should -Not -BeNullOrEmpty
            $permission['contents'] | Should -BeExactly 'write'
            @($permission.Keys) | Should -Be @('contents')
        }
    }

    It 'invokes ./build.ps1 with the ci task' {
        # CI must never grow its own private build logic (DESIGN 12.2.5): it runs
        # the same entry point developers run.
        $script:workflowText | Should -Match '\./build\.ps1\s+-Task\s+ci'
    }

    It 'uploads test results even when the build fails' -Skip:$script:HDTYamlMissing {
        $uploadStep = @($script:job['steps'] | Where-Object {
                $_.ContainsKey('uses') -and $_['uses'] -like 'actions/upload-artifact*'
            })

        $uploadStep.Count | Should -BeGreaterThan 0
        $uploadStep[0].ContainsKey('if') | Should -BeTrue
        $uploadStep[0]['if'] | Should -BeExactly 'always()'
    }

    It 'triggers on push and pull_request' {
        # Raw text, deliberately: ConvertFrom-Yaml maps the 'on' key to $true.
        $script:workflowText | Should -Match '(?m)^on:'
        $script:workflowText | Should -Match '(?m)^\s+push:'
        $script:workflowText | Should -Match '(?m)^\s+pull_request:'
    }
}

Describe 'Coverage workflow' {

    # THE NUMBER ON THE FRONT PAGE, MEASURED ONCE A NIGHT, and kept out of the
    # way of the gate. Both files publish to the same badges branch, so the two
    # badges refresh on different clocks: tests on every push, coverage nightly.

    BeforeAll {
        $script:coverageRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:coveragePath = Join-Path -Path $script:coverageRoot -ChildPath '.github/workflows/coverage.yml'

        $script:coverageText = ''
        if (Test-Path -Path $script:coveragePath -PathType Leaf) {
            $script:coverageText = Get-Content -Path $script:coveragePath -Raw
        }

        $script:coverageJob = $null
        if ($script:coverageText -and (Test-HDTModuleAvailable -Name 'powershell-yaml')) {
            $script:coverageJob = (ConvertFrom-Yaml $script:coverageText)['jobs']['coverage']
        }
    }

    It 'exists at .github/workflows/coverage.yml' {
        Test-Path -Path $script:coveragePath -PathType Leaf | Should -BeTrue
    }

    It 'runs on a schedule and on demand, never on a push' {
        # Raw text, deliberately: ConvertFrom-Yaml maps the 'on' key to $true.
        $script:coverageText | Should -Match '(?m)^\s+schedule:'
        $script:coverageText | Should -Match '(?m)^\s+workflow_dispatch:'
        $script:coverageText | Should -Not -Match '(?m)^\s+push:'
    }

    It 'asks the build for coverage' {
        $script:coverageText | Should -Match '\./build\.ps1\s+-Task\s+test\s+-Coverage'
    }

    It 'uploads the JaCoCo report even when the run fails' -Skip:$script:HDTYamlMissing {
        $uploadStep = @($script:coverageJob['steps'] | Where-Object {
                $_.ContainsKey('uses') -and $_['uses'] -like 'actions/upload-artifact*'
            })

        $coverageStep = @($uploadStep | Where-Object { $_['with']['path'] -like '*coverage*' })

        $coverageStep.Count | Should -Be 1
        $coverageStep[0]['if'] | Should -BeExactly 'always()'
    }

    It 'is given a deadline rather than left burning for six hours' -Skip:$script:HDTYamlMissing {
        $script:coverageJob['timeout-minutes'] | Should -BeGreaterThan 0
        $script:coverageJob['timeout-minutes'] | Should -BeLessThan 360
    }

    It 'publishes the badges too' {
        $script:coverageText | Should -Match 'Publish badges'
    }
}
