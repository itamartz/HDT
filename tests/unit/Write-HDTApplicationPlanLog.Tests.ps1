# The install plan, written down with the reason for every line of it.
#
# THE DEFECT THIS EXISTS FOR. A real deployment (run-20260830-204613) asked for
# ONE application and installed two. The entire log record of the second was its
# id inside 'install plan, in order:' - nothing said that nothing had requested
# it, and nothing named what had. An administrator reading that a week later
# cannot tell a dependency from a typo in HDTApplications, and on a machine where
# the extra install is unwanted they have no thread to pull.
#
# PROVENANCE IS ALREADY A FIRST-CLASS IDEA HERE. rules.yaml resolution records
# the source of every variable and Write-HDTVariableLog prints
# "HDTApplications = '...' (Rule)". The install plan was the one derived
# structure that threw it away, so this follows that idiom rather than inventing
# a second vocabulary: the id in single quotes, the way the cycle message and the
# missing-dependency message already name applications.
#
# IT IS PRIVATE, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A catalog with a real chain - Suite -> Agent -> VCRedist - plus a Baseline
    # that depends on nothing, which is what the tie is made of.
    $script:newApplication = {
        param([string] $Id, [string[]] $Dependency = @())

        return [pscustomobject] @{
            Id           = $Id
            Name         = ('{0} display name' -f $Id)
            Dependencies = [string[]] $Dependency
        }
    }

    $script:catalog = @(
        & $script:newApplication 'Contoso-Suite' @('Contoso-Agent')
        & $script:newApplication 'Contoso-Agent' @('VCRedist-2015-2022')
        & $script:newApplication 'VCRedist-2015-2022'
        & $script:newApplication 'Corp-Baseline'
    )

    # The whole resolution, run for real rather than hand-written: the writer's
    # job is to render what Resolve-HDTApplicationOrder actually produces, and a
    # fixture of what it is BELIEVED to produce would let the two drift.
    $script:resolve = {
        param([object[]] $Catalog, [string[]] $Id)

        $provenance = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $decision = New-Object -TypeName System.Collections.ArrayList
        $plan = @()

        try {
            $plan = @(Resolve-HDTApplicationOrder -Application $Catalog -Id $Id `
                    -Provenance $provenance -Decision $decision)
        } catch {
            $null = $_
        }

        return [pscustomobject] @{
            Plan       = $plan
            Provenance = $provenance
            Decision   = $decision
        }
    }

    $script:newLog = {
        param([string] $Level = 'Info')

        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 30, 20, 46, 13, [System.DateTimeKind]::Utc))

        return (New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level $Level)
    }

    $script:record = {
        $text = ''
        if ($script:fileSystem.File.ContainsKey('C:\HDT\Logs\HDT.jsonl')) {
            $text = [string] $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl']
        }

        return @(@($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
                ForEach-Object { $_ | ConvertFrom-Json })
    }

    $script:messageLike = {
        param([string] $Pattern)

        return @(@(& $script:record) | Where-Object { [string] $_.message -like $Pattern })
    }
}

Describe 'Write-HDTApplicationPlanLog' {

    Context 'the plan line' {

        It 'writes the plan in order, once, in the words it has always used' {
            # NOTHING HERE IS ALLOWED TO REWORD IT. It is the one line an
            # administrator already knows to grep for.
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision `
                    -Source ([ordered] @{ 'Contoso-Suite' = 'HDTApplications' })
            }

            $line = & $script:messageLike 'install plan, in order:*'

            @($line).Count | Should -Be 1
            [string] $line[0].message |
                Should -BeExactly 'install plan, in order: VCRedist-2015-2022, Contoso-Agent, Contoso-Suite'
        }

        It 'carries the requested and the pulled-in ids apart, as data' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision `
                    -Source ([ordered] @{ 'Contoso-Suite' = 'HDTApplications' })
            }

            $line = & $script:messageLike 'install plan, in order:*'

            @($line[0].data.requested) | Should -Be @('Contoso-Suite')
            @($line[0].data.required) | Should -Be @('VCRedist-2015-2022', 'Contoso-Agent')
        }

        It 'says how many the selection named and how many the closure added' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision `
                    -Source ([ordered] @{ 'Contoso-Suite' = 'HDTApplications' })
            }

            $line = & $script:messageLike 'the selection named*'

            @($line).Count | Should -Be 1
            [string] $line[0].message | Should -BeExactly `
                'the selection named 1 application and the dependency closure added 2 more, for a plan of 3.'
        }
    }

    Context 'why each application is in the plan' {

        It 'names the source that asked for one the selection named' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Corp-Baseline')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision `
                    -Source ([ordered] @{ 'Corp-Baseline' = 'HDTApplications' })
            }

            $line = & $script:messageLike "*'Corp-Baseline' is in the plan*"

            @($line).Count | Should -Be 1
            [string] $line[0].message | Should -BeExactly `
                "'Corp-Baseline' is in the plan because HDTApplications asked for it."
        }

        It 'falls back to naming the selection when the source is not known' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Corp-Baseline')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            [string] (& $script:messageLike "*'Corp-Baseline' is in the plan*")[0].message |
                Should -BeExactly "'Corp-Baseline' is in the plan because the selection asked for it."
        }

        It 'says outright that nothing asked for one the closure pulled in' {
            # THE SENTENCE THE REAL RUN WAS MISSING. Without it an unrequested
            # install is indistinguishable from a requested one.
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision `
                    -Source ([ordered] @{ 'Contoso-Suite' = 'HDTApplications' })
            }

            [string] (& $script:messageLike "*'Contoso-Agent' is in the plan*")[0].message |
                Should -BeExactly ("'Contoso-Agent' is in the plan because 'Contoso-Suite' depends on it. " +
                    "Nothing asked for it by name; the chain that pulled it in is " +
                    "Contoso-Suite -> Contoso-Agent.")
        }

        It 'names the immediate requester of a transitive dependency and shows the whole chain' {
            # A -> B -> C names B, not A. Naming A sends an administrator to edit
            # the wrong app.yaml, and the chain is what shows why both are true.
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision `
                    -Source ([ordered] @{ 'Contoso-Suite' = 'HDTApplications' })
            }

            [string] (& $script:messageLike "*'VCRedist-2015-2022' is in the plan*")[0].message |
                Should -BeExactly ("'VCRedist-2015-2022' is in the plan because 'Contoso-Agent' depends on it. " +
                    "Nothing asked for it by name; the chain that pulled it in is " +
                    "Contoso-Suite -> Contoso-Agent -> VCRedist-2015-2022.")
        }

        It 'reports one that was both asked for and depended on as both' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite', 'Contoso-Agent')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision `
                    -Source ([ordered] @{
                            'Contoso-Suite' = 'HDTApplications'
                            'Contoso-Agent' = 'HDTApplications'
                        })
            }

            [string] (& $script:messageLike "*'Contoso-Agent' is in the plan*")[0].message |
                Should -BeExactly ("'Contoso-Agent' is in the plan because HDTApplications asked for it, " +
                    "and because 'Contoso-Suite' depends on it.")
        }

        It 'names every requester of a dependency two applications share' {
            $catalog = @(
                & $script:newApplication 'App-A' @('Shared-Lib')
                & $script:newApplication 'App-B' @('Shared-Lib')
                & $script:newApplication 'Shared-Lib'
            )

            $log = & $script:newLog
            $resolved = & $script:resolve $catalog @('App-A', 'App-B')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            [string] (& $script:messageLike "*'Shared-Lib' is in the plan*")[0].message |
                Should -BeLike "*because 'App-A', 'App-B' depend on it.*"
        }

        It 'writes one line per application in the plan, in plan order' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            $line = & $script:messageLike '*is in the plan because*'

            @($line).Count | Should -Be 3
            [string] $line[0].message | Should -BeLike "'VCRedist-2015-2022'*"
            [string] $line[2].message | Should -BeLike "'Contoso-Suite'*"
        }

        It 'says all of it at Info, because an unrequested install is not a debugging detail' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            foreach ($line in @(& $script:messageLike '*is in the plan because*')) {
                [string] $line.level | Should -BeExactly 'Info'
            }
        }

        It 'carries the reason as structured data as well as text' {
            # THE LOG IS ALSO A DATA SET. "which machines installed something
            # nobody asked for" is a query over data.requested, not a grep.
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision `
                    -Source ([ordered] @{ 'Contoso-Suite' = 'HDTApplications' })
            }

            $data = (& $script:messageLike "*'VCRedist-2015-2022' is in the plan*")[0].data

            [string] $data.id | Should -BeExactly 'VCRedist-2015-2022'
            [int] $data.order | Should -Be 1
            $data.requested | Should -BeFalse
            @($data.requiredBy) | Should -Be @('Contoso-Agent')
            [int] $data.depth | Should -Be 2
            @($data.path) | Should -Be @('Contoso-Suite', 'Contoso-Agent', 'VCRedist-2015-2022')
            [string] $data.reason | Should -BeExactly 'Required'
        }
    }

    Context 'why each application sits where it does' {

        It 'says the first one was ready with nothing to wait for' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            [string] (& $script:messageLike 'plan position 1 of 3:*')[0].message |
                Should -BeExactly ("plan position 1 of 3: 'VCRedist-2015-2022' was ready immediately; " +
                    "it depends on nothing in the plan.")
        }

        It 'names what a later one waited for' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            [string] (& $script:messageLike 'plan position 2 of 3:*')[0].message |
                Should -BeExactly ("plan position 2 of 3: 'Contoso-Agent' was ready once " +
                    "'VCRedist-2015-2022' had installed, which it depends on.")
        }

        It 'says what a tie was broken against, so the order is not a coincidence' {
            # Corp-Baseline and VCRedist do not depend on each other. The sort
            # emits Baseline first because the id sorts first, and a reader who
            # is not told that is left inferring it.
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('VCRedist-2015-2022', 'Corp-Baseline')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            [string] (& $script:messageLike 'plan position 1 of 2:*')[0].message |
                Should -BeExactly ("plan position 1 of 2: 'Corp-Baseline' was ready immediately; " +
                    "it depends on nothing in the plan. 'VCRedist-2015-2022' was ready too, " +
                    "and the tie broke on the id in ordinal order.")
        }

        It 'writes a position line for every application, at Info' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            $line = & $script:messageLike 'plan position *'

            @($line).Count | Should -Be 3
            foreach ($entry in @($line)) { [string] $entry.level | Should -BeExactly 'Info' }
        }
    }

    Context 'the decisions the resolver used to keep to itself' {

        It 'says an application named twice is in the plan once' {
            $catalog = @(
                & $script:newApplication 'App-A' @('Shared-Lib')
                & $script:newApplication 'App-B' @('Shared-Lib')
                & $script:newApplication 'Shared-Lib'
            )

            $log = & $script:newLog
            $resolved = & $script:resolve $catalog @('App-A', 'App-B')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            $line = & $script:messageLike "*was named again*"

            @($line).Count | Should -Be 1
            [string] $line[0].message | Should -BeExactly ("'Shared-Lib' was named again by 'App-B', " +
                "which also depends on it; it is in the plan once and installs once.")
            [string] $line[0].level | Should -BeExactly 'Info'
        }

        It 'writes every dependency edge it walked, at Debug' {
            # VOLUME, not importance. The edges are the graph itself and a plan of
            # forty applications has hundreds of them; the per-application lines
            # above carry the part an administrator needs at Info.
            $log = & $script:newLog 'Debug'
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            $line = & $script:messageLike 'dependency edge:*'

            @($line).Count | Should -Be 2
            @($line | ForEach-Object { [string] $_.message }) |
                Should -Contain "dependency edge: 'Contoso-Suite' depends on 'Contoso-Agent'."
            foreach ($entry in @($line)) { [string] $entry.level | Should -BeExactly 'Debug' }
        }

        It 'writes each round of the sort, at Debug' {
            $log = & $script:newLog 'Debug'
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            $line = & $script:messageLike 'sort round *'

            @($line).Count | Should -Be 3
            [string] $line[0].message | Should -BeExactly ("sort round 1: ready 'VCRedist-2015-2022'; " +
                "emitted 'VCRedist-2015-2022'; still blocked 'Contoso-Agent' on 'VCRedist-2015-2022', " +
                "'Contoso-Suite' on 'Contoso-Agent'.")
        }

        It 'keeps the edges and the rounds off an Info log' {
            $log = & $script:newLog
            $resolved = & $script:resolve $script:catalog @('Contoso-Suite')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            @(& $script:messageLike 'dependency edge:*').Count | Should -Be 0
            @(& $script:messageLike 'sort round *').Count | Should -Be 0
        }
    }

    Context 'a plan that could not be ordered' {

        It 'writes the cycle it found as a warning, with no plan to report' {
            # THE TRACE SURVIVES THE THROW because the collections belong to the
            # caller. Without this the one run where the resolution mattered is
            # the one run with no record of it.
            $catalog = @(
                & $script:newApplication 'App-A' @('App-B')
                & $script:newApplication 'App-B' @('App-A')
            )

            $log = & $script:newLog
            $resolved = & $script:resolve $catalog @('App-A')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            $line = & $script:messageLike 'sort round 1 found nothing ready*'

            @($line).Count | Should -Be 1
            [string] $line[0].message | Should -BeExactly ("sort round 1 found nothing ready and 2 " +
                "applications left: 'App-A', 'App-B'. They depend on each other, so this plan " +
                "cannot be ordered.")
            [string] $line[0].level | Should -BeExactly 'Warning'
            @($line[0].data.stuck) | Should -Be @('App-A', 'App-B')
        }

        It 'writes no plan line when there is no plan' {
            $catalog = @(
                & $script:newApplication 'App-A' @('App-B')
                & $script:newApplication 'App-B' @('App-A')
            )

            $log = & $script:newLog
            $resolved = & $script:resolve $catalog @('App-A')

            InModuleScope Hephaestus -Parameters @{ Log = $log; Resolved = $resolved } {
                Write-HDTApplicationPlanLog -Context $Log -Plan $Resolved.Plan `
                    -Provenance $Resolved.Provenance -Decision $Resolved.Decision
            }

            @(& $script:messageLike 'install plan, in order:*').Count | Should -Be 0
            @(& $script:messageLike '*is in the plan because*').Count | Should -Be 0
        }
    }
}
