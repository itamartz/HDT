function New-HDTPesterConfiguration {
    <#
        .SYNOPSIS
            Builds the Pester 5 configuration HDT runs its suites with.

        .DESCRIPTION
            Produces a PesterConfiguration with the settings every HDT test run
            needs: PassThru enabled so the caller can inspect the result, Run.Exit
            disabled so build.ps1 owns the process exit code, and Should.ErrorAction
            set to Stop so the first failed assertion in an It ends that It.

            Pester must already be imported, pinned to the 5.x line. On this machine
            Pester 6.0.0 is installed alongside 5.7.1 and wins a bare import under
            Windows PowerShell 5.1, so every import must specify
            -MinimumVersion 5.0.0 -MaximumVersion 5.99.99.

        .PARAMETER Path
            One or more paths containing test files.

        .PARAMETER ResultPath
            Path of the NUnitXml result file to write. Test result output is
            disabled when this is not supplied.

        .PARAMETER CoveragePath
            Files or directories to measure code coverage over. Coverage is off
            when this is not supplied: it profiles every command the suite
            executes, and a developer running one file should not pay for it.

        .PARAMETER CoverageResultPath
            Path of the JaCoCo coverage file to write. JaCoCo because every
            coverage reader - shields, Codecov, the VS Code gutters - reads it.

        .PARAMETER ExcludeTag
            Tags to exclude from the run, for example Integration or E2E.

        .PARAMETER Verbosity
            Pester output verbosity. Defaults to Detailed.

        .OUTPUTS
            PesterConfiguration

        .EXAMPLE
            $configuration = New-HDTPesterConfiguration -Path './tests/unit' -ResultPath './out/testResults/unit.xml'
            Invoke-Pester -Configuration $configuration

            Runs the unit suite and writes an NUnitXml result file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory configuration object; it changes no state.')]
    [CmdletBinding()]
    [OutputType('PesterConfiguration')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter()]
        [string] $ResultPath,

        [Parameter()]
        [string[]] $CoveragePath,

        [Parameter()]
        [string] $CoverageResultPath,

        [Parameter()]
        [string[]] $ExcludeTag,

        [Parameter()]
        [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
        [string] $Verbosity = 'Detailed'
    )

    if (-not (Get-Command -Name 'New-PesterConfiguration' -ErrorAction SilentlyContinue)) {
        throw 'Pester 5 is required; import it with -MinimumVersion 5.0.0 -MaximumVersion 5.99.99'
    }

    $configuration = New-PesterConfiguration

    $configuration.Run.Path = $Path
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Output.Verbosity = $Verbosity
    $configuration.Should.ErrorAction = 'Stop'

    if ($ExcludeTag) {
        $configuration.Filter.ExcludeTag = $ExcludeTag
    }

    if ($CoveragePath) {
        $configuration.CodeCoverage.Enabled = $true
        $configuration.CodeCoverage.Path = $CoveragePath
        $configuration.CodeCoverage.OutputFormat = 'JaCoCo'

        # PROFILER, NOT BREAKPOINTS. Pester's original coverage sets a line
        # breakpoint on every command and runs the whole suite under the
        # debugger; on a suite this size that is not a slowdown, it is a
        # different order of magnitude. UseBreakpoints = $false selects the
        # profiler-based tracer added in Pester 5.2.
        $configuration.CodeCoverage.UseBreakpoints = $false

        if ($CoverageResultPath) {
            $coverageDirectory = Split-Path -Parent $CoverageResultPath
            if ($coverageDirectory -and -not (Test-Path -Path $coverageDirectory)) {
                New-Item -Path $coverageDirectory -ItemType Directory -Force | Out-Null
            }

            $configuration.CodeCoverage.OutputPath = $CoverageResultPath
        }
    } else {
        $configuration.CodeCoverage.Enabled = $false
    }

    if ($ResultPath) {
        $resultDirectory = Split-Path -Parent $ResultPath
        if ($resultDirectory -and -not (Test-Path -Path $resultDirectory)) {
            New-Item -Path $resultDirectory -ItemType Directory -Force | Out-Null
        }

        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = $ResultPath
    } else {
        $configuration.TestResult.Enabled = $false
    }

    return $configuration
}
