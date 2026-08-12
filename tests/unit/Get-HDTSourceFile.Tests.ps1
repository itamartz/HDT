BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $helperManifest = Join-Path -Path $repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name $helperManifest -Force -ErrorAction Stop
}

Describe 'Get-HDTSourceFile' {

    BeforeAll {
        $fakeRepo = Join-Path -Path $TestDrive -ChildPath 'repo'
        New-Item -Path $fakeRepo -ItemType Directory -Force | Out-Null

        $relativePaths = @(
            'build.ps1'
            'src/Hephaestus/Hephaestus.psm1'
            'src/Hephaestus/Hephaestus.psd1'
            'src/Hephaestus/Public/Get-HDTThing.ps1'
            'src/Hephaestus/Private/Test-HDTThing.ps1'
            'src/HDT.Console/bin/Debug/Generated.ps1'
            'src/HDT.Console/obj/Generated.ps1'
            'tests/unit/Sample.Tests.ps1'
            'tests/helpers/HDTTestTools/HDTTestTools.psm1'
            'tests/helpers/HDTTestTools/HDTTestTools.psd1'
            'tests/fixtures/workspace/Broken.ps1'
            'out/Hephaestus/0.1.0/Hephaestus.psm1'
            'docs/Snippet.ps1'
        )
        foreach ($relativePath in $relativePaths) {
            $fullPath = Join-Path -Path $fakeRepo -ChildPath $relativePath
            $parentPath = Split-Path -Parent $fullPath
            if (-not (Test-Path -Path $parentPath)) {
                New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
            }
            Set-Content -Path $fullPath -Value '# placeholder' -Encoding ASCII
        }

        $result = @(Get-HDTSourceFile -RepositoryRoot $fakeRepo)
        $relative = @($result | ForEach-Object {
                $_.Substring($fakeRepo.Length).TrimStart('\', '/').Replace('\', '/')
            })
    }

    It 'returns .ps1 files under src' {
        $relative | Should -Contain 'src/Hephaestus/Public/Get-HDTThing.ps1'
        $relative | Should -Contain 'src/Hephaestus/Private/Test-HDTThing.ps1'
    }

    It 'returns .psm1 files under src' {
        $relative | Should -Contain 'src/Hephaestus/Hephaestus.psm1'
    }

    It 'returns build.ps1 from the repository root' {
        $relative | Should -Contain 'build.ps1'
    }

    It 'returns .ps1 files under tests' {
        $relative | Should -Contain 'tests/unit/Sample.Tests.ps1'
    }

    It 'returns .psm1 files under tests' {
        $relative | Should -Contain 'tests/helpers/HDTTestTools/HDTTestTools.psm1'
    }

    It 'excludes anything under tests/fixtures' {
        $relative | Should -Not -Contain 'tests/fixtures/workspace/Broken.ps1'
    }

    It 'excludes .psd1 manifests' {
        @($relative | Where-Object { $_ -like '*.psd1' }).Count | Should -Be 0
    }

    It 'excludes the out directory' {
        $relative | Should -Not -Contain 'out/Hephaestus/0.1.0/Hephaestus.psm1'
    }

    It 'excludes bin and obj directories' {
        $relative | Should -Not -Contain 'src/HDT.Console/bin/Debug/Generated.ps1'
        $relative | Should -Not -Contain 'src/HDT.Console/obj/Generated.ps1'
    }

    It 'ignores PowerShell files outside src, tests and the root build.ps1' {
        $relative | Should -Not -Contain 'docs/Snippet.ps1'
    }

    It 'returns absolute paths' {
        $result.Count | Should -BeGreaterThan 0
        foreach ($path in $result) {
            [System.IO.Path]::IsPathRooted($path) | Should -BeTrue
        }
    }

    It 'returns a sorted, duplicate-free list' {
        ($result -join '|') | Should -BeExactly ((@($result) | Sort-Object) -join '|')
        @($result | Select-Object -Unique).Count | Should -Be $result.Count
    }

    It 'throws when RepositoryRoot does not exist' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-repository'
        { Get-HDTSourceFile -RepositoryRoot $missing } | Should -Throw
    }

    It 'finds at least one file in the real repository' {
        @(Get-HDTSourceFile -RepositoryRoot $repoRoot).Count | Should -BeGreaterThan 0
    }
}
