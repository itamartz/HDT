BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:helperManifest = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -ErrorAction Stop
    Import-Module -Name $script:helperManifest -Force -ErrorAction Stop

    $script:unitPath = Join-Path -Path $script:repoRoot -ChildPath 'tests/unit'
    $script:contractPath = Join-Path -Path $script:repoRoot -ChildPath 'tests/contract'
    $script:sourcePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'
}

Describe 'New-HDTPesterConfiguration' {

    It 'returns a PesterConfiguration object' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath
        $config.GetType().Name | Should -BeExactly 'PesterConfiguration'
    }

    It 'sets Run.Path to the supplied paths' {
        $config = New-HDTPesterConfiguration -Path @($script:unitPath, $script:contractPath)
        @($config.Run.Path.Value) | Should -Be @($script:unitPath, $script:contractPath)
    }

    It 'enables PassThru so the caller can inspect the result' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath
        $config.Run.PassThru.Value | Should -BeTrue
    }

    It 'leaves Run.Exit disabled so build.ps1 controls the exit code' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath
        $config.Run.Exit.Value | Should -BeFalse
    }

    It 'enables NUnitXml test results at the supplied ResultPath' {
        $resultPath = Join-Path -Path $TestDrive -ChildPath 'results/pester.xml'
        $config = New-HDTPesterConfiguration -Path $script:unitPath -ResultPath $resultPath
        $config.TestResult.Enabled.Value | Should -BeTrue
        $config.TestResult.OutputFormat.Value | Should -BeExactly 'NUnitXml'
        $config.TestResult.OutputPath.Value | Should -BeExactly $resultPath
    }

    It 'disables test results when no ResultPath is supplied' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath
        $config.TestResult.Enabled.Value | Should -BeFalse
    }

    It 'applies ExcludeTag to Filter.ExcludeTag' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath -ExcludeTag @('Integration', 'E2E')
        @($config.Filter.ExcludeTag.Value) | Should -Be @('Integration', 'E2E')
    }

    It 'defaults Output.Verbosity to Detailed' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath
        $config.Output.Verbosity.Value | Should -BeExactly 'Detailed'
    }

    It 'honours an explicit Verbosity' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath -Verbosity 'Normal'
        $config.Output.Verbosity.Value | Should -BeExactly 'Normal'
    }

    It 'sets Should.ErrorAction to Stop' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath
        $config.Should.ErrorAction.Value | Should -BeExactly 'Stop'
    }

    It 'leaves code coverage off when no CoveragePath is supplied' {
        # Coverage is not free: it profiles every command the suite executes.
        # Every caller that does not ask for a coverage report - the selfcheck
        # fixtures, a developer running one file - pays nothing.
        $config = New-HDTPesterConfiguration -Path $script:unitPath
        $config.CodeCoverage.Enabled.Value | Should -BeFalse
    }

    It 'covers the supplied CoveragePath' {
        $config = New-HDTPesterConfiguration -Path $script:unitPath -CoveragePath $script:sourcePath
        $config.CodeCoverage.Enabled.Value | Should -BeTrue
        @($config.CodeCoverage.Path.Value) | Should -Be @($script:sourcePath)
    }

    It 'writes JaCoCo, which is what every coverage reader understands' {
        $coveragePath = Join-Path -Path $TestDrive -ChildPath 'coverage/coverage.xml'
        $config = New-HDTPesterConfiguration -Path $script:unitPath -CoveragePath $script:sourcePath -CoverageResultPath $coveragePath

        $config.CodeCoverage.OutputFormat.Value | Should -BeExactly 'JaCoCo'
        $config.CodeCoverage.OutputPath.Value | Should -BeExactly $coveragePath
    }

    It 'profiles rather than setting a breakpoint on every command' {
        # Pester's original coverage sets a line breakpoint per command and runs
        # the suite under the debugger. On a suite this size that is not a
        # slowdown, it is a different order of magnitude. UseBreakpoints = $false
        # selects the profiler-based tracer added in Pester 5.2.
        $config = New-HDTPesterConfiguration -Path $script:unitPath -CoveragePath $script:sourcePath
        $config.CodeCoverage.UseBreakpoints.Value | Should -BeFalse
    }

    It 'throws when Path is empty' {
        { New-HDTPesterConfiguration -Path @() } | Should -Throw
    }
}

# PESTER MAKES A TestRegistry PER CONTAINER WHETHER OR NOT ANYTHING USES ONE.
#
# It creates and deletes a GUID key under HKCU:\Software\Pester for every test
# FILE. Two files in this repository use TestRegistry:; the other 307 pay for it
# anyway - and eight workers creating and deleting keys under one parent race,
# so the enumeration fails with "Test-Path : No more data is available" and a
# whole file dies with "Framework failed". Seven different files were the victim
# across one afternoon; none of them touched the registry.
#
# OFF UNLESS ASKED FOR. The two files that need it get a configuration that
# turns it back on, and Split-HDTTestBucket keeps them in one bucket, so exactly
# one process ever touches that key.
Describe 'New-HDTPesterConfiguration and the registry nobody asked for' {

    It 'leaves TestRegistry off' {
        $configuration = New-HDTPesterConfiguration -Path 'tests/unit'

        $configuration.TestRegistry.Enabled.Value | Should -BeFalse
    }

    It 'turns it on when a caller says its files need one' {
        $configuration = New-HDTPesterConfiguration -Path 'tests/unit' -TestRegistry

        $configuration.TestRegistry.Enabled.Value | Should -BeTrue
    }

    # TestDrive IS A DIFFERENT THING AND STAYS ON. Eighteen files use it, it is
    # a directory per container rather than one shared parent, and nothing has
    # ever raced on it.
    It 'leaves TestDrive alone' {
        $configuration = New-HDTPesterConfiguration -Path 'tests/unit'

        $configuration.TestDrive.Enabled.Value | Should -BeTrue
    }
}
