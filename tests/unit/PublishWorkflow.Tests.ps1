# PUBLISHING IS NOT A BUILD STEP. A version on the PowerShell Gallery cannot be
# replaced and cannot really be withdrawn - Unlist hides it from search and
# leaves it installable by exact version for ever. So the one thing this
# workflow must not do is run by itself.
#
# TWO HALVES, AND ONLY ONE OF THEM IS AUTOMATIC:
#
#   the check    every CI run proves the module WOULD publish - the manifest
#                loads, the version parses, the fields the Gallery shows are
#                filled in. Free, and it fails on the pull request that broke
#                it rather than on the day somebody tries to ship.
#
#   the publish  a tag, or a human pressing Run workflow. Never a push to main.
#
# THE KEY IS A SECRET AND THE JOB SAYS SO WHEN IT IS MISSING. A publish that
# fails inside Publish-Module reports a NuGet error about an anonymous request;
# one that checks first says "PSGALLERY_API_KEY is not set on this repository".

# AT FILE SCOPE, NOT IN BeforeAll: -Skip is read while Pester is DISCOVERING
# tests, and BeforeAll has not run by then - so a flag set there is $null at the
# moment it is needed, and the whole file fails to discover. The same trap the
# string table contract hit with -ForEach.
Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
        -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

$script:yamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')

# SPIKES S9.15, FOR THE FIFTH TIME. -Skip: is bound at DISCOVERY, before any
# BeforeAll has run, so a flag set in one is `$null there - and under the
# StrictMode build.ps1 sets, reading it throws and the whole FILE is dropped.
# Pester then reports 0 failed, because nothing ran.
$script:HDTPublishRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTPublishRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
$script:yamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:publishPath = Join-Path -Path $script:repoRoot -ChildPath '.github/workflows/publish.yml'

    $script:publishText = ''
    if (Test-Path -Path $script:publishPath -PathType Leaf) {
        $script:publishText = Get-Content -Path $script:publishPath -Raw
    }


    # SET IN BOTH PHASES, BECAUSE PESTER HAS TWO AND THEY DO NOT SHARE A SCOPE.
    # The copy at file scope is what -Skip reads while tests are DISCOVERED; this
    # one is what BeforeAll and every It read while they RUN. Setting it only at
    # file scope passes a bare Invoke-Pester and fails the gate, because
    # build.ps1 sets Set-StrictMode -Version Latest and reading a variable that
    # is not there is then an error rather than $null.
    $script:yamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')

    $script:publishJob = $null
    if ($script:publishText -and -not $script:yamlMissing) {
        $script:publishJob = (ConvertFrom-Yaml $script:publishText)['jobs']['publish']
    }

    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    $script:manifest = Import-PowerShellDataFile -Path $script:manifestPath
}

