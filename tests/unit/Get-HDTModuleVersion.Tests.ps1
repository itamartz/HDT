BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifestPath = Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    Import-Module -Name $manifestPath -Force -ErrorAction Stop
}

Describe 'Get-HDTModuleVersion' {

    It 'returns a [version] object' {
        Get-HDTModuleVersion | Should -BeOfType ([version])
    }

    It 'returns the version declared in the manifest' {
        $declared = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
        Get-HDTModuleVersion | Should -Be ([version] $declared)
    }

    It 'takes no mandatory parameters' {
        $command = Get-Command -Name Get-HDTModuleVersion
        $mandatory = @(
            $command.Parameters.Values |
                Where-Object {
                    @($_.Attributes | Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
                        }).Count -gt 0
                }
        )
        $mandatory.Count | Should -Be 0
    }

    It 'has comment-based help with a synopsis' {
        $synopsis = (Get-Help -Name Get-HDTModuleVersion).Synopsis
        $synopsis | Should -Not -BeNullOrEmpty
        $synopsis.Trim() | Should -Not -BeExactly 'Get-HDTModuleVersion'
    }
}
