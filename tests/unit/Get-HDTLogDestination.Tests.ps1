# MDT's SLShare, which HDT did not have.
#
# The copy-back destination was derived and nothing could change it: logs landed
# under <deployRoot>\Logs and nowhere else. MDT sites point SLShare at a log
# server precisely BECAUSE it is not the deployment share - a read-only share
# that a technician's account cannot write to, a site whose deployments run from
# a replica, a team that keeps deployment logs where the rest of their logs are.
#
# THE NAME IS MDT'S AND SO IS THE BEHAVIOUR. HDTSLShare, not HDTLogShare: an
# admin arriving from Workbench searches for what they already know.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:bag = {
        param([System.Collections.IDictionary] $Value)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $live[[string] $key] = $Value[$key] }
        }

        return $live
    }
}

Describe 'Get-HDTLogDestination' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTLogDestination' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'no HDTSLShare, which is every deployment that has ever run' {

        It 'lands under the deploy root, exactly where it always did' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' -Variable (& $script:bag $null)

            [string] $answer.Path | Should -BeExactly 'Z:\Deploy\Logs'
            [string] $answer.Source | Should -BeExactly 'DeployRoot'
        }

        It 'treats an empty HDTSLShare as no HDTSLShare' {
            # A rule that set it to '' is a rule that meant to leave it alone,
            # and a copy-back to the empty string is a run whose logs vanish.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '   ' }))

            [string] $answer.Path | Should -BeExactly 'Z:\Deploy\Logs'
            [string] $answer.Source | Should -BeExactly 'DeployRoot'
        }
    }

    Context 'HDTSLShare, MDT-style' {

        It 'sends the logs where the rule says' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '\\logs-01\HDTLogs' }))

            [string] $answer.Path | Should -BeExactly '\\logs-01\HDTLogs'
            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }

        It 'uses it verbatim rather than appending Logs to it' {
            # MDT's SLShare IS the folder - LiteTouch writes <SLShare>\<computer>
            # and never <SLShare>\Logs\<computer>. An engine that appended would
            # put logs somewhere the admin did not name.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '\\logs-01\HDTLogs' }))

            [string] $answer.Path | Should -Not -BeLike '*Logs\Logs*'
        }

        It 'trims what a rule left around it' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '  \\logs-01\HDTLogs  ' }))

            [string] $answer.Path | Should -BeExactly '\\logs-01\HDTLogs'
        }

        It 'takes a local path as readily as a UNC' {
            # A lab, a USB stick, standalone media: the log share does not have
            # to be a server.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = 'D:\HDTLogs' }))

            [string] $answer.Path | Should -BeExactly 'D:\HDTLogs'
            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }

        It 'reads the name case-insensitively, as every variable in this engine is' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ hdtslshare = '\\logs-01\HDTLogs' }))

            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }
    }

    Context 'a deployment with no root at all' {

        It 'returns nothing rather than a path built from an empty root' {
            # A run that never resolved a deploy root has nowhere to copy to,
            # and '\Logs' is a path on whatever drive the process happens to be
            # standing on.
            $answer = Get-HDTLogDestination -WorkspaceRoot '' -Variable (& $script:bag $null)

            [string] $answer.Path | Should -BeExactly ''
            [string] $answer.Source | Should -BeExactly 'None'
        }

        It 'still honours HDTSLShare when there is no deploy root' {
            # THE CASE THAT MAKES IT WORTH HAVING: the share could not be
            # reached, which is exactly the run whose log somebody needs.
            $answer = Get-HDTLogDestination -WorkspaceRoot '' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '\\logs-01\HDTLogs' }))

            [string] $answer.Path | Should -BeExactly '\\logs-01\HDTLogs'
            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }
    }
}
