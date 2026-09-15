# WHAT A CALLED WORKFLOW MAY ASK FOR, AND WHAT THE LAB MACHINE MAY HOLD.
#
# v1.0.0 WAS TAGGED AND NEVER BUILT. Run 35009921583 came back `startup_failure`
# with zero jobs and no logs: publish.yml calls lab.yml with `contents: read`,
# lab.yml's `badges` job declares `contents: write`, and A CALLED WORKFLOW MAY
# NOT REQUEST MORE PERMISSION THAN ITS CALLER GRANTS. GitHub validates that
# before it creates a single job, so the `if:` that would have skipped `badges`
# on a tag never got the chance to - the run was rejected whole, and the first
# release in months could not start.
#
# NOTHING SAW IT because it was introduced by a restructure - six workflows
# merged into three, and the badge publisher moved INTO lab.yml - and the next
# tag after that restructure was the one that failed. There is no push, no pull
# request and no schedule that exercises a call site's permission grant; only a
# release does, and a release happens once.
#
# SO THE RULE IS ASSERTED OVER THE SET OF CALL SITES, not over the one that
# broke. The call site that gets this wrong next will be one somebody adds - a
# new caller, a new job in a called workflow, a scope nobody thought about - and
# a test naming publish.yml's `lab` job would pass for it and fail nobody after
# it.
#
# AND THE SECOND HALF IS THE ONE THAT MATTERS MORE. The minimal repair is to
# raise the call site to `contents: write`, which is only safe if the jobs on
# GHRUNNER01 cannot then receive it. They could not before by INHERITING
# lab.yml's workflow-level `contents: read` - and inheritance is exactly what
# let this rot unnoticed. So every self-hosted job must STATE its own read-only
# grant, and that is asserted here over every self-hosted job in every file,
# rather than over the two that exist today.
#
# YAML 1.1 gotcha, same as the other workflow files: ConvertFrom-Yaml turns the
# GitHub Actions 'on:' key into a boolean. Nothing here reads it.
#
# SPIKES S9.15: -Skip: is bound at DISCOVERY, before any BeforeAll has run, so
# the flag is set at file scope as well as inside BeforeAll. Under the
# StrictMode build.ps1 sets, reading one that is not there drops the whole file
# and Pester reports 0 failed.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HDTPermissionRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTPermissionRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
$script:HDTYamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')

# THE HELPERS LIVE IN A TOP-LEVEL BeforeAll, NOT AT FILE SCOPE. Pester 5 runs
# every It inside its own scope and a function declared beside the Describes is
# not in it - the first draft of this file reported four
# CommandNotFoundException failures that looked exactly like the defect it was
# written to catch. A file-level BeforeAll runs once and its functions reach
# every container below.
BeforeAll {

# THE THREE LEVELS GITHUB HAS, RANKED. `none` is what an unlisted scope gets
# once a permissions block is present at all - declaring one scope silences
# every other, which is why a grant below is a DEFAULT plus a table rather than
# a table alone.
function Get-HDTWorkflowPermissionRank {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Level
    )

    switch ($Level) {
        'none' { return 0 }
        'read' { return 1 }
        'write' { return 2 }
        default { return 0 }
    }
}

# A `permissions:` node as GitHub reads it. It has three shapes: the strings
# `read-all` and `write-all`, an empty map (everything none), and a map of
# scopes. Absent is not a shape - it means "inherit", and the caller of this
# function decides what to inherit from.
function ConvertTo-HDTWorkflowPermissionGrant {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Permissions
    )

    $grant = @{ Default = 'none'; Scopes = @{} }

    if ($null -eq $Permissions) { return $grant }

    if ($Permissions -is [string]) {
        if ($Permissions -eq 'write-all') { $grant.Default = 'write' }
        elseif ($Permissions -eq 'read-all') { $grant.Default = 'read' }
        return $grant
    }

    if ($Permissions -is [System.Collections.IDictionary]) {
        foreach ($scope in @($Permissions.Keys)) {
            $grant.Scopes[[string] $scope] = [string] $Permissions[$scope]
        }
    }

    return $grant
}

function Get-HDTWorkflowPermissionLevel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable] $Grant,
        [Parameter(Mandatory)] [string] $Scope
    )

    if ($Grant.Scopes.ContainsKey($Scope)) { return [string] $Grant.Scopes[$Scope] }

    return [string] $Grant.Default
}

