# DESIGN 12.2.5: unit + contract + PSScriptAnalyzer on every push, on a Windows
# runner, and a red suite blocks merge.
#
# ONE EDITION, AND IT IS 5.1. The engine runs inside WinPE, which has no pwsh,
# so 5.1 is the edition that decides whether HDT works. Which edition the runner
# uses is asserted here rather than eyeballed in a review, in BOTH directions: a
# drift off 5.1 would move the gate away from the only edition that counts, and
# a second leg coming back would gate a merge on a shell the product never runs
# under.
#
# THE MATRIX HAS BEEN CUT TWICE AND ADDED BACK ONCE, so the reason is written
# down here rather than left to be re-derived a third time.
#
# The case FOR a pwsh leg was that two contracts were asleep without it. Both
# are awake on 5.1 now, and neither needed a second engine - they needed the
# tests fixing:
#
#   - Thirteen suites validated schemas/*.schema.json with Test-Json, which is
#     PowerShell 6+, so each opened with `-Skip:(-not (Get-Command Test-Json))`
#     and vanished whole on the gate. They validate with Test-HDTJsonSchema now,
#     which is 5.1's own.
#   - PowerShell51Compatibility.Contract wanted 7 to prove a forbidden operator
#     is detectable. Under 5.1 a `??` is a PARSE ERROR and the scanner reports
#     that as a violation, so 5.1 is the stronger engine for that contract, not
#     the weaker one.
#
# The case AGAINST is unchanged and now unanswered: a green pwsh leg proves
# nothing WinPE cares about, a red one blocks a merge over a shell HDT does not
# support, and one already has - PSUseSingularNouns fires differently between
# the editions over a rule with no bearing on the engine.
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
        # shell: powershell on windows-latest IS Windows PowerShell 5.1, which
        # is what makes the WinPE constraint enforced rather than aspirational.
        #
        # It is set once on defaults.run and inherited by every run: step. A
        # step-level shell: key cannot read a matrix context - GitHub rejects
        # the whole workflow with "Unrecognized named-value: 'matrix'" and
        # produces a run with zero jobs - which is why it lives there even now
        # that there is no matrix to read.
        $script:job['defaults']['run']['shell'] | Should -BeExactly 'powershell'
    }

    It 'runs no second edition' -Skip:$script:HDTYamlMissing {
        # THE RULE, WITH ITS REASON, so that adding a leg back is a decision
        # somebody makes rather than a line somebody slips in.
        #
        # A pwsh leg gates a merge on a shell WinPE does not ship. The two
        # contracts that once justified one - the schema suites and the 5.1
        # syntax contract - both run on 5.1 now; see this file's header.
        #
        # Asserted twice over: no strategy block at all, AND no pwsh in a shell:
        # key anywhere in the file, because a matrix reintroduced under another
        # job name would satisfy the first alone.
        $script:job.ContainsKey('strategy') | Should -BeFalse -Because (
            'a matrix over the editions would put the gate back on a shell HDT does not support. ' +
            'If you are adding one, say why in this test rather than deleting it')

        $script:workflowText | Should -Not -Match '(?m)^\s*shell:\s*\[?.*pwsh'
    }

    It 'gates on an edition that can validate the schemas' -Skip:$script:HDTYamlMissing {
        # WHY THE SECOND LEG IS NOT NEEDED, asserted rather than asserted in a
        # comment. Thirteen suites used to skip whole on this runner because
        # Test-Json is PowerShell 6+, and the pwsh leg existed to run them. If
        # one of them reverts to Test-Json it goes back to validating no schema
        # here, silently, and nothing else in CI would say so.
        $contract = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/contract') `
                -Filter '*Schema.Contract.Tests.ps1' -File)

        @($contract).Count | Should -BeGreaterThan 5

        $guarded = @($contract |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Get-Command\s+-Name\s+Test-Json' } |
                ForEach-Object { $_.Name })

        $guarded -join ', ' | Should -BeExactly '' -Because (
            'a suite guarded on Test-Json skips itself whole on Windows PowerShell 5.1 and reports green ' +
            'having executed nothing. Validate with Test-HDTJsonSchema, which exists there')
    }

    It 'is given a deadline rather than left burning for six hours' -Skip:$script:HDTYamlMissing {
        # GitHub's default job timeout is 360 minutes. The suite is ~10 minutes
        # on a developer machine and ~20 here, so a hung DISM or a wedged Pester
        # runner would burn six hours of runner time in front of every push
        # behind it. coverage.yml has had a deadline all along; this had none.
        $script:job['timeout-minutes'] | Should -BeGreaterThan 30
        $script:job['timeout-minutes'] | Should -BeLessThan 90
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

        It 'cannot fire when the release path calls this workflow' {
            # THE ONE THING A RELEASE-PATH INVOCATION MUST NOT DO. publish.yml
            # calls this workflow, and a called workflow sees the CALLER's
            # github context - so on a release `github.event_name` really is
            # 'push' and the first half of this guard is satisfied.
            #
            # `github.ref` IS WHAT STOPS IT. A release runs on refs/tags/v0.25.0
            # and this requires refs/heads/main, which no tag ref can ever
            # equal - so the badge step is skipped, nothing is pushed to the
            # badges branch, and a release cannot race the branch's own run for
            # the same commit parent. The manual publish path is skipped twice
            # over: workflow_dispatch is not 'push' either.
            #
            # THIS IS THE GUARD, NOT THE TOKEN. The calling job has to grant
            # contents: write, because a called workflow may not ask for more
            # than its caller holds and this file declares write at workflow
            # level. So the ref comparison is the whole defence, and it is
            # asserted here rather than left as a happy accident of the
            # condition written for a different reason.
            $script:badgeStep[0]['if'] | Should -BeLike '*refs/heads/main*'
            $script:badgeStep[0]['if'] | Should -BeLike "*github.ref ==*"
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

    It 'is one definition the release path can call, not a shape to copy' {
        # publish.yml RUNS THIS FILE BEFORE IT SHIPS ANYTHING. A tag used to go
        # to the Gallery on the strength of "the commit passed CI on main",
        # which is true until the tag points at an older commit, or is pushed
        # while the branch's own run is still going, or names a commit that
        # reached main by a route that did not run CI.
        #
        # CALLED, NOT COPIED, for the same reason as e2e.yml: the release then
        # runs the IDENTICAL gate the branch does, and a change to the pins or
        # the edition reaches both callers or neither.
        $script:workflowText | Should -Match '(?m)^\s{2}workflow_call:'
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

    It 'names the artefact it uploads' -Skip:$script:HDTYamlMissing {
        # actions/upload-artifact@v4 REFUSES a name that already exists rather
        # than appending to it, so this was per-leg while there was a matrix.
        # With one job the name is a constant, and it is still asserted: an
        # unnamed upload lands under 'artifact' and the next workflow to add one
        # collides with it.
        $uploadStep = @($script:job['steps'] | Where-Object {
                $_.ContainsKey('uses') -and $_['uses'] -like 'actions/upload-artifact*'
            })

        $uploadStep[0]['with']['name'] | Should -BeExactly 'pester-powershell'
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

Describe 'Artefact uploads (every workflow)' {

    # A GREEN GATE MUST NOT GO RED BECAUSE GITHUB'S STORAGE SAID NO.
    #
    # Run 34250900149 built, linted, tested and self-checked clean - 15693
    # passed, the badge pushed brightgreen - and reported failure, because
    # actions/upload-artifact@v4 got HTTP 403 from the artifact service while
    # finalising. The bytes had already gone up; only the finalise handshake was
    # refused, the action calls that non-retryable and exits 1, and one optional
    # diagnostic copy sank the whole run. The identical step, name and path had
    # succeeded four hours earlier on the same runner image.
    #
    # THE VERDICT BELONGS TO build.ps1, NOT TO A BLOB STORE. Every one of these
    # steps uploads a convenience copy of something the run already reports
    # another way - the NUnit xml behind a summary and a badge that are written
    # before it, the e2e screenshots behind an assertion that already failed. A
    # transport error on any of them is worth an annotation and is not worth a
    # merge.
    #
    # continue-on-error IS NOT if-no-files-found. The latter is already `warn`
    # (or `ignore`), so a missing report has never failed a step; the only thing
    # this suppresses is the service refusing to take a file that exists. The
    # step still shows red on the run page, so the failure stays visible.
    #
    # ACROSS THE SET, because the coupling is in every one of them and fixing
    # only the step that happened to break leaves the next one to be diagnosed
    # from scratch. Same class as the lab-safety guards that failed CI for being
    # a CI runner: the environment, not the code.

    BeforeAll {
        $script:uploadRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        $script:uploadWorkflow = @(Get-ChildItem `
                -LiteralPath (Join-Path -Path $script:uploadRepoRoot -ChildPath '.github/workflows') `
                -Filter '*.yml' -File)

        $script:uploadStep = @(
            if (Test-HDTModuleAvailable -Name 'powershell-yaml') {
                foreach ($file in $script:uploadWorkflow) {
                    $document = ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw)
                    if (-not ($document -is [System.Collections.IDictionary]) -or -not $document.Contains('jobs')) { continue }

                    foreach ($jobName in @($document['jobs'].Keys)) {
                        $job = $document['jobs'][$jobName]
                        if (-not ($job -is [System.Collections.IDictionary]) -or -not $job.Contains('steps')) { continue }

                        foreach ($step in @($job['steps'])) {
                            if (-not ($step -is [System.Collections.IDictionary]) -or -not $step.Contains('uses')) { continue }
                            if ($step['uses'] -notlike 'actions/upload-artifact*') { continue }

                            [pscustomobject] @{
                                Workflow  = $file.Name
                                Step      = [string] $step['name']
                                Tolerated = $step.Contains('continue-on-error') -and [bool] $step['continue-on-error']
                            }
                        }
                    }
                }
            })
    }

    It 'finds the upload steps at all, so the sweep below cannot pass by finding none' -Skip:$script:HDTYamlMissing {
        # ci.yml uploads the NUnit results; coverage.yml the JaCoCo report and
        # its own results; e2e.yml the results and the deployment diagnostics.
        @($script:uploadStep).Count | Should -BeGreaterThan 4
    }

    It 'never lets a refused upload decide the run' -Skip:$script:HDTYamlMissing {
        $offender = @($script:uploadStep |
                Where-Object { -not $_.Tolerated } |
                ForEach-Object { '{0} / {1}' -f $_.Workflow, $_.Step })

        $offender -join '; ' | Should -BeExactly '' -Because (
            'an upload-artifact step without continue-on-error hands GitHub artifact storage a veto over ' +
            'the gate. Run 34250900149 passed every check and reported failure on a 403 while finalising')
    }
}
