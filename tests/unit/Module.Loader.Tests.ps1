BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:modulePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'
    $script:manifestPath = Join-Path -Path $script:modulePath -ChildPath 'Hephaestus.psd1'
    $script:moduleFilePath = Join-Path -Path $script:modulePath -ChildPath 'Hephaestus.psm1'
    Import-Module -Name $script:manifestPath -Force -ErrorAction Stop
}

Describe 'Hephaestus module loader' {

    It 'imports without error' {
        { Import-Module -Name $script:manifestPath -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports exactly the functions named in the manifest' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        $declared = @($data.FunctionsToExport) | Sort-Object
        $actual = @((Get-Module -Name Hephaestus).ExportedFunctions.Keys) | Sort-Object
        ($actual -join ',') | Should -BeExactly ($declared -join ',')
    }

    It 'does not export the private function Test-HDTSchemaVersion' {
        Get-Command -Name Test-HDTSchemaVersion -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'makes private functions callable inside module scope' {
        InModuleScope -ModuleName Hephaestus {
            Test-HDTSchemaVersion -SchemaVersion 1 -Supported 1
        } | Should -BeTrue
    }

    It 'sets StrictMode Latest in the module file' {
        $text = Get-Content -Path $script:moduleFilePath -Raw
        $text | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
    }

    It 'sets $ErrorActionPreference to Stop in the module file' {
        $text = Get-Content -Path $script:moduleFilePath -Raw
        $text | Should -Match "\`$ErrorActionPreference\s*=\s*'Stop'"
    }

    It 'survives a second -Force import' {
        Import-Module -Name $script:manifestPath -Force -ErrorAction Stop
        $first = @((Get-Module -Name Hephaestus).ExportedFunctions.Keys).Count
        Import-Module -Name $script:manifestPath -Force -ErrorAction Stop
        $second = @((Get-Module -Name Hephaestus).ExportedFunctions.Keys).Count
        $second | Should -Be $first
    }
}

Describe 'Hephaestus module loader resilience' {

    AfterAll {
        Remove-Module -Name Hephaestus -Force -ErrorAction SilentlyContinue
        Import-Module -Name $script:manifestPath -Force -ErrorAction Stop
    }

    It 'has a dot-source loader that tolerates a missing Private folder' {
        $copyRoot = Join-Path -Path $TestDrive -ChildPath 'NoPrivate'
        New-Item -Path $copyRoot -ItemType Directory -Force | Out-Null
        Copy-Item -Path $script:modulePath -Destination $copyRoot -Recurse -Force
        $copiedModule = Join-Path -Path $copyRoot -ChildPath 'Hephaestus'
        Remove-Item -Path (Join-Path -Path $copiedModule -ChildPath 'Private') -Recurse -Force
        $copiedManifest = Join-Path -Path $copiedModule -ChildPath 'Hephaestus.psd1'

        { Import-Module -Name $copiedManifest -Force -ErrorAction Stop } | Should -Not -Throw
    }
}
