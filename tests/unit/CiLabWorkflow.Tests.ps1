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

        $script:workflowPath = Join-Path -Path $script:repoRoot -ChildPath '.github/workflows/lab.yml'

        $script:workflowText = ''
        if (Test-Path -Path $script:workflowPath -PathType Leaf) {
            $script:workflowText = Get-Content -Path $script:workflowPath -Raw
        }

        $script:workflow = $null
        if ($script:workflowText -and (Test-HDTModuleAvailable -Name 'powershell-yaml')) {
            $script:workflow = ConvertFrom-Yaml $script:workflowText
        }

        # THE HOSTED JOB THAT DECIDES WHETHER THE LAB IS WORTH STARTING, AND
        # THE LAB JOB THAT READS IT. Held by name because the wiring between
        # the two - an output on one, an `if:` on the other - is the whole
        # mechanism, and a rename that broke it would otherwise look like a job
        # that had simply stopped running.
        $script:decisionJob = $null
        $script:labJob = $null
        if ($script:workflow -and $script:workflow.Contains('jobs')) {
            if ($script:workflow['jobs'].Contains('changes')) { $script:decisionJob = $script:workflow['jobs']['changes'] }
            if ($script:workflow['jobs'].Contains('lab')) { $script:labJob = $script:workflow['jobs']['lab'] }
        }

        $script:decisionScript = ''
        if ($script:decisionJob -and $script:decisionJob.Contains('steps')) {
            $script:decisionScript = (@($script:decisionJob['steps'] |
                    Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('run') } |
                    ForEach-Object { [string] $_['run'] }) -join "`n")
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

    It 'exists at .github/workflows/lab.yml' {
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
        # BY NAME, NOT BY INDEX. This file now holds two self-hosted jobs - the
        # gate and the end-to-end suite - and the labels are exactly what keeps
        # them on different runner instances, so picking [0] would assert the
        # gate's labels against whichever job the parser happened to see first.
        $gate = @($script:selfHostedJob | Where-Object { $_.Name -eq 'lab' })
        $gate.Count | Should -Be 1 -Because 'the gate is the job labelled hdt-ci'

        $labels = @($gate[0].Job['runs-on'])
        $labels | Should -Contain 'self-hosted'
        $labels | Should -Contain 'windows'
        $labels | Should -Contain 'hdt-ci'
    }

    It 'never runs one self-hosted job after another' -Skip:$script:HDTYamlMissing {
        # TWO CONSECUTIVE SELF-HOSTED JOBS LEAVE A WINDOW WITH NO
        # Runner.Worker.exe IN THE GUEST, and MS-A2's hourly checkpoint revert
        # skips only while that process exists (PROJECT.md, "GHRUNNER01"). A
        # revert landing in the gap between two jobs takes the workspace the
        # second one was about to use, and what it looks like from here is a
        # checkout that vanished mid-run.
        #
        # THE DANGER IS THE SEQUENCE, NOT THE COUNT. This asserted a single
        # self-hosted job, which is how the property expressed itself while the
        # gate and the end-to-end suite lived in separate files. In one file
        # there are two - so what has to be stated is that they are never
        # CHAINED: no self-hosted job may wait on another, because the wait is
        # the gap.
        #
        # Running side by side is safe and is what a workflow_dispatch does: a
        # worker stays alive throughout, so the revert never sees its opening.
        # The triggers keep them apart otherwise - a push runs the gate, a tag
        # runs the suite, because publish.yml has already gated on hosted
        # hardware by then.
        $selfHosted = @($script:selfHostedJob | ForEach-Object { $_.Name })

        $selfHosted.Count | Should -BeGreaterThan 0 -Because 'finding none would pass this by measuring nothing'

        $chained = @($selfHosted | Where-Object {
                $job = $script:workflow['jobs'][$_]
                $needs = @()
                if ($job.Contains('needs')) { $needs = @($job['needs']) }

                @($needs | Where-Object { $selfHosted -contains $_ }).Count -gt 0
            })

        $chained | Should -BeNullOrEmpty -Because (
            'these wait on another self-hosted job, so a checkpoint revert can land in the gap: {0}' -f
                ($chained -join ', '))
    }

    It 'runs every step under Windows PowerShell 5.1' -Skip:$script:HDTYamlMissing {
        # The engine runs in WinPE, which has no pwsh. `shell: powershell` on
        # Windows IS 5.1.
        foreach ($entry in @($script:selfHostedJob)) {
            $entry.Job['defaults']['run']['shell'] | Should -BeExactly 'powershell' -Because (
                "job '$($entry.Name)' runs on the lab machine and the engine's floor is Windows PowerShell 5.1")
        }
    }

    It 'invokes ./build.ps1 with the ci task' {
        # THE SAME ENTRY POINT DEVELOPERS RUN (DESIGN 12.2.5). CI never grows
        # its own private build logic, and this file exists to run the gate on
        # different hardware, not to run a different gate.
        # THE GATE JOB RUNS -Task ci. The end-to-end job in this same file runs
        # -Task e2e, which is its whole purpose - so the exclusion that used to
        # police a file with one job is now stated per job.
        $script:workflowText | Should -Match '\./build\.ps1\s+-Task\s+ci'

        $gate = @($script:selfHostedJob | Where-Object { $_.Name -eq 'lab' })
        $gateRun = (@($gate[0].Job['steps'] | ForEach-Object { [string] $_['run'] }) -join "`n")

        $gateRun | Should -Match '\./build\.ps1\s+-Task\s+ci'
        $gateRun | Should -Not -Match '-Task\s+e2e'
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
                Join-Path -Path $script:repoRoot -ChildPath '.github/workflows/lab.yml') -Raw)

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
        # THE GATE'S DEADLINE IS A NUMBER; the end-to-end job's is whatever the
        # caller passed, so it reads as an expression here and its bounds are
        # asserted where that input is declared.
        $gate = @($script:selfHostedJob | Where-Object { $_.Name -eq 'lab' })

        $gate[0].Job['timeout-minutes'] | Should -BeGreaterThan 20
        $gate[0].Job['timeout-minutes'] | Should -BeLessThan 120

        # EVERY self-hosted job still has to have one - a job with no deadline
        # holds the machine until GitHub's six-hour ceiling.
        foreach ($entry in @($script:selfHostedJob)) {
            [string] $entry.Job['timeout-minutes'] | Should -Not -BeNullOrEmpty -Because (
                "job '$($entry.Name)' would run to the platform ceiling")
        }
    }

    It 'asks whether the lab is worth starting before any of it reaches the lab machine' -Skip:$script:HDTYamlMissing {
        # ~9 MINUTES OF A MACHINE THERE IS EXACTLY ONE OF, AND IT IS REVERTED
        # TO A CHECKPOINT EVERY HOUR. Spending that on a README edit is not a
        # cautious gate; it is a queue nothing useful can get into.
        #
        # HOSTED, AND THAT IS THE POINT RATHER THAN A DETAIL. A check that ran
        # on GHRUNNER01 would have checked out onto it, started a worker and
        # taken the slot it was deciding whether to take. The decision has to
        # be made somewhere the answer is free.
        $script:decisionJob | Should -Not -BeNullOrEmpty -Because (
            'ci-lab.yml needs a hosted job that decides whether the lab machine is worth starting')

        [string] @($script:decisionJob['runs-on']) | Should -Not -Match 'self-hosted' -Because (
            'a check that runs on the machine it is deciding about has already spent the thing it was saving')

        # THE DECISION IS A HOSTED JOB, so it adds nothing to the lab machine -
        # which is what the case above, about the hourly checkpoint revert
        # landing in the gap between two workers, is actually about. Asserted
        # as "no self-hosted job waits on another" by the test of that name
        # rather than as a count here, now that the end-to-end suite shares
        # this file.
        @($script:selfHostedJob | Where-Object { $_.Name -eq 'changes' }) | Should -BeNullOrEmpty -Because (
            'the decision must never be made on the machine it is deciding about')
    }

    It 'makes that decision behind the owner guard, not in front of it' -Skip:$script:HDTYamlMissing {
        # THE GUARD FAILS, THIS ONE SKIPS, AND THE ORDER DECIDES WHICH OF THOSE
        # GETS REPORTED. A run started by somebody who is not the owner must
        # say exactly that - not report a version that did not move.
        @($script:decisionJob['needs']) | Should -Contain 'guard'
    }

    It 'lets the lab job read the decision rather than make it' -Skip:$script:HDTYamlMissing {
        # A JOB OUTPUT, AND AN `if:` ON THE LAB JOB ITSELF. Skipping is the
        # CORRECT behaviour here, which is exactly why it is not how the owner
        # guard is written: a refusal that skips reports success, and for
        # "nobody needs the lab machine for this commit" success is the honest
        # answer rather than a hidden one.
        @($script:labJob['needs']) | Should -Contain 'guard'
        @($script:labJob['needs']) | Should -Contain 'changes'

        [string] $script:labJob['if'] | Should -Match 'needs\.changes\.outputs\.run' -Because (
            'the lab job is the one that has to be skipped; a condition anywhere else still starts a worker on GHRUNNER01')

        [string] $script:decisionJob['outputs']['run'] | Should -Match 'steps\.[A-Za-z0-9_-]+\.outputs\.run' -Because (
            'an output wired to no step is the empty string, and the empty string is not ''true'' - the lab would never run again')
    }

    It 'names the version as the condition, and reads it where it is recorded' -Skip:$script:HDTYamlMissing {
        # THE RULE AS ASKED FOR, AND IT IS THE FIRST CLAUSE. A commit that
        # moves ModuleVersion is a release-shaped commit and the lab runs for
        # it whatever else it did or did not touch.
        $script:decisionScript | Should -Match 'ModuleVersion'
        $script:decisionScript | Should -Match 'Hephaestus\.psd1' -Because (
            'the version has to be read out of the manifest at both revisions; nothing else records it')
    }

    It 'runs the lab for source the version task was never allowed to record' -Skip:$script:HDTYamlMissing {
        # WHY THE VERSION ALONE IS NOT ENOUGH, IN ONE NUMBER: ModuleVersion has
        # moved on 34 of this repository's 941 commits, and on 2 of the last
        # 40. ./build.ps1 -Task ci bumps it on every run and the bump is
        # reverted before every commit, so on main the number moves on a
        # deliberate release and almost nowhere else.
        #
        # A version-only gate would therefore run the lab on releases and skip
        # everything between them. That is not "a docs commit does not spend
        # the lab machine", it is "main is unvalidated except at a release" -
        # and ci.yml no longer carries a `push:` to cover for it.
        #
        # SO THE DEFAULT IS TO RUN AND THE SKIP IS THE SPECIAL CASE. A path
        # nobody thought about when this was written - a new top-level
        # directory, a new tool the build calls - starts the lab, because the
        # failure that costs something is a change going unvalidated, not a
        # machine running for nine minutes it did not have to.
        #
        # SO: THE PATHS ARE COMPARED AT ALL, AND THE COMPARISON CAN SAY RUN.
        # A version-only gate would have no `git diff` in it, which is exactly
        # what this case is here to notice if somebody reduces it to one.
        $script:decisionScript | Should -Match 'GITHUB_OUTPUT' -Because (
            'the decision has to leave the job as an output; a run= nobody writes is an empty string')
        $script:decisionScript | Should -Match '(?s)git diff --name-only.{0,1200}decide true' -Because (
            'the second clause is the one that keeps main validated between releases')
    }

    It 'lets no document or workflow edit spend the lab machine' -Skip:$script:HDTYamlMissing {
        # ASSERTED OVER THE SET RATHER THAN OVER THE ONE THAT PROMPTED IT. The
        # request was "a README change must not trigger a LAB build", and a
        # test naming only README.md would pass for it and fail nobody after
        # it - not the next docs/ page, not the next .planning/ report, not the
        # next edit to this very workflow.
        #
        # WHAT THIS COSTS, AND WHY IT IS ACCEPTED: a docs-only commit that
        # breaks a documentation contract test is not caught within the nine
        # minutes. It is caught by ci.yml, which still runs on every pull
        # request and every Monday.
        foreach ($inert in 'docs/', '\.planning/', '\.github/', 'README\.md') {
            $script:decisionScript | Should -Match $inert -Because (
                "'$inert' is one of the trees that must not start the lab machine on its own")
        }

        # AND THE OTHER HALF OF THE SET: none of the trees the gate actually
        # reads may appear in the skip list. This is the case that fails the
        # day somebody widens the skip to quieten a noisy run.
        $inertLine = @($script:decisionScript -split "`n" | Where-Object { $_ -match '^\s*inert=' }) -join ' '
        $inertLine | Should -Not -BeNullOrEmpty -Because (
            'the skip list has to be one greppable line, or this case is reading nothing')

        foreach ($read in 'src/', 'tests/', 'schemas/', 'build\.ps1') {
            $inertLine | Should -Not -Match $read -Because (
                "the gate reads '$read'; a change there has to reach GHRUNNER01")
        }
    }

    It 'always runs the lab when a human started the run' -Skip:$script:HDTYamlMissing {
        # A workflow_dispatch IS A DELIBERATE ACT. Somebody pressed the button
        # BECAUSE they want this commit on that machine - most often after the
        # checkpoint was retaken, which is precisely the moment when nothing
        # about the last push has changed and a version comparison would skip.
        #
        # ASSERTED AS "THE EVENT IS TESTED BEFORE ANYTHING ELSE IS": the event
        # check has to come before the version comparison, or a dispatch of a
        # commit whose version has not moved skips the very run somebody just
        # asked for.
        $script:decisionScript | Should -Match 'HDT_EVENT'
        $script:decisionScript | Should -Match "(?s)HDT_EVENT.{0,600}decide true"
        ($script:decisionScript -split 'ModuleVersion moved')[0] | Should -Match 'HDT_EVENT.*!=.*push' -Because (
            'the dispatch case has to be settled before the version is looked at, not after it')
    }

    It 'compares against the whole push rather than against its last commit' -Skip:$script:HDTYamlMissing {
        # A PUSH IS NOT ONE COMMIT. Source in the first commit and a README fix
        # in the second, pushed together, and a HEAD~1 comparison sees only the
        # README - the exact change this is meant to protect, skipped by the
        # thing meant to protect it. github.event.before is the tip before the
        # push, which is the range GitHub actually delivered.
        #
        # AND THE HISTORY HAS TO BE THERE TO COMPARE AGAINST: the default
        # checkout is one commit deep and `git diff` against anything older
        # than it fails.
        $checkout = @($script:decisionJob['steps'] | Where-Object {
                $_ -is [System.Collections.IDictionary] -and $_.Contains('uses') -and
                ([string] $_['uses']) -like 'actions/checkout*'
            })
        $checkout.Count | Should -Be 1
        [string] $checkout[0]['with']['fetch-depth'] | Should -BeExactly '0'

        $script:decisionScript | Should -Match 'HDT_BEFORE'
        $script:decisionScript | Should -Not -Match 'HEAD~1|HEAD\^\.'
    }

    It 'runs the lab whenever it cannot tell, rather than skipping it' -Skip:$script:HDTYamlMissing {
        # THE FIRST PUSH TO A BRANCH, A FORCE PUSH THAT ORPHANED THE OLD TIP, A
        # `before` OF FORTY ZEROES. In each of those there is no honest
        # comparison to make, and the safe answer to "I cannot tell" is nine
        # minutes of a machine rather than a commit nothing ever checked.
        $script:decisionScript | Should -Match '0000000000000000000000000000000000000000'
        $script:decisionScript | Should -Match 'cat-file'
    }

    It 'hands the badges to the workflow that publishes them' -Skip:$script:HDTYamlMissing {
        # THIS JOB MUST NOT PUSH THEM ITSELF, and the reason is the token: a
        # self-hosted job may not hold contents: write (asserted over the set in
        # E2eWorkflow.Tests.ps1), because a writable GITHUB_TOKEN on a machine
        # somebody owns is what turns a compromised job into a compromised
        # repository. So it uploads the numbers and badges.yml, on GitHub's own
        # hardware, does the write.
        $gate = @($script:selfHostedJob | Where-Object { $_.Name -eq 'lab' })

        $upload = @($gate[0].Job['steps'] | Where-Object {
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
        $script:badgePath = Join-Path -Path $script:badgeRoot -ChildPath '.github/workflows/lab.yml'

        $script:badgeText = ''
        if (Test-Path -Path $script:badgePath -PathType Leaf) {
            $script:badgeText = Get-Content -Path $script:badgePath -Raw
        }

        $script:badgeWorkflow = $null
        if ($script:badgeText -and (Test-HDTModuleAvailable -Name 'powershell-yaml')) {
            $script:badgeWorkflow = ConvertFrom-Yaml $script:badgeText
        }
    }

    It 'exists at .github/workflows/lab.yml' {
        Test-Path -Path $script:badgePath -PathType Leaf | Should -BeTrue
    }

    It 'is valid YAML' -Skip:$script:HDTYamlMissing {
        { ConvertFrom-Yaml $script:badgeText } | Should -Not -Throw
        $script:badgeWorkflow | Should -Not -BeNullOrEmpty
    }

    # ======================================================================
    # THE BADGES ARE A JOB NOW, AND EVERY PROPERTY BELOW MOVED WITH THEM.
    #
    # badges.yml fired on `workflow_run` so GitHub would run the DEFAULT
    # BRANCH's copy - the only way to hold contents: write in a world where the
    # file might be fork-editable. In a file with NO fork-reachable trigger that
    # indirection buys nothing, so the job sits beside the run that produced the
    # numbers and reads them from it directly.
    #
    # WHAT DID NOT MOVE IS THE RULE: the write is on this job and on no other,
    # and this job does not run on the lab machine.
    # ======================================================================
    It 'is a job, and only it may write' -Skip:$script:HDTYamlMissing {
        $badgeJob = $script:badgeWorkflow['jobs']['badges']
        $badgeJob | Should -Not -BeNullOrEmpty

        [string] $badgeJob['permissions']['contents'] | Should -BeExactly 'write'

        # Every OTHER job must not - most of all the self-hosted ones. A
        # writable token on a machine somebody owns is what turns a compromised
        # job into a compromised repository.
        foreach ($name in @($script:badgeWorkflow['jobs'].Keys | Where-Object { $_ -ne 'badges' })) {
            $other = $script:badgeWorkflow['jobs'][$name]

            if ($other.Contains('permissions')) {
                [string] $other['permissions']['contents'] | Should -Not -Be 'write' -Because (
                    "job '$name' would hold a writable token")
            }
        }

        [string] $script:badgeWorkflow['permissions']['contents'] | Should -BeExactly 'read' -Because (
            'the workflow default has to be read, or a job that states nothing inherits a write'
        )
    }

    It 'runs on GitHub hardware, not on the lab machine' -Skip:$script:HDTYamlMissing {
        $badgeJob = $script:badgeWorkflow['jobs']['badges']

        ([string] ($badgeJob['runs-on'] -join ' ')) | Should -Not -Match 'self-hosted'
    }

    It 'takes the numbers from the run that produced them' -Skip:$script:HDTYamlMissing {
        # SAME RUN, so no run-id and no actions: read - that was only needed
        # while the job lived in another workflow.
        $badgeJob = $script:badgeWorkflow['jobs']['badges']

        $download = @($badgeJob['steps'] | Where-Object {
                $_ -is [System.Collections.IDictionary] -and
                $_.Contains('uses') -and ([string] $_['uses']) -like 'actions/download-artifact*'
            })

        $download.Count | Should -Be 1
        [string] $download[0]['with']['name'] | Should -BeExactly 'badges'
    }

    It 'publishes only what main produced' -Skip:$script:HDTYamlMissing {
        $badgeJob = $script:badgeWorkflow['jobs']['badges']

        [string] $badgeJob['if'] | Should -Match "refs/heads/main"
    }

    It 'carries no fork-reachable trigger, which is what lets it hold the write' -Skip:$script:HDTYamlMissing {
        # THE WHOLE REASON THIS IS SAFE IN A SHARED FILE. badges.yml used
        # workflow_run to be certain a pull request could not rewrite it; here
        # the same certainty comes from the file having no pull_request trigger
        # at all - and that is asserted over the SET in E2eWorkflow.Tests.ps1
        # as well, so it is judged even if this file is deleted.
        @($script:badgeWorkflow['on'].Keys) | Should -Not -Contain 'pull_request'
        @($script:badgeWorkflow['on'].Keys) | Should -Not -Contain 'pull_request_target'
    }
}


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
        # ONE, AND THAT IS THE POINT OF THE CONSOLIDATION. There used to be two
        # verbatim copies of this push - ci.yml's and coverage.yml's - which is
        # why this asked for two and why the concurrency group below had to be
        # asserted over a set. There is one publisher now; the sweep still runs
        # over every workflow so a second one added later is judged by it.
        @($script:badgeWriter).Count | Should -BeGreaterOrEqual 1
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
