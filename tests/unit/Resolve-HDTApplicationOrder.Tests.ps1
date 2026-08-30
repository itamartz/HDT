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
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test fixture object; it changes no state.')]
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

    # WHY AN APPLICATION IS IN THE PLAN, which the sort worked out and then threw
    # away. A real deployment asked for one application and installed two, and the
    # entire log record of the second was its id in the plan line - no statement
    # that nothing had asked for it, and no name of what had. An administrator
    # reading that cannot tell a dependency from a typo in HDTApplications.
    #
    # THE RESOLVER IS THE ONLY PLACE THAT KNOWS. The requester, the depth and the
    # chain exist in the closure walk; the tie and the wait exist in the sort.
    # Both were local variables that went out of scope. So the caller passes
    # collections in and this fills them, the way Expand-HDTVariableToken is
    # handed an Unresolved list to append to.
    Context 'the provenance it records' {

        BeforeEach {
            $script:provenance = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $script:decision = New-Object -TypeName System.Collections.ArrayList
        }

        It 'marks an application the selection named as requested, with no requester' {
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Corp-Baseline' `
                    -Provenance $script:provenance -Decision $script:decision)

            $record = $script:provenance['Corp-Baseline']

            $record.Requested | Should -BeTrue
            @($record.RequiredBy).Count | Should -Be 0
            $record.Reason | Should -BeExactly 'Requested'
            $record.Depth | Should -Be 0
        }

        It 'names the application that pulled in one nothing asked for' {
            # THE DEFECT, in one assertion. Suite was requested, Agent was not,
            # and the only thing that can explain Agent is Suite.
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            $record = $script:provenance['Contoso-Agent']

            $record.Requested | Should -BeFalse
            @($record.RequiredBy) | Should -Be @('Contoso-Suite')
            $record.Reason | Should -BeExactly 'Required'
        }

        It 'names the immediate requester of a transitive dependency, not the one that started it' {
            # Suite -> Agent -> VCRedist. VCRedist is in the plan because AGENT
            # needs it; naming Suite there sends an administrator to edit the
            # wrong app.yaml.
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            $record = $script:provenance['VCRedist-2015-2022']

            @($record.RequiredBy) | Should -Be @('Contoso-Agent')
            $record.Depth | Should -Be 2
        }

        It 'carries the whole chain that pulled in a transitive dependency' {
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            @($script:provenance['VCRedist-2015-2022'].Path) |
                Should -Be @('Contoso-Suite', 'Contoso-Agent', 'VCRedist-2015-2022')
        }

        It 'reports an application that was both requested and required as both' {
            # THE ONE A FIRST-WRITER-WINS RECORD GETS WRONG. Agent was asked for
            # by name AND is needed by Suite; a record holding only the first
            # answer it found tells half the story, whichever half it kept.
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog `
                    -Id @('Contoso-Suite', 'Contoso-Agent') `
                    -Provenance $script:provenance -Decision $script:decision)

            $record = $script:provenance['Contoso-Agent']

            $record.Requested | Should -BeTrue
            @($record.RequiredBy) | Should -Be @('Contoso-Suite')
            $record.Reason | Should -BeExactly 'RequestedAndRequired'
        }

        It 'names every requester of a dependency two applications share' {
            $catalog = @(
                New-HDTTestApplication -Id 'App-A' -Dependency @('Shared-Lib')
                New-HDTTestApplication -Id 'App-B' -Dependency @('Shared-Lib')
                New-HDTTestApplication -Id 'Shared-Lib'
            )

            $null = @(Resolve-HDTApplicationOrder -Application $catalog -Id @('App-A', 'App-B') `
                    -Provenance $script:provenance -Decision $script:decision)

            @($script:provenance['Shared-Lib'].RequiredBy) | Should -Be @('App-A', 'App-B')
        }

        It 'records one entry for every application in the plan and nothing else' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            @($script:provenance.Keys) | Should -Be @($plan | ForEach-Object { $_.Id })
        }

        It 'numbers each entry with the position it takes in the plan' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            foreach ($index in 0..(@($plan).Count - 1)) {
                $script:provenance[[string] $plan[$index].Id].Order | Should -Be ($index + 1)
            }
        }

        It 'says what an application waited for, which is why it sits where it does' {
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            @($script:provenance['VCRedist-2015-2022'].WaitedFor).Count | Should -Be 0
            @($script:provenance['Contoso-Agent'].WaitedFor) | Should -Be @('VCRedist-2015-2022')
        }

        It 'records the tie a ready application won, so the order is explicable' {
            # Corp-Baseline and VCRedist do not depend on each other; the sort
            # emits Baseline first because the id sorts first. That is a decision
            # worth writing down rather than a coincidence for a reader to spot.
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog `
                    -Id @('VCRedist-2015-2022', 'Corp-Baseline') `
                    -Provenance $script:provenance -Decision $script:decision)

            @($script:provenance['Corp-Baseline'].Ready) | Should -Be @('Corp-Baseline', 'VCRedist-2015-2022')
        }

        It 'records the selection it was given' {
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            $record = @(@($script:decision) | Where-Object { $_.Kind -eq 'Selection' })

            @($record).Count | Should -Be 1
            @($record[0].Id) | Should -Be @('Contoso-Suite')
            $record[0].WholeCatalog | Should -BeFalse
        }

        It 'records that the whole catalog was the selection when no id was given' {
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog `
                    -Provenance $script:provenance -Decision $script:decision)

            $record = @(@($script:decision) | Where-Object { $_.Kind -eq 'Selection' })

            $record[0].WholeCatalog | Should -BeTrue
        }

        It 'records each dependency edge it walked' {
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            $edge = @(@(@($script:decision) | Where-Object { $_.Kind -eq 'Edge' }) |
                    ForEach-Object { '{0}->{1}' -f $_.Id, $_.DependsOn })

            $edge | Should -Contain 'Contoso-Suite->Contoso-Agent'
            $edge | Should -Contain 'Contoso-Agent->VCRedist-2015-2022'
        }

        It 'records the second time an application was named rather than collapsing it silently' {
            # "installs a shared dependency only once" is a decision, and until
            # now the only evidence of it was an absence from the plan.
            $catalog = @(
                New-HDTTestApplication -Id 'App-A' -Dependency @('Shared-Lib')
                New-HDTTestApplication -Id 'App-B' -Dependency @('Shared-Lib')
                New-HDTTestApplication -Id 'Shared-Lib'
            )

            $null = @(Resolve-HDTApplicationOrder -Application $catalog -Id @('App-A', 'App-B') `
                    -Provenance $script:provenance -Decision $script:decision)

            $duplicate = @(@($script:decision) | Where-Object { $_.Kind -eq 'Duplicate' })

            @($duplicate).Count | Should -Be 1
            $duplicate[0].Id | Should -BeExactly 'Shared-Lib'
            $duplicate[0].NamedBy | Should -BeExactly 'App-B'
        }

        It 'records one round of the sort per application it emitted' {
            $plan = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            $round = @(@($script:decision) | Where-Object { $_.Kind -eq 'Round' })

            @($round).Count | Should -Be @($plan).Count
            @($round | ForEach-Object { $_.Emitted }) | Should -Be @($plan | ForEach-Object { $_.Id })
        }

        It 'records what each round was still blocked on' {
            $null = @(Resolve-HDTApplicationOrder -Application $script:catalog -Id 'Contoso-Suite' `
                    -Provenance $script:provenance -Decision $script:decision)

            $round = @(@($script:decision) | Where-Object { $_.Kind -eq 'Round' })
            $blocked = @($round[0].Blocked)

            @($blocked | ForEach-Object { $_.Id }) | Should -Be @('Contoso-Agent', 'Contoso-Suite')
            @($blocked[0].BlockedOn) | Should -Be @('VCRedist-2015-2022')
        }

        It 'leaves the trace behind when it refuses a cycle, so the log shows how far it got' {
            # THE COLLECTION BELONGS TO THE CALLER, which is what makes a partial
            # trace survive a terminating error at all. A step that fails on an
            # unorderable plan can still log the closure that led up to it.
            $catalog = @(
                New-HDTTestApplication -Id 'App-A' -Dependency @('App-B')
                New-HDTTestApplication -Id 'App-B' -Dependency @('App-A')
            )

            try {
                $null = @(Resolve-HDTApplicationOrder -Application $catalog `
                        -Provenance $script:provenance -Decision $script:decision)
            } catch {
                $null = $_
            }

            $cycle = @(@($script:decision) | Where-Object { $_.Kind -eq 'Cycle' })

            @($cycle).Count | Should -Be 1
            @($cycle[0].Stuck) | Should -Be @('App-A', 'App-B')
        }

        It 'orders exactly as it did without being asked for provenance' {
            $bare = @(Resolve-HDTApplicationOrder -Application $script:catalog)
            $traced = @(Resolve-HDTApplicationOrder -Application $script:catalog `
                    -Provenance $script:provenance -Decision $script:decision)

            @($traced | ForEach-Object { $_.Id }) | Should -Be @($bare | ForEach-Object { $_.Id })
        }
    }
}
