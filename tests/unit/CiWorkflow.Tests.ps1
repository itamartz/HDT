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
