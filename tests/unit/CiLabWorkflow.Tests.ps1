# THE GATE, ON THE MACHINE THAT IS NOT A HOSTED RUNNER - AND THE BADGES, WHICH
# HAD TO LEAVE IT.
#
# ci-lab.yml runs ./build.ps1 -Task ci on GHRUNNER01, the same self-hosted
# runner e2e.yml uses, because a hosted runner proves the suite passes on a
# clean container and says nothing about whether it passes on a Windows install
# that has been used. It is a SEPARATE FILE from ci.yml for the reason e2e.yml's
# header spells out: on `pull_request` GitHub runs the workflow file from the
# PR HEAD, so an `if:` guard written inside a fork-editable file is guarding a
# file the attacker controls. A file with no pull_request trigger at all cannot
# be reached that way whatever anybody writes inside it.
#
# THE SELF-HOSTED RULES ARE NOT REPEATED HERE. E2eWorkflow.Tests.ps1 asserts
# them over the SET of workflow files - no fork-reachable trigger, no
# contents: write, an owner guard, no schedule - so ci-lab.yml is judged by
# them the moment it exists, which is the point of having written them that
# way. What is here is what those cannot see: that this file is the CI gate
# rather than the e2e suite, that its self-hosted side is ONE job, and that its
# dependency check is still the same one e2e.yml uses rather than a drifted
# copy.
#
# AND THE BADGES BRANCH, WHICH NOW HAS MORE THAN ONE POSSIBLE WRITER. ci.yml
# pushed it on every push to main and coverage.yml pushes it nightly, with two
# verbatim copies of the same forty-line script, no rebase and no retry in
# either - so a nightly coverage run overlapping a push already turned a green
# build red, and nobody had noticed because the clocks rarely met. The push is
# one composite action now and every job that calls it shares a concurrency
# group, asserted below over the set rather than per file.
#
# YAML 1.1 gotcha, same as the other two workflow suites: ConvertFrom-Yaml turns
# the GitHub Actions 'on:' key into the BOOLEAN $true. Trigger assertions are
# made against the raw file text.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
$script:HDTYamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')

