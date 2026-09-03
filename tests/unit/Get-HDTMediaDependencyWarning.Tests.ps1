#requires -Version 5.1

# Get-HDTMediaDependencyWarning - the sentence that was worth hours.
#
# OBSERVED FOR REAL ON 2026-09-03: a hand-built disc carried TightVNC without
# the Acrobat package its app.yaml dependencies: names, and the deployment got to
# step 11 of 15 before finding out. MDT would have let the machine find out on
# the bench; HDT says so while the ISO is being built, in front of the person who
# can fix it.
#
# IT WARNS AND DOES NOT FIX (DESIGN 6.2): the selection profile is the
# administrator's statement of intent, and a build that quietly added an
# application nobody selected would be a disc whose contents no document
# describes.
#
# IT IS PURE - handed a catalog and a list of ids, returns sentences.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTTestApplicationEntry {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory object; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)]
            [string] $Id,

            [Parameter()]
            [AllowEmptyCollection()]
            [string[]] $Dependency = @()
        )

        return [pscustomobject] @{
            Id           = $Id
            Name         = $Id
            Dependencies = [string[]] @($Dependency)
        }
    }

    # The catalog the disc was built from: TightVNC needs Acrobat, Acrobat needs
    # the VC runtime, and Chrome needs nothing.
    $script:catalog = @(
        New-HDTTestApplicationEntry -Id 'TightVNC' -Dependency @('Acrobat')
        New-HDTTestApplicationEntry -Id 'Acrobat' -Dependency @('VCRedist')
        New-HDTTestApplicationEntry -Id 'VCRedist'
        New-HDTTestApplicationEntry -Id 'Chrome'
    )

    function Get-HDTMediaTestDependencyWarning {
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]] $Application,

            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [string[]] $CarriedId
        )

        return [string[]] @(InModuleScope Hephaestus -Parameters @{
                App = $Application; Carried = $CarriedId
            } {
                param($App, $Carried)

                Get-HDTMediaDependencyWarning -Application ([object[]] @($App)) -CarriedId ([string[]] @($Carried))
            })
    }
}

Describe 'Get-HDTMediaDependencyWarning' {

    Context 'the transitive closure' {

        It 'says nothing for a projection carrying every dependency' {
            @(Get-HDTMediaTestDependencyWarning -Application $script:catalog `
                    -CarriedId @('TightVNC', 'Acrobat', 'VCRedist')) | Should -BeNullOrEmpty
        }

        It 'says nothing for a projection carrying no applications at all' {
            @(Get-HDTMediaTestDependencyWarning -Application $script:catalog -CarriedId @()) |
                Should -BeNullOrEmpty
        }

        It 'warns when an application on the disc depends on one that is not' {
            @(Get-HDTMediaTestDependencyWarning -Application $script:catalog `
                    -CarriedId @('TightVNC', 'VCRedist')) | Should -Not -BeNullOrEmpty
        }

        It 'names BOTH applications - the one that is there and the one that is missing' {
            $sentence = @(Get-HDTMediaTestDependencyWarning -Application $script:catalog `
                    -CarriedId @('TightVNC', 'VCRedist'))

            ($sentence -join ' ') | Should -Match 'TightVNC'
            ($sentence -join ' ') | Should -Match 'Acrobat'
        }

        It 'follows a chain two deep, because the closure is transitive and a real disc proved it' {
            # TightVNC alone: Acrobat is one deep, VCRedist is two, and both are
            # missing. A pass that only read the carried applications' own
            # dependencies: lists would have found the first and not the second.
            $sentence = @(Get-HDTMediaTestDependencyWarning -Application $script:catalog `
                    -CarriedId @('TightVNC'))

            ($sentence -join ' ') | Should -Match 'Acrobat'
            ($sentence -join ' ') | Should -Match 'VCRedist'
        }

        It 'reports a dependency shared by two carried applications once' {
            $catalog = @(
                New-HDTTestApplicationEntry -Id 'AppOne' -Dependency @('Shared')
                New-HDTTestApplicationEntry -Id 'AppTwo' -Dependency @('Shared')
                New-HDTTestApplicationEntry -Id 'Shared'
            )

            $sentence = @(Get-HDTMediaTestDependencyWarning -Application $catalog `
                    -CarriedId @('AppOne', 'AppTwo'))

            @($sentence | Where-Object { $_ -match 'Shared' }).Count | Should -Be 1
        }

        It 'names every missing dependency when there is more than one' {
            $catalog = @(
                New-HDTTestApplicationEntry -Id 'AppOne' -Dependency @('MissingOne')
                New-HDTTestApplicationEntry -Id 'AppTwo' -Dependency @('MissingTwo')
                New-HDTTestApplicationEntry -Id 'MissingOne'
                New-HDTTestApplicationEntry -Id 'MissingTwo'
            )

            $sentence = @(Get-HDTMediaTestDependencyWarning -Application $catalog `
                    -CarriedId @('AppOne', 'AppTwo'))

            @($sentence).Count | Should -Be 2
            ($sentence -join ' ') | Should -Match 'MissingOne'
            ($sentence -join ' ') | Should -Match 'MissingTwo'
        }
    }

    Context 'what it does not do' {

        It 'does not add the missing dependency to the projection' {
            $carried = [string[]] @('TightVNC')

            [void] @(Get-HDTMediaTestDependencyWarning -Application $script:catalog -CarriedId $carried)

            $carried | Should -Be @('TightVNC')
        }

        It 'returns sentences and changes nothing' {
            $sentence = @(Get-HDTMediaTestDependencyWarning -Application $script:catalog -CarriedId @('TightVNC'))

            foreach ($current in $sentence) { $current | Should -BeOfType ([string]) }
        }
    }

    Context 'it fails soft' {

        # A BUILD THAT REFUSES TO MAKE A DISC OVER AN AUTHORING PROBLEM IN AN
        # APPLICATION NOBODY SELECTED IS A BUILD THAT HELPS NOBODY.
        # Resolve-HDTApplicationOrder throws for both of these, and correctly -
        # it is the install planner. Here they become a sentence.

        It 'reports a dependency naming an application the catalog has not got, rather than throwing' {
            $catalog = @(New-HDTTestApplicationEntry -Id 'TightVNC' -Dependency @('NotInCatalog'))

            $script:soft = $null
            { $script:soft = @(Get-HDTMediaTestDependencyWarning -Application $catalog -CarriedId @('TightVNC')) } |
                Should -Not -Throw

            $sentence = @($script:soft)
            @($sentence) | Should -Not -BeNullOrEmpty
            ($sentence -join ' ') | Should -Match 'NotInCatalog'
        }

        It 'reports a cycle as a sentence, because a build should say so and go on' {
            $catalog = @(
                New-HDTTestApplicationEntry -Id 'AppOne' -Dependency @('AppTwo')
                New-HDTTestApplicationEntry -Id 'AppTwo' -Dependency @('AppOne')
            )

            $script:soft = $null
            { $script:soft = @(Get-HDTMediaTestDependencyWarning -Application $catalog -CarriedId @('AppOne')) } |
                Should -Not -Throw

            $sentence = @($script:soft)
            @($sentence) | Should -Not -BeNullOrEmpty
            ($sentence -join ' ') | Should -Match 'AppOne'
        }
    }
}