# EVERY `uses: ./.github/workflows/*.yml` IN A FILE, with the job that carries
# it and the grant that job hands over. A job-level block wins; failing that the
# workflow default; failing that the repository's own default token
# permissions, which is a GitHub SETTING and cannot be read from here - so that
# case is reported as unknown rather than guessed at.
function Get-HDTWorkflowCallSite {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $Path
    )

    $sites = @()

    if (-not $Document.Contains('jobs')) { return $sites }

    $workflowPermissions = $null
    $workflowDeclares = $Document.Contains('permissions')
    if ($workflowDeclares) { $workflowPermissions = $Document['permissions'] }

    foreach ($name in @($Document['jobs'].Keys)) {

        $job = $Document['jobs'][$name]
        if (-not ($job -is [System.Collections.IDictionary])) { continue }
        if (-not $job.Contains('uses')) { continue }

        $uses = [string] $job['uses']
        if ($uses -notmatch '^\./\.github/workflows/') { continue }

        $grant = $null

        if ($job.Contains('permissions')) {
            $grant = ConvertTo-HDTWorkflowPermissionGrant -Permissions $job['permissions']
        }
        elseif ($workflowDeclares) {
            $grant = ConvertTo-HDTWorkflowPermissionGrant -Permissions $workflowPermissions
        }

        $sites += @{
            Caller = Split-Path -Leaf $Path
            Job    = [string] $name
            Called = $uses
            Grant  = $grant
        }
    }

    return $sites
}

# EVERY PERMISSIONS BLOCK A CALLED WORKFLOW CARRIES - the workflow default and
# each job's own. GitHub checks them all at startup, so this has to look at all
# of them; the `if:` on a job is not consulted there and neither is whether the
# job would ever run.
function Get-HDTWorkflowPermissionRequest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document
    )

    $requests = @()

    if ($Document.Contains('permissions')) {
        $requests += @{
            Where = 'workflow level'
            Grant = (ConvertTo-HDTWorkflowPermissionGrant -Permissions $Document['permissions'])
        }
    }

    if ($Document.Contains('jobs')) {
        foreach ($name in @($Document['jobs'].Keys)) {

            $job = $Document['jobs'][$name]
            if (-not ($job -is [System.Collections.IDictionary])) { continue }
            if (-not $job.Contains('permissions')) { continue }

            $requests += @{
                Where = ("job '{0}'" -f $name)
                Grant = (ConvertTo-HDTWorkflowPermissionGrant -Permissions $job['permissions'])
            }
        }
    }

    return $requests
}

}

