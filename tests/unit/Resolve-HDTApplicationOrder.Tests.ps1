# Resolve-HDTApplicationOrder turns a catalog plus a selection into THE install
# plan - the ordered list DESIGN 8 says is logged before anything executes.
#
# DETERMINISM IS THE POINT, not a nicety. The plan is logged before execution and
# read afterwards when a build goes wrong, so the same catalog and the same
# selection must produce the same order every time, on every machine. A
# topological sort has freedom wherever two applications are independent, and
# that freedom is spent on the id in ordinal order rather than on whatever order
# the filesystem happened to enumerate.
#
# A CYCLE IS AN AUTHORING ERROR, reported naming every application in it. MDT
# hangs; the design's whole claim here is that HDT does not.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # The sort reads two properties off an application - Id and Dependencies - so
    # the fixtures carry those and a Name to prove the object is passed through
    # rather than rebuilt.
    function New-HDTTestApplication {
        param([string] $Id, [string[]] $Dependency = @())

        return [pscustomobject] @{
            Id           = $Id
            Name         = ('{0} display name' -f $Id)
            Dependencies = [string[]] $Dependency
        }
    }
}

Describe 'Resolve-HDTApplicationOrder' {

    BeforeEach {
        # Suite -> Agent -> VCRedist, plus a Baseline that depends on nothing.
        # Declared in an order that is ALREADY WRONG, so a function that returned
        # its input unchanged would fail.
        $script:catalog = @(
            New-HDTTestApplication -Id 'Contoso-Suite' -Dependency @('Contoso-Agent')
            New-HDTTestApplication -Id 'Contoso-Agent' -Dependency @('VCRedist-2015-2022')
            New-HDTTestApplication -Id 'VCRedist-2015-2022'
            New-HDTTestApplication -Id 'Corp-Baseline'
        )
    }

    Context 'the order it produces' {

        It 'puts a dependency before the application that needs it' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite')

            @($plan | ForEach-Object { $_.Id }) |
                Should -Be @('VCRedist-2015-2022', 'Contoso-Agent', 'Contoso-Suite')
        }

        It 'returns the application objects it was given, not rebuilt ones' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Agent')

            $plan[0].Name | Should -BeExactly 'VCRedist-2015-2022 display name'
        }

        It 'orders the whole catalog when no selection is given' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog)

            @($plan).Count | Should -Be 4
            [array]::IndexOf(@($plan | ForEach-Object { $_.Id }), 'VCRedist-2015-2022') |
                Should -BeLessThan ([array]::IndexOf(@($plan | ForEach-Object { $_.Id }), 'Contoso-Agent'))
        }

        It 'passes an application with no dependencies straight through' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Corp-Baseline')

            @($plan | ForEach-Object { $_.Id }) | Should -Be @('Corp-Baseline')
        }
    }

    Context 'determinism' {

        It 'breaks a tie between independent applications on the id, in ordinal order' {
            # Corp-Baseline and VCRedist-2015-2022 do not depend on each other, so
            # the sort is free to emit them in either order. It spends that freedom
            # on the id so the plan does not change between runs.
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id @('VCRedist-2015-2022', 'Corp-Baseline'))

            @($plan | ForEach-Object { $_.Id }) | Should -Be @('Corp-Baseline', 'VCRedist-2015-2022')
        }

        It 'produces the same plan whatever order the catalog arrives in' {
            $forward = @(Resolve-HDTApplicationOrder -Application $script:catalog)

            $reversed = @($script:catalog)
            [array]::Reverse($reversed)
            $backward = @(Resolve-HDTApplicationOrder -Application $reversed)

            @($backward | ForEach-Object { $_.Id }) | Should -Be @($forward | ForEach-Object { $_.Id })
        }

        It 'produces the same plan whatever order the selection arrives in' {
            $one = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id @('Corp-Baseline', 'Contoso-Suite'))
            $two = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id @('Contoso-Suite', 'Corp-Baseline'))

            @($two | ForEach-Object { $_.Id }) | Should -Be @($one | ForEach-Object { $_.Id })
        }
    }

    Context 'the selection' {

        It 'pulls in transitive dependencies that were not selected' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite')

            @($plan | ForEach-Object { $_.Id }) | Should -Contain 'VCRedist-2015-2022'
        }

        It 'leaves out an application nothing selected depends on' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite')

            @($plan | ForEach-Object { $_.Id }) | Should -Not -Contain 'Corp-Baseline'
        }

        It 'installs an application named twice only once' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id @('Contoso-Agent', 'Contoso-Agent'))

            @($plan | ForEach-Object { $_.Id }) | Should -Be @('VCRedist-2015-2022', 'Contoso-Agent')
        }

        It 'installs a shared dependency only once' {
            $catalog = @(
                New-HDTTestApplication -Id 'App-A' -Dependency @('Shared-Lib')
                New-HDTTestApplication -Id 'App-B' -Dependency @('Shared-Lib')
                New-HDTTestApplication -Id 'Shared-Lib'
            )

            $plan = @(Resolve-HDTApplicationOrder -Application $catalog -Id @('App-A', 'App-B'))

            @($plan | ForEach-Object { $_.Id }) | Should -Be @('Shared-Lib', 'App-A', 'App-B')
        }

        It 'returns nothing for an empty selection' {
            @(Resolve-HDTApplicationOrder -Application $script:catalog -Id @()).Count | Should -Be 0
        }
    }

    Context 'what it refuses' {

        It 'names every application in a cycle' {
            $catalog = @(
                New-HDTTestApplication -Id 'App-A' -Dependency @('App-B')
                New-HDTTestApplication -Id 'App-B' -Dependency @('App-C')
                New-HDTTestApplication -Id 'App-C' -Dependency @('App-A')
            )

            $message = ''
            try {
                $null = @(Resolve-HDTApplicationOrder -Application $catalog)
            } catch {
                $message = [string] $_.Exception.Message
            }

            foreach ($id in @('App-A', 'App-B', 'App-C')) {
                $message | Should -BeLike ('*{0}*' -f $id)
            }
        }

        It 'reports a cycle as a configuration error rather than hanging' {
            $catalog = @(
                New-HDTTestApplication -Id 'App-A' -Dependency @('App-B')
                New-HDTTestApplication -Id 'App-B' -Dependency @('App-A')
            )

            $record = $null
            try {
                $null = @(Resolve-HDTApplicationOrder -Application $catalog)
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'names the dependent and the dependency when a dependency is not in the catalog' {
            $catalog = @(
                New-HDTTestApplication -Id 'Contoso-Suite' -Dependency @('Not-Imported')
            )

            $message = ''
            try {
                $null = @(Resolve-HDTApplicationOrder -Application $catalog)
            } catch {
                $message = [string] $_.Exception.Message
            }

            $message | Should -BeLike '*Contoso-Suite*'
            $message | Should -BeLike '*Not-Imported*'
        }

        It 'names an application selected that the catalog does not hold' {
            { Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Not-Imported' } |
                Should -Throw -ExpectedMessage '*Not-Imported*'
        }

        It 'refuses a catalog holding two applications with the same id' {
            $catalog = @(
                New-HDTTestApplication -Id 'App-A'
                New-HDTTestApplication -Id 'App-A'
            )

            { Resolve-HDTApplicationOrder -Application $catalog } |
                Should -Throw -ExpectedMessage '*App-A*'
        }
    }
}