Describe 'the publish workflow' {

    It 'exists at .github/workflows/publish.yml' {
        Test-Path -Path $script:publishPath -PathType Leaf | Should -BeTrue
    }

    It 'never runs on a push to a branch' {
        # THE WHOLE POINT. A Gallery version cannot be replaced, so publishing
        # must be something somebody did on purpose.
        $script:publishText | Should -Not -Match '(?m)^\s+branches:'
    }

    It 'runs on a tag and on demand' {
        $script:publishText | Should -Match '(?m)^\s+tags:'
        $script:publishText | Should -Match '(?m)^\s+workflow_dispatch:'
    }

    It 'gates on the suite before it ships anything' -Skip:$script:yamlMissing {
        # An unpublishable build is a bad day; a published broken one is worse.
        #
        # THE GATE MOVED OUT OF THE PUBLISHING JOB AND INTO ITS OWN, in front
        # of the lab. It used to be a `run: ./build.ps1 -Task
        # clean,bundle,build,lint,test,selfcheck` line in the job that
        # publishes - which meant a lint failure was discovered AFTER ninety
        # minutes of somebody's Hyper-V host and a human's approval click.
        #
        # SO THE ASSERTION IS ABOUT THE GRAPH, NOT ABOUT A STRING. What has to
        # be true is that something proved the suite and that publishing
        # depends on it. Naming a task list here is what let the old version of
        # this case pass on a COMMENT saying './build.ps1 -Task ci' while the
        # workflow had stopped running it.
        $graph = ConvertFrom-Yaml $script:publishText

        $graph['jobs'].ContainsKey('ci') | Should -BeTrue
        @($graph['jobs']['publish']['needs']) | Should -Contain 'ci'
    }

    # AND IT MUST NOT BUMP THE VERSION IT HAS JUST CHECKED. The version task
    # rewrites ModuleVersion in the manifest; running it here published 0.5.0
    # under a tag reading 0.4.0, because the step below re-reads the manifest.
    It 'runs no task that can move ModuleVersion' {
        $ran = @($script:publishText -split "`r?`n" |
                Where-Object { $_ -match '^\s*run:\s*\./build\.ps1\s+-Task\s+\S' })

        foreach ($line in $ran) {
            $line | Should -Not -Match '-Task\s+(\S*,)?version(,|\s|$)'
            $line | Should -Not -Match '-Task\s+(\S*,)?ci(,|\s|$)'
        }
    }

    It 'publishes what the build staged, not the working tree' {
        # out/<name>/<version> is what Invoke-HDTBuild produced and validated -
        # the manifest exports checked against the module's own exports. The
        # source tree has tests and fixtures beside it.
        $script:publishText | Should -Match 'out/Hephaestus'
    }

    It 'takes the key from a secret and never from the file' {
        $script:publishText | Should -Match 'secrets\.PSGALLERY_API_KEY'
        $script:publishText | Should -Not -Match '(?m)NuGetApiKey\s*[:=]\s*[''"][A-Za-z0-9]'
    }

    It 'says which secret is missing rather than failing inside NuGet' {
        $script:publishText | Should -Match 'PSGALLERY_API_KEY is not set'
    }

    It 'asks for exactly the write it needs to create a Release, and nothing more' -Skip:$script:yamlMissing {
        # WIDENED FROM read ON 2026-09-05, DELIBERATELY, TO CREATE THE RELEASE
        # ITSELF. gh release create is a repository write - there is no
        # narrower scope for it - so this is a real posture change, made only
        # because the workflow now performs a write it did not before. Still
        # the single permission this job needs: nothing here pushes a commit,
        # opens a PR, or touches anything but the Releases list.
        $permission = (ConvertFrom-Yaml $script:publishText)['permissions']

        $permission['contents'] | Should -BeExactly 'write'
    }

    It 'creates a GitHub Release from the tag it just published' -Skip:$script:yamlMissing {
        # A TAG WITH NO RELEASE BEHIND IT is what v0.13.0 through v0.19.0 all
        # were: Publish shipped every one of them to the Gallery and none of
        # them got a Release page, because nothing in this file ever asked
        # for one. v0.12.0 has a Release only because somebody made it by
        # hand once.
        $release = @($script:publishJob['steps'] | Where-Object { [string] $_['name'] -eq 'Create a GitHub Release' })
        $release.Count | Should -Be 1

        [string] $release[0]['run'] | Should -Match 'gh release create'
    }

    It 'only creates a Release on the same condition that actually published' -Skip:$script:yamlMissing {
        # THE DRY RUN, AND A VERSION THE GALLERY ALREADY HAS, MUST NOT GET ONE.
        # needs.preflight.outputs.published is 'false' only when the Gallery
        # check found this version already there and skipped the Gallery
        # publish for the same reason - the two steps stay in lockstep by
        # sharing the guard rather than each inventing its own.
        #
        # IT MOVED FROM steps.gallery TO needs.preflight WHEN THE CHECK MOVED
        # INTO ITS OWN JOB, in front of the lab. Same value, read from the job
        # that now produces it.
        $release = @($script:publishJob['steps'] | Where-Object { [string] $_['name'] -eq 'Create a GitHub Release' })

        [string] $release[0]['if'] | Should -Match "github\.event_name == 'push'"
        [string] $release[0]['if'] | Should -Match "needs\.preflight\.outputs\.published != 'false'"
    }
}

Describe 'the manifest the Gallery would show' {

    # CHECKED ON EVERY BUILD, because the first time anybody looks at these is
    # the moment they are trying to ship.

    It 'declares a version that parses' {
        { [version] $script:manifest.ModuleVersion } | Should -Not -Throw
    }

    It 'names <Field>, which the Gallery lists' -ForEach @(
        @{ Field = 'Author' }
        @{ Field = 'Description' }
        @{ Field = 'GUID' }
    ) {
        [string] $script:manifest[$Field] | Should -Not -BeNullOrEmpty
    }

    It 'carries tags, which is how anybody finds it' {
        @($script:manifest.PrivateData.PSData.Tags).Count | Should -BeGreaterThan 0
    }

    It 'points at the repository' {
        # A Gallery page with no project link is a dead end for anybody trying
        # to report a bug.
        [string] $script:manifest.PrivateData.PSData.ProjectUri | Should -Match '^https://github\.com/'
    }

    It 'declares the minimum PowerShell version WinPE ships' {
        [string] $script:manifest.PowerShellVersion | Should -BeExactly '5.1'
    }
}

