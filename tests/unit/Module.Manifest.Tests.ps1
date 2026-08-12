BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:modulePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'
    $script:manifestPath = Join-Path -Path $script:modulePath -ChildPath 'Hephaestus.psd1'
    $script:publicPath = Join-Path -Path $script:modulePath -ChildPath 'Public'
}

Describe 'Hephaestus module manifest' {

    It 'exists at src/Hephaestus/Hephaestus.psd1' {
        Test-Path -Path $script:manifestPath -PathType Leaf | Should -BeTrue
    }

    It 'passes Test-ModuleManifest' {
        { Test-ModuleManifest -Path $script:manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'declares RootModule Hephaestus.psm1' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        $data.RootModule | Should -BeExactly 'Hephaestus.psm1'
    }

    It 'requires PowerShell 5.1' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        $data.PowerShellVersion | Should -BeExactly '5.1'
    }

    It 'declares both PS editions' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        $data.CompatiblePSEditions | Should -Contain 'Desktop'
        $data.CompatiblePSEditions | Should -Contain 'Core'
    }

    It 'exports functions explicitly, never a wildcard' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        $data.FunctionsToExport | Should -BeOfType ([string])
        @($data.FunctionsToExport) -notcontains '*' | Should -BeTrue
        @($data.FunctionsToExport).Count | Should -BeGreaterThan 0
    }

    It 'exports no cmdlets, aliases or variables' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        @($data.CmdletsToExport).Count | Should -Be 0
        @($data.AliasesToExport).Count | Should -Be 0
        @($data.VariablesToExport).Count | Should -Be 0
    }

    It 'lists exactly one exported function per file in Public' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        $exported = @($data.FunctionsToExport) | Sort-Object
        $onDisk = @(Get-ChildItem -Path $script:publicPath -Filter '*.ps1' -Recurse |
            ForEach-Object { $_.BaseName }) | Sort-Object
        @($onDisk).Count | Should -BeGreaterThan 0
        ($exported -join ',') | Should -BeExactly ($onDisk -join ',')
    }

    It 'has a valid GUID' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        { [guid]::Parse($data.GUID) } | Should -Not -Throw
    }

    It 'does not use DefaultCommandPrefix' {
        $data = Import-PowerShellDataFile -Path $script:manifestPath
        $data.ContainsKey('DefaultCommandPrefix') | Should -BeFalse
    }
}