Describe 'CI-Lab workflow' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

        $script:workflowPath = Join-Path -Path $script:repoRoot -ChildPath '.github/workflows/ci-lab.yml'

        $script:workflowText = ''
        if (Test-Path -Path $script:workflowPath -PathType Leaf) {
            $script:workflowText = Get-Content -Path $script:workflowPath -Raw
        }

        $script:workflow = $null
        if ($script:workflowText -and (Test-HDTModuleAvailable -Name 'powershell-yaml')) {
            $script:workflow = ConvertFrom-Yaml $script:workflowText
        }

        $script:selfHostedJob = @()
        if ($script:workflow -and $script:workflow.Contains('jobs')) {
            $script:selfHostedJob = @(
                foreach ($name in @($script:workflow['jobs'].Keys)) {
                    $candidate = $script:workflow['jobs'][$name]
                    if (-not ($candidate -is [System.Collections.IDictionary])) { continue }
                    if ((@($candidate['runs-on']) -join ' ') -match 'self-hosted') {
                        [pscustomobject] @{ Name = [string] $name; Job = $candidate }
                    }
                })
        }
    }

    It 'exists at .github/workflows/ci-lab.yml' {
        Test-Path -Path $script:workflowPath -PathType Leaf | Should -BeTrue
    }

    It 'is valid YAML' -Skip:$script:HDTYamlMissing {
        $script:workflowText | Should -Not -BeNullOrEmpty
        { ConvertFrom-Yaml $script:workflowText } | Should -Not -Throw
        $script:workflow | Should -Not -BeNullOrEmpty
    }

    It 'is named so a workflow_run trigger can find it' -Skip:$script:HDTYamlMissing {
        # badges.yml fires on `workflow_run: workflows: [CI-Lab]`, and that key
        # matches the `name:` in this file - not the filename. Rename this and
        # the badges silently stop updating, with no failing run anywhere to
        # say so, because a workflow_run naming a workflow that does not exist
        # simply never fires.
        [string] $script:workflow['name'] | Should -BeExactly 'CI-Lab'
    }

    It 'runs the gate on the lab runner, by label' -Skip:$script:HDTYamlMissing {
        # LABELS, NOT A NAME, for the reason e2e.yml gives: the runner is
        # replaced when the lab host is rebuilt and the new one will not be
        # called what the old one was.
        #
        # hdt-ci, NOT hyperv-nested. This is a SECOND runner instance on the
        # same machine, and the labels are what keep the two apart: the gate
        # must not queue behind a six-hour deployment run, and a deployment run
        # must not queue behind the gate.
        @($script:selfHostedJob).Count | Should -Be 1

        $labels = @($script:selfHostedJob[0].Job['runs-on'])
        $labels | Should -Contain 'self-hosted'
        $labels | Should -Contain 'windows'
        $labels | Should -Contain 'hdt-ci'
    }

    It 'keeps the self-hosted side to a single job' -Skip:$script:HDTYamlMissing {
        # TWO CONSECUTIVE SELF-HOSTED JOBS LEAVE A WINDOW WITH NO
        # Runner.Worker.exe IN THE GUEST, and MS-A2's hourly checkpoint revert
        # skips only while that process exists (PROJECT.md, "GHRUNNER01"). A
        # revert landing in the gap between two jobs takes the workspace the
        # second one was about to use, and what it looks like from here is a
        # checkout that vanished mid-run.
        #
        # So: one job on the lab machine. The owner guard is a job too, and it
        # is HOSTED - which is the whole reason it can be a separate job at all.
        @($script:selfHostedJob).Count | Should -Be 1 -Because (
            'a second self-hosted job opens a gap between workers, and the hourly checkpoint revert can land in it')
    }

    It 'runs every step under Windows PowerShell 5.1' -Skip:$script:HDTYamlMissing {
        # The engine runs in WinPE, which has no pwsh. `shell: powershell` on
        # Windows IS 5.1.
        $script:selfHostedJob[0].Job['defaults']['run']['shell'] | Should -BeExactly 'powershell'
    }

    It 'invokes ./build.ps1 with the ci task' {
        # THE SAME ENTRY POINT DEVELOPERS RUN (DESIGN 12.2.5). CI never grows
        # its own private build logic, and this file exists to run the gate on
        # different hardware, not to run a different gate.
        $script:workflowText | Should -Match '\./build\.ps1\s+-Task\s+ci'
        $script:workflowText | Should -Not -Match '-Task\s+e2e'
    }

    It 'proves its dependencies the way the other lab workflow does' -Skip:$script:HDTYamlMissing {
        # NOT INSTALLED ON A RUNNER THAT IS REVERTED TO A CHECKPOINT, VERIFIED
        # ON IT. What can go wrong on GHRUNNER01 is the checkpoint being older
        # than the pins, and the step that reports that - by module name, by
        # pinned version, with the exact Install-Module line and the reminder
        # to retake the checkpoint - is e2e.yml's.
        #
        # THE SAME STEP, NOT A SIMILAR ONE. Two hand-maintained copies of a
        # version pin is how the two runners come to disagree about what is
        # installed, and the copy nobody looked at is the one that stops
        # checking. Asserted character for character.
        $mine = @($script:selfHostedJob[0].Job['steps'] | Where-Object {
                $_ -is [System.Collections.IDictionary] -and [string] $_['name'] -eq 'Check the build dependencies'
            })
        $mine.Count | Should -Be 1

        $e2e = ConvertFrom-Yaml (Get-Content -LiteralPath (
                Join-Path -Path $script:repoRoot -ChildPath '.github/workflows/e2e.yml') -Raw)

        $theirs = @($e2e['jobs']['e2e']['steps'] | Where-Object {
                $_ -is [System.Collections.IDictionary] -and [string] $_['name'] -eq 'Check the build dependencies'
            })
        $theirs.Count | Should -Be 1

        ([string] $mine[0]['run']).Trim() | Should -BeExactly ([string] $theirs[0]['run']).Trim() -Because (
            'the two self-hosted workflows check the same machine against the same pins; a drifted copy is ' +
            'the one that stops noticing a checkpoint older than the versions build.ps1 requires')
    }

    It 'triggers on a push to main and on demand, and on nothing else' {
        # Raw text: the 'on' key is the boolean $true after a YAML 1.1 parse.
        #
        # NO pull_request, AND NOT BECAUSE AN `if:` COULD BE WRITTEN INSTEAD.
        # On `pull_request` GitHub runs the workflow file FROM THE PR HEAD, so
        # a guard written in this file would be a guard the fork gets to edit
        # in the same commit that adds the runner label. The absence of the
        # trigger is the control; nothing written inside the file could be.
        # E2eWorkflow.Tests.ps1 asserts that over the set as well.
        $script:workflowText | Should -Match '(?m)^\s{2}push:'
        $script:workflowText | Should -Match '(?m)^\s{4}branches:\s*\[\s*main\s*\]'
        $script:workflowText | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:workflowText | Should -Not -Match '(?m)^\s{2}pull_request:'
        $script:workflowText | Should -Not -Match '(?m)^\s{2}pull_request_target:'
    }

    It 'collapses two quick pushes rather than queueing them on one machine' -Skip:$script:HDTYamlMissing {
        # THERE IS ONE OF THIS MACHINE. A hosted runner pool absorbs a burst of
        # pushes by starting a container each; GHRUNNER01 runs them one after
        # another, so three commits in five minutes is three twenty-minute runs
        # and the answer everybody wants is the last one's.
        #
        # PER REF, so main and a hand-started run on another branch do not
        # cancel each other.
        $concurrency = $script:workflow['concurrency']
        $concurrency | Should -Not -BeNullOrEmpty
        [string] $concurrency['group'] | Should -Match 'github\.ref'
        [bool] $concurrency['cancel-in-progress'] | Should -BeTrue
    }

    It 'is given a deadline rather than left burning' -Skip:$script:HDTYamlMissing {
        # The suite is ~10 minutes on a developer machine and ~20 on a hosted
        # runner. GitHub's default is 360, and six hours of a machine there is
        # exactly one of is six hours nothing else can be tested on.
        $script:selfHostedJob[0].Job['timeout-minutes'] | Should -BeGreaterThan 20
        $script:selfHostedJob[0].Job['timeout-minutes'] | Should -BeLessThan 120
    }

    It 'hands the badges to the workflow that publishes them' -Skip:$script:HDTYamlMissing {
        # THIS JOB MUST NOT PUSH THEM ITSELF, and the reason is the token: a
        # self-hosted job may not hold contents: write (asserted over the set in
        # E2eWorkflow.Tests.ps1), because a writable GITHUB_TOKEN on a machine
        # somebody owns is what turns a compromised job into a compromised
        # repository. So it uploads the numbers and badges.yml, on GitHub's own
        # hardware, does the write.
        $upload = @($script:selfHostedJob[0].Job['steps'] | Where-Object {
                $_ -is [System.Collections.IDictionary] -and
                $_.Contains('uses') -and ([string] $_['uses']) -like 'actions/upload-artifact*'
            })

        $badges = @($upload | Where-Object { [string] $_['with']['name'] -eq 'badges' })
        $badges.Count | Should -Be 1
        [string] $badges[0]['with']['path'] | Should -Match 'out/badges'
        [string] $badges[0]['if'] | Should -Match 'always\(\)'
    }
}

