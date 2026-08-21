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

    It 'gates on the suite before it ships anything' {
        # An unpublishable build is a bad day; a published broken one is worse.
        #
        # ON A run: LINE, NOT ANYWHERE IN THE FILE. This asserted that the text
        # held './build.ps1 -Task ci' and passed on a COMMENT saying so, which
        # is how it stayed green through the change that stopped the workflow
        # running ci at all.
        $ran = @($script:publishText -split "`r?`n" |
                Where-Object { $_ -match '^\s*run:\s*\./build\.ps1\s+-Task\s+\S' })

        @($ran).Count | Should -BeGreaterThan 0
        ($ran -join ' ') | Should -Match 'build,lint,test,selfcheck'
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

    It 'asks for no more permission than reading the repository' -Skip:$script:yamlMissing {
        # It publishes outward. Nothing here writes to the repository, and a
        # token that could is a token that might.
        $permission = (ConvertFrom-Yaml $script:publishText)['permissions']

        $permission['contents'] | Should -BeExactly 'read'
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
