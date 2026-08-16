# The application catalog shipped in samples/, read the way a deployment reads
# it. ConsoleRoundTrip.Tests.ps1 does this for every sample SEQUENCE, and this is
# the same idea for the applications: a sample that does not load is a sample
# that teaches the wrong thing, and it is the first file anyone copies.
#
# The catalog is enumerated off disk rather than listed here, so an application
# added to samples/ is covered the day it is added and nobody has to remember.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:sampleRoot = Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace'
    $script:workspaceRoot = 'C:\ws'

    # The real sample files, seeded into a fake filesystem at a workspace root of
    # their own - so the test reads what ships, and touches no disk doing it.
    $script:file = @{}
    foreach ($app in @(Get-ChildItem -Path (Join-Path -Path $script:sampleRoot -ChildPath 'Applications') -Directory -ErrorAction SilentlyContinue)) {
        $path = Join-Path -Path $app.FullName -ChildPath 'app.yaml'

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $script:file[('C:\ws\Applications\{0}\app.yaml' -f $app.Name)] = (Get-Content -LiteralPath $path -Raw)
        }
    }

    $script:fileSystem = New-HDTFakeFileSystem -File $script:file
}

Describe 'the sample application catalog' {

    It 'ships applications to cover in the first place' {
        # Without this, an empty Applications folder would make every assertion
        # below vacuously true.
        $script:file.Count | Should -BeGreaterThan 1
    }

    It 'loads every one of them' {
        $catalog = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem)

        $catalog.Count | Should -Be $script:file.Count
    }

    It 'orders the whole catalog without a cycle' {
        $catalog = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem)

        { Resolve-HDTApplicationOrder -Application $catalog } | Should -Not -Throw
    }

    It 'resolves every dependency the samples name' {
        # A dependency on an application that is not in the workspace is a
        # deployment that fails at the plan stage. In a sample it is a typo
        # somebody copies.
        $catalog = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem)
        $id = @($catalog | ForEach-Object { [string] $_.Id })

        foreach ($application in $catalog) {
            foreach ($dependency in @($application.Dependencies)) {
                $id | Should -Contain ([string] $dependency)
            }
        }
    }

    It 'installs a dependency before the application that needs it' {
        # Corp-Baseline depends on 7Zip-24.09, which is what makes the samples
        # exercise the sort rather than merely parse.
        $catalog = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem)
        $plan = @(Resolve-HDTApplicationOrder -Application $catalog -Id 'Corp-Baseline')

        @($plan | ForEach-Object { $_.Id }) | Should -Be @('7Zip-24.09', 'Corp-Baseline')
    }

    It 'ships one application with a detection rule and one without' {
        # DESIGN 8 makes detect: optional, and the samples are where an
        # administrator learns that both shapes are legitimate.
        $catalog = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem)

        @($catalog | Where-Object { $null -ne $_.Detect }).Count | Should -BeGreaterThan 0
        @($catalog | Where-Object { $null -eq $_.Detect }).Count | Should -BeGreaterThan 0
    }
}