# ---------------------------------------------------------------------------

Describe 'Badges workflow' {

    BeforeAll {
        $script:badgeRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:badgePath = Join-Path -Path $script:badgeRoot -ChildPath '.github/workflows/badges.yml'

        $script:badgeText = ''
        if (Test-Path -Path $script:badgePath -PathType Leaf) {
            $script:badgeText = Get-Content -Path $script:badgePath -Raw
        }

        $script:badgeWorkflow = $null
        if ($script:badgeText -and (Test-HDTModuleAvailable -Name 'powershell-yaml')) {
            $script:badgeWorkflow = ConvertFrom-Yaml $script:badgeText
        }
    }

    It 'exists at .github/workflows/badges.yml' {
        Test-Path -Path $script:badgePath -PathType Leaf | Should -BeTrue
    }

    It 'is valid YAML' -Skip:$script:HDTYamlMissing {
        { ConvertFrom-Yaml $script:badgeText } | Should -Not -Throw
        $script:badgeWorkflow | Should -Not -BeNullOrEmpty
    }

    It 'fires on the gate finishing, and on nothing a fork can pull' {
        # workflow_run RUNS THE DEFAULT BRANCH'S COPY OF THIS FILE, whatever the
        # producing run was. That is the property that makes it safe to hold a
        # writable token here: a pull request cannot edit the file that does the
        # write, the way it could if this were a job inside a fork-triggered
        # workflow.
        $script:badgeText | Should -Match '(?m)^\s{2}workflow_run:'
        $script:badgeText | Should -Match 'CI-Lab'
        $script:badgeText | Should -Not -Match '(?m)^\s{2}pull_request:'
        $script:badgeText | Should -Not -Match '(?m)^\s{2}pull_request_target:'
    }

    It 'runs on GitHub hardware, not on the lab machine' {
        # The write lives here BECAUSE it cannot live there.
        $script:badgeText | Should -Not -Match '(?m)^\s*runs-on:.*self-hosted'
    }

    It 'takes the numbers from the run that produced them' -Skip:$script:HDTYamlMissing {
        # NOT FROM A FRESH BUILD OF ITS OWN. A badge that says what a second,
        # later build found is a badge for a commit nobody asked about, and it
        # would be measured on a different machine from the one whose result is
        # being reported.
        $script:badgeText | Should -Match 'actions/download-artifact'
        $script:badgeText | Should -Match 'github\.event\.workflow_run\.id'
    }

    It 'publishes only what main produced' {
        # A hand-started CI-Lab run on a branch still produces badges. The
        # branch's numbers are not what the README is reporting.
        $script:badgeText | Should -Match "head_branch == 'main'"
    }

    It 'asks for the write, and for reading the producing run, and nothing else' -Skip:$script:HDTYamlMissing {
        # contents: write for the branch; actions: read because
        # download-artifact reaching into ANOTHER run needs it. Anything beyond
        # those two is a scope this file has no use for.
        $permission = $script:badgeWorkflow['permissions']
        $permission | Should -Not -BeNullOrEmpty
        [string] $permission['contents'] | Should -BeExactly 'write'
        [string] $permission['actions'] | Should -BeExactly 'read'
        (@($permission.Keys) | Sort-Object) -join ',' | Should -BeExactly 'actions,contents'
    }
}

