# THE SHARE'S ADDRESS LIVES IN TWO FILES AND NOTHING COMPARED THEM.
#
# workspace.yaml carries deployRoot. bootstrap-rules.yaml carries HDTDeployRoot
# per rule and OVERRIDES it, because it is read in WinPE before the share is
# reachable - MDT's Bootstrap.ini, and the right design.
#
# IT COST AN AFTERNOON. The lab's DHCP lease moved, deployRoot was corrected,
# the boot image was rebuilt, and every machine still went looking for the old
# address because both bootstrap rules still named it. Nothing said the two
# disagreed - and the Welcome screen showed the CORRECTED address in its box,
# which is filled from the workspace, so the stale rule that actually drove the
# connection was never on screen.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTTestBootstrapRule {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([string] $Name, [string] $DeployRoot)

        $set = [ordered] @{}
        if (-not [string]::IsNullOrEmpty($DeployRoot)) { $set['HDTDeployRoot'] = $DeployRoot }

        return [pscustomobject] @{ Name = $Name; Set = $set }
    }
}

Describe 'Get-HDTBootstrapDeployRootWarning' {

    It 'is reachable inside the module' {
        InModuleScope Hephaestus {
            Get-Command -Name 'Get-HDTBootstrapDeployRootWarning' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'says nothing when the rule names the same share' {
        InModuleScope Hephaestus {
            $rule = [pscustomobject] @{ Name = 'Lab'; Set = [ordered] @{ HDTDeployRoot = '\\host\share' } }

            @(Get-HDTBootstrapDeployRootWarning -DeployRoot '\\host\share' -Rule ([object[]] @($rule))) |
                Should -BeNullOrEmpty
        }
    }

    # THE ONE THAT HAPPENED.
    It 'names the rule, the share it sends to, and the one the workspace claims' {
        InModuleScope Hephaestus {
            $rule = [pscustomobject] @{ Name = 'Lab, by gateway'; Set = [ordered] @{ HDTDeployRoot = '\\192.168.2.39\HDTShare' } }

            $warning = @(Get-HDTBootstrapDeployRootWarning -DeployRoot '\\192.168.2.112\HDTShare' -Rule ([object[]] @($rule)))

            @($warning).Count | Should -Be 1
            $warning[0] | Should -BeLike '*Lab, by gateway*'
            $warning[0] | Should -BeLike '*192.168.2.39*'
            $warning[0] | Should -BeLike '*192.168.2.112*'
        }
    }

    It 'warns once per rule that disagrees' {
        InModuleScope Hephaestus {
            $rule = @(
                [pscustomobject] @{ Name = 'A'; Set = [ordered] @{ HDTDeployRoot = '\\old\share' } }
                [pscustomobject] @{ Name = 'B'; Set = [ordered] @{ HDTDeployRoot = '\\old\share' } }
                [pscustomobject] @{ Name = 'C'; Set = [ordered] @{ HDTDeployRoot = '\\new\share' } }
            )

            @(Get-HDTBootstrapDeployRootWarning -DeployRoot '\\new\share' -Rule ([object[]] $rule)).Count |
                Should -Be 2
        }
    }

    It 'ignores a rule that sets no share at all' {
        # Most rules set an account, not a share.
        InModuleScope Hephaestus {
            $rule = [pscustomobject] @{ Name = 'Credentials'; Set = [ordered] @{ HDTUserId = 'svc' } }

            @(Get-HDTBootstrapDeployRootWarning -DeployRoot '\\host\share' -Rule ([object[]] @($rule))) |
                Should -BeNullOrEmpty
        }
    }

    It 'ignores a share picked at run time, which names no server to check' {
        InModuleScope Hephaestus {
            $rule = [pscustomobject] @{ Name = 'By site'; Set = [ordered] @{ HDTDeployRoot = '\\%HDTSiteServer%\share' } }

            @(Get-HDTBootstrapDeployRootWarning -DeployRoot '\\host\share' -Rule ([object[]] @($rule))) |
                Should -BeNullOrEmpty
        }
    }

    It 'treats a trailing slash and a difference of case as the same share' {
        InModuleScope Hephaestus {
            $rule = [pscustomobject] @{ Name = 'Lab'; Set = [ordered] @{ HDTDeployRoot = '\\HOST\Share\' } }

            @(Get-HDTBootstrapDeployRootWarning -DeployRoot '\\host\share' -Rule ([object[]] @($rule))) |
                Should -BeNullOrEmpty
        }
    }

    It 'says nothing when the image has no share of its own to disagree with' {
        InModuleScope Hephaestus {
            $rule = [pscustomobject] @{ Name = 'Lab'; Set = [ordered] @{ HDTDeployRoot = '\\host\share' } }

            @(Get-HDTBootstrapDeployRootWarning -DeployRoot '' -Rule ([object[]] @($rule))) |
                Should -BeNullOrEmpty
        }
    }
}