# ---------------------------------------------------------------------------

Describe 'the lab gate in front of a release' {

    # A TAG USED TO GO STRAIGHT TO THE GALLERY. publish.yml ran
    # clean,bundle,build,lint,test,selfcheck on a hosted runner and shipped -
    # and tests/e2e, the only suite that proves HDT can actually deploy a
    # machine, ran on a Sunday cron nobody was watching. Every release between
    # v0.4.0 and v0.24.0 shipped without one line of evidence that the engine
    # boots a VM.
    #
    # THE ORDER IS NOW: preflight -> lab -> publish, and the middle one is
    # e2e.yml ITSELF, called with `uses:`. Not a copy of its steps - rule 8
    # applied to CI. The Sunday cron and the release path run the same
    # definition, so a fix to the lab job reaches both or neither.
    #
    # WHAT THESE CASES ARE REALLY DEFENDING is the shape of the dependency,
    # because there are two ways to get it wrong that look fine in review:
    # an `if:` on the lab job (which makes it skippable and, worse, makes
    # every job that needs it skip too), and `always()` on the publish job
    # (which turns "the lab passed" into "the lab finished, or was cancelled,
    # or never ran").

    BeforeAll {
        $script:publishWorkflow = $null
        $script:labJob = $null
        $script:preflightJob = $null
        $script:releaseJob = $null

        if ($script:publishText -and -not $script:yamlMissing) {
            $script:publishWorkflow = ConvertFrom-Yaml $script:publishText
            $script:labJob = $script:publishWorkflow['jobs']['lab']
            $script:preflightJob = $script:publishWorkflow['jobs']['preflight']
            $script:releaseJob = $script:publishWorkflow['jobs']['publish']
        }
    }

    It 'calls the e2e workflow rather than copying its steps' -Skip:$script:yamlMissing {
        # ONE DEFINITION, TWO CALLERS. A second copy of "check the runner, run
        # ./build.ps1 -Task e2e, upload the diagnostics" would be a second
        # source of truth, and the cron copy would be the one still passing
        # after somebody fixed the release copy.
        $script:labJob | Should -Not -BeNullOrEmpty
        [string] $script:labJob['uses'] | Should -BeExactly './.github/workflows/e2e.yml'
    }

    It 'cannot skip the lab on the way to the Gallery' -Skip:$script:yamlMissing {
        # NO `if:` AT ALL on the lab job. An `if:` is the bypass: a condition
        # that is false skips the job, and GitHub then skips everything that
        # needs it - so a mistyped guard does not fail the release, it
        # publishes without one.
        $script:labJob.ContainsKey('if') | Should -BeFalse
    }

    It 'will not publish until the lab job has succeeded' -Skip:$script:yamlMissing {
        @($script:releaseJob['needs']) | Should -Contain 'lab'
    }

    It 'never reaches the Gallery on always()' -Skip:$script:yamlMissing {
        # `needs: lab` alone means "only if lab succeeded". Adding always() -
        # or failure(), or a cancelled() branch - to the publishing job would
        # quietly restore exactly the behaviour this whole change removes.
        $guard = ''
        if ($script:releaseJob.ContainsKey('if')) { $guard = [string] $script:releaseJob['if'] }

        $guard | Should -Not -Match 'always\('
        $guard | Should -Not -Match 'cancelled\('

        foreach ($step in @($script:releaseJob['steps'])) {
            if ($step.ContainsKey('if')) {
                [string] $step['if'] | Should -Not -Match 'always\('
            }
        }
    }

    It 'checks the tag and the Gallery before it commits the lab to anything' -Skip:$script:yamlMissing {
        # THE LAB IS THE EXPENSIVE PART - hours on a machine somebody owns.
        # A tag that disagrees with the manifest, or a version the Gallery
        # already holds, is knowable in about a minute on a hosted runner, and
        # neither is changed by building. The same argument the Gallery check
        # already makes for running before the build, one step further out.
        $script:preflightJob | Should -Not -BeNullOrEmpty
        [string] $script:preflightJob['runs-on'] | Should -BeExactly 'windows-latest'

        # THE LAB REACHES preflight THROUGH ci NOW, not directly - the chain is
        # preflight -> ci -> lab, and the whole ordering is asserted in 'the
        # order a release runs in'. What matters here is that the cheap checks
        # sit upstream of everything expensive, so the first link is the one to
        # pin: nothing at all runs before them.
        $script:preflightJob.ContainsKey('needs') | Should -BeFalse

        @($script:publishWorkflow['jobs']['ci']['needs']) | Should -Contain 'preflight'
        @($script:releaseJob['needs']) | Should -Contain 'preflight'
    }

    It 'still refuses a tag that disagrees with the manifest' -Skip:$script:yamlMissing {
        $checks = @($script:preflightJob['steps'] | ForEach-Object { [string] $_['run'] }) -join "`n"
        $checks | Should -Match 'Hephaestus\.psd1 says'
    }

    It 'still refuses to republish a version the Gallery holds' -Skip:$script:yamlMissing {
        $checks = @($script:preflightJob['steps'] | ForEach-Object { [string] $_['run'] }) -join "`n"
        $checks | Should -Match 'Find-Module'
        $checks | Should -Match 'published=false'

        $script:preflightJob['outputs']['published'] | Should -Match 'steps\.gallery\.outputs\.published'
    }

    It 'gives the lab a deadline of its own on the release path' -Skip:$script:yamlMissing {
        # `timeout-minutes` IS NOT ALLOWED ON A JOB THAT CALLS A REUSABLE
        # WORKFLOW - GitHub rejects the file - so the deadline is an input the
        # called workflow applies to its own job. The cron may have six hours;
        # a release waiting six hours to find out the lab hung is a release
        # nobody will wait for.
        $script:labJob['with'] | Should -Not -BeNullOrEmpty
        [int] $script:labJob['with']['timeoutMinutes'] | Should -BeGreaterThan 0
        [int] $script:labJob['with']['timeoutMinutes'] | Should -BeLessThan 360
    }

    It 'hands the lab job read and no secrets' -Skip:$script:yamlMissing {
        # The publishing job needs contents: write for `gh release create`.
        # The job that runs on a machine in somebody's lab must not inherit it,
        # and must not be handed PSGALLERY_API_KEY either - it has no use for
        # a key that can write to the Gallery.
        $script:labJob['permissions']['contents'] | Should -BeExactly 'read'
        $script:labJob.ContainsKey('secrets') | Should -BeFalse
    }

    It 'says on the run page that it is waiting rather than looking hung' -Skip:$script:yamlMissing {
        # `environment: lab` carries a required reviewer, so a tag push stops
        # dead until somebody presses a button. A run that stops with no
        # explanation looks broken; this one writes what it is waiting for.
        $summaries = @($script:preflightJob['steps'] | ForEach-Object { [string] $_['run'] }) -join "`n"
        $summaries | Should -Match 'GITHUB_STEP_SUMMARY'
        $summaries | Should -Match 'approv'
    }
}