# ---------------------------------------------------------------------------

Describe 'The badges branch has one writer at a time' {

    # ASSERTED OVER THE SET, BECAUSE THE RACE IS BETWEEN FILES AND NOT INSIDE
    # ONE. Two workflows push the same branch on two different clocks, the push
    # has no rebase and no retry, and the loser fails - so a nightly coverage
    # run overlapping a push to main turns a green build red for a reason that
    # is nowhere in its own log. Adding a third writer without a concurrency
    # group is the same defect again, and this is what has to catch it.

    BeforeAll {
        $script:setRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:setRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

        $script:setFile = @(Get-ChildItem `
                -LiteralPath (Join-Path -Path $script:setRoot -ChildPath '.github/workflows') `
                -Filter '*.yml' -File)

        $script:badgeWriter = @(
            if (Test-HDTModuleAvailable -Name 'powershell-yaml') {
                foreach ($file in $script:setFile) {
                    $document = ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw)
                    if (-not ($document -is [System.Collections.IDictionary])) { continue }
                    if (-not $document.Contains('jobs')) { continue }

                    $workflowConcurrency = $null
                    if ($document.Contains('concurrency')) { $workflowConcurrency = $document['concurrency'] }

                    foreach ($jobName in @($document['jobs'].Keys)) {
                        $job = $document['jobs'][$jobName]
                        if (-not ($job -is [System.Collections.IDictionary])) { continue }
                        if (-not $job.Contains('steps')) { continue }

                        $publishes = @($job['steps'] | Where-Object {
                                $_ -is [System.Collections.IDictionary] -and
                                $_.Contains('uses') -and
                                ([string] $_['uses']) -like '*actions/publish-badges*'
                            })
                        if ($publishes.Count -eq 0) { continue }

                        # A JOB-LEVEL GROUP OVERRIDES THE WORKFLOW-LEVEL ONE,
                        # which is how coverage.yml can hold the badges group
                        # for the length of a push rather than for the four
                        # hours its measurement takes.
                        $concurrency = $workflowConcurrency
                        if ($job.Contains('concurrency')) { $concurrency = $job['concurrency'] }

                        [pscustomobject] @{
                            Workflow = $file.Name
                            Job      = [string] $jobName
                            Group    = $(if ($concurrency -is [System.Collections.IDictionary]) {
                                    [string] $concurrency['group']
                                } else { [string] $concurrency })
                            Cancels  = $(if ($concurrency -is [System.Collections.IDictionary]) {
                                    [bool] $concurrency['cancel-in-progress']
                                } else { $false })
                        }
                    }
                }
            })
    }

    It 'finds the badge publishers at all, so the sweep below cannot pass by finding none' -Skip:$script:HDTYamlMissing {
        # badges.yml after a CI-Lab run, and coverage.yml nightly. If this drops
        # to one the rule below is asserting nothing, which is the shape of
        # failure the whole file is written against.
        @($script:badgeWriter).Count | Should -BeGreaterOrEqual 2
    }

    It 'gives every badge publisher the same concurrency group' -Skip:$script:HDTYamlMissing {
        $offender = @($script:badgeWriter |
                Where-Object { $_.Group -ne 'badges' } |
                ForEach-Object { '{0} / {1} (group: {2})' -f $_.Workflow, $_.Job, $(if ($_.Group) { $_.Group } else { 'none' }) })

        $offender -join '; ' | Should -BeExactly '' -Because (
            'the badge push has no rebase and no retry, so two writers racing means one of them fails ' +
            'and a green build reports red. A shared concurrency group is what makes them queue instead')
    }

    It 'never cancels a badge push already in flight' -Skip:$script:HDTYamlMissing {
        # cancel-in-progress ON THIS GROUP WOULD BE THE RACE AGAIN WEARING A
        # DIFFERENT HAT: a coverage push killed halfway leaves the branch with
        # a tests badge from one run and a coverage badge from another, and
        # nothing would ever say so. Queueing is the whole point.
        $offender = @($script:badgeWriter |
                Where-Object { $_.Cancels } |
                ForEach-Object { '{0} / {1}' -f $_.Workflow, $_.Job })

        $offender -join '; ' | Should -BeExactly ''
    }

    It 'writes the push in exactly one place' {
        # RULE 8. This was forty lines of PowerShell copied verbatim into
        # ci.yml and coverage.yml, and the copies had already begun to diverge
        # in their comments. A workflow that pushes the branch with its own
        # inline git is a second source of truth AND is invisible to the
        # concurrency sweep above, which looks for the action.
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        Test-Path -LiteralPath (Join-Path -Path $root -ChildPath '.github/actions/publish-badges/action.yml') -PathType Leaf |
            Should -BeTrue

        $inline = @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath '.github/workflows') -Filter '*.yml' -File |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'push\s+(--quiet\s+)?origin\s+badges' } |
                ForEach-Object { $_.Name })

        $inline -join ', ' | Should -BeExactly '' -Because (
            'the badge push lives in .github/actions/publish-badges; a workflow with its own copy is the ' +
            'one still green after somebody fixes the other')
    }
}