Describe 'A called workflow may not outrank its caller' {

    BeforeDiscovery {
        $discoveryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:permissionWorkflowFiles = @(
            Get-ChildItem -Path (Join-Path -Path $discoveryRoot -ChildPath '.github/workflows') `
                -Filter '*.yml' -File -ErrorAction SilentlyContinue |
                ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
        )
    }

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

        # SET IN BOTH PHASES. Discovery reads the copy at file scope; this is
        # the one every It reads while it runs.
        $script:HDTYamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')

        $script:workflowDirectory = Join-Path -Path $script:repoRoot -ChildPath '.github/workflows'
    }

    It 'finds call sites at all' -Skip:$script:HDTYamlMissing {
        # A DISCOVERY THAT FOUND NOTHING WOULD MAKE EVERY CASE BELOW VACUOUS,
        # which is the exact shape of failure this file exists to prevent: a
        # release is the only thing that exercises a call site, so a green run
        # proving nothing would not be noticed until the next tag.
        $found = 0

        foreach ($file in (Get-ChildItem -LiteralPath $script:workflowDirectory -Filter '*.yml' -File)) {
            $document = ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw)
            $found += @(Get-HDTWorkflowCallSite -Document $document -Path $file.FullName).Count
        }

        $found | Should -BeGreaterThan 0 -Because 'publish.yml calls gate.yml and lab.yml; if neither is seen the case below is asserted about nothing'
    }

    It '<Name> grants every call site at least what the called workflow asks for' -Skip:$script:HDTYamlMissing -ForEach $script:permissionWorkflowFiles {

        $document = ConvertFrom-Yaml (Get-Content -LiteralPath $Path -Raw)
        $sites = @(Get-HDTWorkflowCallSite -Document $document -Path $Path)

        $violations = @()

        foreach ($site in $sites) {

            # THE REPOSITORY'S DEFAULT TOKEN PERMISSIONS IS A SETTING, not a
            # file, so a call site that declares nothing hands over something no
            # test here can read. Every call site states its grant.
            if ($null -eq $site.Grant) {
                $violations += ("{0}: job '{1}' calls {2} and declares no permissions, so what it grants is a GitHub setting rather than something this repository can read" -f
                    $site.Caller, $site.Job, $site.Called)
                continue
            }

            $calledPath = Join-Path -Path $script:repoRoot -ChildPath ($site.Called -replace '^\./', '')

            if (-not (Test-Path -LiteralPath $calledPath -PathType Leaf)) {
                $violations += ("{0}: job '{1}' calls {2}, which does not exist" -f $site.Caller, $site.Job, $site.Called)
                continue
            }

            $called = ConvertFrom-Yaml (Get-Content -LiteralPath $calledPath -Raw)

            foreach ($request in (Get-HDTWorkflowPermissionRequest -Document $called)) {

                foreach ($scope in @($request.Grant.Scopes.Keys)) {

                    $wanted = [string] $request.Grant.Scopes[$scope]
                    $granted = Get-HDTWorkflowPermissionLevel -Grant $site.Grant -Scope $scope

                    if ((Get-HDTWorkflowPermissionRank -Level $wanted) -gt (Get-HDTWorkflowPermissionRank -Level $granted)) {
                        $violations += ("{0}: job '{1}' grants {2}: {3} to {4}, whose {5} asks for {2}: {6} - GitHub rejects the whole run at startup with startup_failure and no logs" -f
                            $site.Caller, $site.Job, $scope, $granted, $site.Called, $request.Where, $wanted)
                    }
                }
            }
        }

        ($violations -join "`n") | Should -BeNullOrEmpty
    }
}

Describe 'No self-hosted job holds a writable token' {

    # THE INVARIANT THAT PROTECTS THE LAB, AND IT IS STATED TWICE ON PURPOSE.
    # E2eWorkflow.Tests.ps1 asserts that a self-hosted job which DECLARES
    # permissions does not declare write. That was enough while every
    # self-hosted job inherited a read-only workflow default - and the call site
    # above now hands lab.yml `contents: write` so that its hosted badge job can
    # push. Inheritance is no longer a safe place to keep this property: delete
    # lab.yml's workflow-level `contents: read` and every job that states
    # nothing would take the caller's write.
    #
    # SO THE RULE HERE IS STRONGER: a self-hosted job must STATE its own grant,
    # and that grant must not be write. Over the set, because the self-hosted
    # job that gets this wrong will be the next one somebody adds.

    BeforeDiscovery {
        $discoveryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:selfHostedWorkflowFiles = @(
            Get-ChildItem -Path (Join-Path -Path $discoveryRoot -ChildPath '.github/workflows') `
                -Filter '*.yml' -File -ErrorAction SilentlyContinue |
                ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
        )
    }

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
        $script:HDTYamlMissing = -not (Test-HDTModuleAvailable -Name 'powershell-yaml')
        $script:workflowDirectory = Join-Path -Path $script:repoRoot -ChildPath '.github/workflows'
    }

    It 'finds the self-hosted jobs at all' -Skip:$script:HDTYamlMissing {
        $found = 0

        foreach ($file in (Get-ChildItem -LiteralPath $script:workflowDirectory -Filter '*.yml' -File)) {

            $document = ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw)
            if (-not $document.Contains('jobs')) { continue }

            foreach ($name in @($document['jobs'].Keys)) {
                $job = $document['jobs'][$name]
                if (-not ($job -is [System.Collections.IDictionary])) { continue }
                if (-not $job.Contains('runs-on')) { continue }
                if ((@($job['runs-on']) -join ' ') -match 'self-hosted') { $found++ }
            }
        }

        $found | Should -BeGreaterThan 0 -Because 'lab.yml runs the gate and the end-to-end suite on GHRUNNER01; seeing none means the case below proves nothing'
    }

    It '<Name> states a read-only grant on every self-hosted job' -Skip:$script:HDTYamlMissing -ForEach $script:selfHostedWorkflowFiles {

        $document = ConvertFrom-Yaml (Get-Content -LiteralPath $Path -Raw)
        $file = Split-Path -Leaf $Path

        $violations = @()

        if ($document.Contains('jobs')) {
            foreach ($name in @($document['jobs'].Keys)) {

                $job = $document['jobs'][$name]
                if (-not ($job -is [System.Collections.IDictionary])) { continue }
                if (-not $job.Contains('runs-on')) { continue }
                if (-not ((@($job['runs-on']) -join ' ') -match 'self-hosted')) { continue }

                if (-not $job.Contains('permissions')) {
                    $violations += ("{0}: job '{1}' runs on a machine somebody owns and states no permissions of its own, so the token it holds is whatever the workflow default or a caller hands it" -f
                        $file, $name)
                    continue
                }

                $grant = ConvertTo-HDTWorkflowPermissionGrant -Permissions $job['permissions']

                foreach ($scope in @($grant.Scopes.Keys)) {
                    if (([string] $grant.Scopes[$scope]) -eq 'write') {
                        $violations += ("{0}: job '{1}' runs self-hosted and asks for {2}: write - a writable token on a machine somebody owns turns a compromised job into a compromised repository" -f
                            $file, $name, $scope)
                    }
                }

                if ($grant.Default -eq 'write') {
                    $violations += ("{0}: job '{1}' runs self-hosted and asks for write-all" -f $file, $name)
                }
            }
        }

        ($violations -join "`n") | Should -BeNullOrEmpty
    }
}
