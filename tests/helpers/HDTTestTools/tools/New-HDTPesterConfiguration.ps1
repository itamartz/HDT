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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingVerbs', '',
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
