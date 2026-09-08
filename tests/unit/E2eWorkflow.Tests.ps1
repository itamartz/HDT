# THE ONE WORKFLOW THAT RUNS ON A MACHINE SOMEBODY OWNS.
#
# tests/e2e needs Hyper-V, so it cannot run on a hosted runner, so it runs on
# GHRUNNER01 - a nested-virtualisation guest on the MS-A2 lab host, on a private
# LAN beside a domain controller and a ConfigMgr server belonging to another
# project. This repository is PUBLIC. A fork's pull request is code written by
# somebody nobody here has met, and GitHub's first-time-contributor approval
# stops exactly one pull request per person.
#
# So the rule this file exists to hold is: A JOB THAT RUNS ON A SELF-HOSTED
# RUNNER MUST NOT BE REACHABLE FROM A FORK. It is asserted against the SET of
# workflow files rather than against e2e.yml alone, because the workflow that
# breaks it will be the next one somebody adds, not this one.
#
# YAML 1.1 gotcha, same as CiWorkflow.Tests.ps1: ConvertFrom-Yaml turns the
# GitHub Actions 'on:' key into the BOOLEAN $true. Trigger assertions are made
# against the raw file text.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
$script:HDTYamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')

Describe 'E2E workflow' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

        $script:workflowPath = Join-Path -Path $script:repoRoot -ChildPath '.github/workflows/e2e.yml'

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
            $script:job = $script:workflow['jobs']['e2e']
        }
    }

    It 'exists at .github/workflows/e2e.yml' {
        Test-Path -Path $script:workflowPath -PathType Leaf | Should -BeTrue
    }

    It 'is valid YAML' -Skip:$script:HDTYamlMissing {
        $script:workflowText | Should -Not -BeNullOrEmpty
        { ConvertFrom-Yaml $script:workflowText } | Should -Not -Throw
    }

    It 'runs on the self-hosted, nested-virtualisation runner' -Skip:$script:HDTYamlMissing {
        # LABELS, NOT A NAME. A runner is replaced when the lab host is rebuilt
        # and the new one will not be called what the old one was; what does not
        # change is that it is Windows and that it can nest a hypervisor.
        $labels = @($script:job['runs-on'])
        $labels | Should -Contain 'self-hosted'
        $labels | Should -Contain 'windows'
        $labels | Should -Contain 'hyperv-nested'
    }

    It 'runs every step under Windows PowerShell 5.1' -Skip:$script:HDTYamlMissing {
        # The same reason as the gate: the engine runs in WinPE, which has no
        # pwsh. `shell: powershell` on Windows IS 5.1.
        $script:workflow['jobs']['e2e']['defaults']['run']['shell'] | Should -Be 'powershell'
    }

    It 'invokes ./build.ps1 with the e2e task' {
        $script:workflowText | Should -Match '\./build\.ps1\s+-Task\s+e2e'
    }

    It 'is given a deadline rather than left burning' {
        # It deploys real operating systems to real VMs; it is allowed hours.
        # It is not allowed to hold the lab host for ever.
        #
        # THE DEADLINE IS AN INPUT NOW, WITH A DEFAULT, and it has to be both.
        # `timeout-minutes` is not a key GitHub allows on a job that calls a
        # reusable workflow, so the release path cannot set a shorter one from
        # outside - it passes a number in and this job applies it. And an
        # input declared under workflow_call does NOT get its default on a
        # schedule or a workflow_dispatch: `inputs.timeoutMinutes` is null
        # there, and a bare `timeout-minutes: ${{ inputs.timeoutMinutes }}`
        # would be an empty value and an invalid workflow. Hence the `||`.
        $script:workflowText | Should -Match 'timeout-minutes:\s*\$\{\{\s*inputs\.timeoutMinutes\s*\|\|\s*\d+\s*\}\}'

        $fallback = [int] ([regex]::Match($script:workflowText,
                'timeout-minutes:\s*\$\{\{\s*inputs\.timeoutMinutes\s*\|\|\s*(?<default>\d+)\s*\}\}').Groups['default'].Value)

        $fallback | Should -BeGreaterThan 0
        $fallback | Should -BeLessOrEqual 720
    }

    It 'is one definition the release path can call, not a shape to copy' {
        # RULE 8, APPLIED TO CI. publish.yml runs this suite before it ships
        # anything, and it does it with `uses:` - so the Sunday cron and the
        # release run the same job, and a fix to the runner checks reaches
        # both or neither. A second copy of these steps in publish.yml would
        # be the copy still passing after somebody fixed this one.
        $script:workflowText | Should -Match '(?m)^\s{2}workflow_call:'
    }

    It 'declares the deadline it accepts from a caller' -Skip:$script:HDTYamlMissing {
        # An input GitHub does not know about is rejected at the caller, not
        # here, which is a confusing place to read about it.
        # THE 'on' KEY IS NOT RELIABLY A STRING. YAML 1.1 says `on` is a
        # boolean, and which of the two a parser hands back has moved between
        # powershell-yaml releases - 0.4.12 here keeps it as the string 'on'.
        # Asserted against whichever one this parser produced, so the case
        # tests the workflow rather than the YAML library.
        $triggers = $script:workflow['on']
        if (-not $triggers) { $triggers = $script:workflow[$true] }
        $triggers['workflow_call']['inputs']['timeoutMinutes'] | Should -Not -BeNullOrEmpty
        [string] $triggers['workflow_call']['inputs']['timeoutMinutes']['type'] | Should -BeExactly 'number'
    }

    It 'uploads test results even when the suite fails' -Skip:$script:HDTYamlMissing {
        # A red e2e run is the run whose artefacts are worth keeping.
        $upload = @($script:job['steps']) | Where-Object {
            $_.ContainsKey('uses') -and ([string] $_['uses']).StartsWith('actions/upload-artifact')
        }
        $upload | Should -Not -BeNullOrEmpty
        @($upload | Where-Object { [string] $_['if'] -match 'always\(\)' }) | Should -Not -BeNullOrEmpty
    }

    It 'keeps the deployment diagnostics, not only the .xml' {
        # A failed assertion says a machine never reported its heartbeat. The
        # screenshot and the share's own log say what it was doing instead, and
        # they are the only record of it once the VM is gone.
        $script:workflowText | Should -Match 'e2e-diagnostics'
    }

    It 'triggers on demand, on a schedule, on a caller, and on nothing else' {
        # Raw text: the 'on' key is the boolean $true after a YAML 1.1 parse.
        #
        # workflow_call IS NOT A TRIGGER SOMEBODY CAN PULL. It fires only when
        # another workflow in this repository names this file, and that
        # workflow's own triggers decide who can reach it - which is why the
        # set-wide case below exists.
        $script:workflowText | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:workflowText | Should -Match '(?m)^\s{2}schedule:'
        $script:workflowText | Should -Match '(?m)^\s{2}workflow_call:'
        $script:workflowText | Should -Not -Match '(?m)^\s{2}push:'
    }
}

