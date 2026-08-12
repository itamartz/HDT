BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $helperManifest = Join-Path -Path $repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -ErrorAction Stop
    Import-Module -Name $helperManifest -Force -ErrorAction Stop

    $unitPath = Join-Path -Path $repoRoot -ChildPath 'tests/unit'
    $contractPath = Join-Path -Path $repoRoot -ChildPath 'tests/contract'
}

Describe 'New-HDTPesterConfiguration' {

    It 'returns a PesterConfiguration object' {
        $config = New-HDTPesterConfiguration -Path $unitPath
        $config.GetType().Name | Should -BeExactly 'PesterConfiguration'
    }

    It 'sets Run.Path to the supplied paths' {
        $config = New-HDTPesterConfiguration -Path @($unitPath, $contractPath)
        @($config.Run.Path.Value) | Should -Be @($unitPath, $contractPath)
    }

    It 'enables PassThru so the caller can inspect the result' {
        $config = New-HDTPesterConfiguration -Path $unitPath
        $config.Run.PassThru.Value | Should -BeTrue
    }

    It 'leaves Run.Exit disabled so build.ps1 controls the exit code' {
        $config = New-HDTPesterConfiguration -Path $unitPath
        $config.Run.Exit.Value | Should -BeFalse
    }

    It 'enables NUnitXml test results at the supplied ResultPath' {
        $resultPath = Join-Path -Path $TestDrive -ChildPath 'results/pester.xml'
        $config = New-HDTPesterConfiguration -Path $unitPath -ResultPath $resultPath
        $config.TestResult.Enabled.Value | Should -BeTrue
        $config.TestResult.OutputFormat.Value | Should -BeExactly 'NUnitXml'
        $config.TestResult.OutputPath.Value | Should -BeExactly $resultPath
    }

    It 'disables test results when no ResultPath is supplied' {
        $config = New-HDTPesterConfiguration -Path $unitPath
        $config.TestResult.Enabled.Value | Should -BeFalse
    }

    It 'applies ExcludeTag to Filter.ExcludeTag' {
        $config = New-HDTPesterConfiguration -Path $unitPath -ExcludeTag @('Integration', 'E2E')
        @($config.Filter.ExcludeTag.Value) | Should -Be @('Integration', 'E2E')
    }

    It 'defaults Output.Verbosity to Detailed' {
        $config = New-HDTPesterConfiguration -Path $unitPath
        $config.Output.Verbosity.Value | Should -BeExactly 'Detailed'
    }

    It 'honours an explicit Verbosity' {
        $config = New-HDTPesterConfiguration -Path $unitPath -Verbosity 'Normal'
        $config.Output.Verbosity.Value | Should -BeExactly 'Normal'
    }

    It 'sets Should.ErrorAction to Stop' {
        $config = New-HDTPesterConfiguration -Path $unitPath
        $config.Should.ErrorAction.Value | Should -BeExactly 'Stop'
    }

    It 'throws when Path is empty' {
        { New-HDTPesterConfiguration -Path @() } | Should -Throw
    }
}
