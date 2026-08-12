# DESIGN 12.2.5: unit + contract + PSScriptAnalyzer on every push, on a Windows
# runner, and a red suite blocks merge. The dual-engine requirement is only real
# if CI actually runs both editions, so that is asserted here rather than
# eyeballed in a review.
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

    It 'runs a matrix over pwsh and powershell' -Skip:$script:HDTYamlMissing {
        # shell: powershell on windows-latest IS Windows PowerShell 5.1. This is
        # what makes the 5.1 constraint enforced rather than aspirational.
        $shell = @($script:job['strategy']['matrix']['shell'])
        $shell | Should -Contain 'pwsh'
        $shell | Should -Contain 'powershell'
    }

    It 'does not fail fast, so both editions always report' -Skip:$script:HDTYamlMissing {
        $script:job['strategy']['fail-fast'] | Should -BeFalse
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