# ---------------------------------------------------------------------------

Describe 'Self-hosted runners on a public repository' {

    # ASSERTED OVER EVERY WORKFLOW FILE, DELIBERATELY. e2e.yml is correct today
    # and a test that only reads e2e.yml would pass for e2e.yml and fail nobody
    # after it. The workflow that puts the lab host in front of a stranger will
    # be one somebody adds later, and this is what has to catch it.

    BeforeDiscovery {
        $discoveryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:workflowFiles = @(
            Get-ChildItem -Path (Join-Path -Path $discoveryRoot -ChildPath '.github/workflows') `
                -Filter '*.yml' -File -ErrorAction SilentlyContinue |
                ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
        )
    }

    It 'finds the workflow files at all' {
        # A discovery that silently found nothing would make every case below
        # vacuously green, which is the shape of failure this whole file exists
        # to prevent.
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        @(Get-ChildItem -Path (Join-Path -Path $root -ChildPath '.github/workflows') -Filter '*.yml' -File).Count |
            Should -BeGreaterThan 0
    }

    It '<Name> never puts a self-hosted runner behind a fork-reachable trigger' -ForEach $script:workflowFiles {

        $text = Get-Content -LiteralPath $Path -Raw

        # `runs-on: [self-hosted, ...]` or `runs-on: self-hosted`, in any job.
        $selfHosted = $text -match '(?m)^\s*runs-on:.*\bself-hosted\b'

        if ($selfHosted) {
            # pull_request runs the HEAD of a fork's branch on the runner.
            # pull_request_target is worse: the base repository's secrets come
            # with it. Neither may appear in a file with a self-hosted job.
            $text | Should -Not -Match '(?m)^\s{2}pull_request:'
            $text | Should -Not -Match '(?m)^\s{2}pull_request_target:'
        } else {
            # Nothing to prove for a hosted workflow; the assertion above is the
            # whole rule. Kept explicit so the case is reported rather than
            # silently absent from the run.
            $selfHosted | Should -BeFalse
        }
    }

    It '<Name> asks for no more token than it needs when it is self-hosted' -ForEach $script:workflowFiles {

        $text = Get-Content -LiteralPath $Path -Raw
        $selfHosted = $text -match '(?m)^\s*runs-on:.*\bself-hosted\b'

        if ($selfHosted) {
            # A writable GITHUB_TOKEN on a machine somebody owns is the thing
            # that turns a compromised job into a compromised repository.
            $text | Should -Match '(?m)^permissions:'
            $text | Should -Not -Match '(?m)^\s+contents:\s*write'
        } else {
            $selfHosted | Should -BeFalse
        }
    }

    It '<Name> never reaches a self-hosted runner from a fork-reachable trigger' -ForEach $script:workflowFiles {

        # THE HOLE workflow_call OPENS, AND THE ONLY TEST THAT WOULD SEE IT.
        # Every case above reads one file and asks whether THAT file puts a
        # self-hosted `runs-on` behind a pull_request. A reusable workflow is
        # reached from somewhere else: e2e.yml stays clean, and ci.yml - which
        # does trigger on pull_request, because it must - grows one
        # `uses: ./.github/workflows/e2e.yml` and a fork's pull request runs on
        # GHRUNNER01. Nothing else here would notice.
        #
        # A called workflow runs on the CALLER's event, so the caller's
        # triggers are the ones that decide who can reach the lab host.
        #
        # FOLLOWED TRANSITIVELY, BECAUSE THE CALL GRAPH IS TWO DEEP NOW.
        # publish.yml calls ci.yml and e2e.yml both, so one hop is no longer
        # the whole question: the next hole is a `uses:` added to ci.yml
        # pointing at something that itself calls e2e.yml, and a direct check
        # would walk straight past it.

        $text = Get-Content -LiteralPath $Path -Raw
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        $forkReachable = ($text -match '(?m)^\s{2}pull_request:') -or ($text -match '(?m)^\s{2}pull_request_target:')

        # A visited set, because a cycle in workflow calls is something
        # somebody can write and it must not hang the suite.
        $seen = @{}
        $queue = New-Object System.Collections.Queue
        [void] $queue.Enqueue([string] $Path)
        $reaches = @()

        while ($queue.Count -gt 0) {
            $current = [string] $queue.Dequeue()
            if ($seen.ContainsKey($current)) { continue }
            $seen[$current] = $true

            $body = Get-Content -LiteralPath $current -Raw

            # The file this walk STARTED from is judged by the `runs-on:` case
            # above, not by this one. What is collected here is every
            # self-hosted job it can REACH through a call.
            if (($current -ne [string] $Path) -and ($body -match '(?m)^\s*runs-on:.*\bself-hosted\b')) {
                $reaches += (Split-Path -Leaf $current)
            }

            foreach ($found in [regex]::Matches($body, '(?m)^\s*uses:\s*(?<ref>\./\.github/workflows/\S+\.ya?ml)')) {
                $called = Join-Path -Path $root -ChildPath ($found.Groups['ref'].Value -replace '^\./', '')
                if (Test-Path -LiteralPath $called -PathType Leaf) { [void] $queue.Enqueue($called) }
            }
        }

        if ($forkReachable) {
            $reaches | Should -BeNullOrEmpty -Because (
                "$Name is reachable from a fork's pull request and can reach [$($reaches -join ', ')], " +
                'which runs on the lab host - so a fork would run code written outside this project on it')
        } else {
            # Nothing to prove; a workflow no fork can trigger may call
            # whatever it likes. Reported rather than silently absent.
            $forkReachable | Should -BeFalse
        }
    }

    It 'the walk that case depends on actually resolves a call' {

        # THE CASE ABOVE IS VACUOUS IF THE RESOLVER FINDS NOTHING, and it was:
        # the pattern was written with a \b that the tooling turned into a
        # literal backspace, so `runs-on: [self-hosted, ...]` never matched and
        # every fork-reachable file passed by finding zero self-hosted jobs.
        # Green, and asserting nothing at all.
        #
        # So this pins the resolver against a call that IS in the tree:
        # publish.yml -> e2e.yml -> a self-hosted runs-on. If that stops
        # resolving, this fails here rather than leaving the real rule asleep.

        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $publish = Join-Path -Path $root -ChildPath '.github/workflows/publish.yml'
        $body = Get-Content -LiteralPath $publish -Raw

        $called = @([regex]::Matches($body, '(?m)^\s*uses:\s*(?<ref>\./\.github/workflows/\S+\.ya?ml)') |
                ForEach-Object { $_.Groups['ref'].Value })

        $called | Should -Contain './.github/workflows/e2e.yml'

        $e2e = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath '.github/workflows/e2e.yml') -Raw
        $e2e -match '(?m)^\s*runs-on:.*\bself-hosted\b' | Should -BeTrue
    }

    It '<Name> gates a self-hosted job behind an environment' -ForEach $script:workflowFiles {

        $text = Get-Content -LiteralPath $Path -Raw
        $selfHosted = $text -match '(?m)^\s*runs-on:.*\bself-hosted\b'

        if ($selfHosted) {
            # The backstop. An environment with a required reviewer means even a
            # workflow_dispatch waits for a human, which is what still holds if
            # somebody adds a trigger to the file without reading its header.
            $text | Should -Match '(?m)^\s+environment:\s*\S+'
        } else {
            $selfHosted | Should -BeFalse
        }
    }
}