# ---------------------------------------------------------------------------

Describe 'the order a release runs in' {

    # preflight -> ci -> lab -> publish, AND EACH ARROW IS LOAD-BEARING.
    #
    # The chain is ordered by what it costs to find out something is wrong:
    #
    #   preflight   two manifest reads and one Find-Module. About a minute,
    #               on a hosted runner, and it answers "is this tag even
    #               shippable" before anything else is spent.
    #   ci          the same gate the branch runs, on hosted runners.
    #               ~20 minutes of somebody else's compute.
    #   lab         ~90 minutes on GHRUNNER01, a machine in somebody's house,
    #               behind an approval click a human has to be awake for.
    #   publish     the artefact, then the Gallery, then the Release.
    #
    # "BUT THE TAGGED COMMIT ALREADY PASSED ci.yml ON main" IS TRUE RIGHT UP
    # UNTIL IT IS NOT, and the cases where it is not are the ones that cost
    # something: a tag pointed at an older commit, a tag pushed at the same
    # time as the branch so the branch's own run is still going, or a commit
    # that reached main by a route that did not run CI. In each of those the
    # old shape spent the lab and the approval first and found the lint
    # failure afterwards.

    BeforeAll {
        $script:graph = $null
        if ($script:publishText -and -not $script:yamlMissing) {
            $script:graph = (ConvertFrom-Yaml $script:publishText)['jobs']
        }
    }

    It 'runs preflight, then CI, then the lab, then the publish' -Skip:$script:yamlMissing {
        @($script:graph.Keys) | Should -Contain 'preflight'

        @($script:graph['ci']['needs'])      | Should -Contain 'preflight'
        @($script:graph['lab']['needs'])     | Should -Contain 'ci'
        @($script:graph['publish']['needs']) | Should -Contain 'lab'
    }

    It 'calls the CI workflow rather than copying its steps' -Skip:$script:yamlMissing {
        # THE SAME ARGUMENT THAT MADE THE LAB A CALL. A second copy of the
        # edition, the dependency installs and the build invocation would be a
        # second source of truth, and the branch's copy would be the one still
        # green after somebody fixed the release's. It also means the release
        # runs the IDENTICAL gate the branch does - Windows PowerShell 5.1,
        # 7 for the seven schema contracts that skip whole under 5.1.
        [string] $script:graph['ci']['uses'] | Should -BeExactly './.github/workflows/ci.yml'
    }

    It 'cannot skip CI or the lab on the way to the Gallery' -Skip:$script:yamlMissing {
        # NO `if:` ON EITHER. A condition that evaluates false skips the job,
        # and GitHub then skips everything that needs it - so a mistyped guard
        # does not fail the release, it publishes without a gate.
        $script:graph['ci'].ContainsKey('if')  | Should -BeFalse
        $script:graph['lab'].ContainsKey('if') | Should -BeFalse
    }

    It 'builds the artefact it uploads and does not re-run the gate' -Skip:$script:yamlMissing {
        # WHAT SURVIVED, AND WHY. bundle and build are not verification, they
        # are how out/Hephaestus/<version> comes to exist at all - and build is
        # itself the artefact's own check: Test-ModuleManifest, then
        # FunctionsToExport compared against what the module really exports,
        # then a refusal if Hephaestus.bundle.ps1 is not staged. clean is there
        # so the stage cannot inherit anything from a previous run.
        #
        # WHAT WENT, AND WHY. lint, test and selfcheck all run in the ci job,
        # on this exact commit, on the gate's own edition, minutes earlier - and none of
        # them looks at the staged folder. selfcheck watches a deliberately
        # failing test fail; it proves the harness, not the package. Running
        # the three again here is twenty minutes per release buying a second
        # opinion from the same code about the same commit.
        # THE COMMAND, NOT A COMMENT THAT QUOTES ONE. The Gallery step's own
        # header says "./build.ps1 -Task bundle,build is what puts it there",
        # so a match anywhere in a step's `run` finds two steps and joins their
        # text into something that matches nothing. Only lines that ARE the
        # invocation count.
        $invocations = @($script:graph['publish']['steps'] |
                ForEach-Object { [string] $_['run'] -split "`r?`n" } |
                Where-Object { $_ -match '^\s*\./build\.ps1\s+-Task' } |
                ForEach-Object { $_.Trim() })

        @($invocations).Count | Should -Be 1
        $invocations[0] | Should -BeExactly './build.ps1 -Task clean,bundle,build'
    }

    It 'keeps the gate on a job of its own, where it cannot touch the manifest this one stages' -Skip:$script:yamlMissing {
        # ./build.ps1 -Task ci INCLUDES version, WHICH REWRITES ModuleVersion.
        # That is the v0.4.0 defect: ci bumped the manifest to 0.5.0 and the
        # publish step re-read it, putting 0.5.0 on the Gallery under a tag
        # saying 0.4.0.
        #
        # IT IS SAFE HERE ONLY BECAUSE ci IS A SEPARATE JOB. GitHub gives every
        # job its own runner and its own checkout, so the bump happens in a
        # tree that is thrown away and the publishing job reads the manifest at
        # the tag. Put those steps back inside this job and the defect returns.
        [string] $script:graph['ci']['uses'] | Should -Not -BeNullOrEmpty

        foreach ($step in @($script:graph['publish']['steps'])) {
            [string] $step['run'] | Should -Not -Match '-Task\s+(\S*,)?version(,|\s|$)'
            [string] $step['run'] | Should -Not -Match '-Task\s+(\S*,)?ci(,|\s|$)'
        }
    }

    It 'grants the CI job the write its own workflow declares, and nothing new' -Skip:$script:yamlMissing {
        # ci.yml DECLARES contents: write AT WORKFLOW LEVEL for the badges
        # branch, and a called workflow may not ask for more than the calling
        # job grants. Handing it read would be the tidier posture and is not
        # available: the call is refused rather than quietly narrowed.
        #
        # THE BADGES ARE STOPPED BY THE REF, NOT BY THE TOKEN - see the case in
        # CiWorkflow.Tests.ps1. A release runs on refs/tags/v*, the badge step
        # requires refs/heads/main, so it is skipped.
        $script:graph['ci']['permissions']['contents'] | Should -BeExactly 'write'
        $script:graph['ci'].ContainsKey('secrets') | Should -BeFalse
    }
}
