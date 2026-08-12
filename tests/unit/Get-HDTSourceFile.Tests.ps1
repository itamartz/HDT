BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:helperManifest = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name $script:helperManifest -Force -ErrorAction Stop
}

Describe 'Get-HDTSourceFile' {

    BeforeAll {
        $script:fakeRepo = Join-Path -Path $TestDrive -ChildPath 'repo'
        New-Item -Path $script:fakeRepo -ItemType Directory -Force | Out-Null

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
            $fullPath = Join-Path -Path $script:fakeRepo -ChildPath $relativePath
            $parentPath = Split-Path -Parent $fullPath
            if (-not (Test-Path -Path $parentPath)) {
                New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
            }
            Set-Content -Path $fullPath -Value '# placeholder' -Encoding ASCII
        }

        $script:result = @(Get-HDTSourceFile -RepositoryRoot $script:fakeRepo)
        $script:relative = @($script:result | ForEach-Object {
                $_.Substring($script:fakeRepo.Length).TrimStart('\', '/').Replace('\', '/')
            })
    }

    It 'returns .ps1 files under src' {
        $script:relative | Should -Contain 'src/Hephaestus/Public/Get-HDTThing.ps1'
        $script:relative | Should -Contain 'src/Hephaestus/Private/Test-HDTThing.ps1'
    }

    It 'returns .psm1 files under src' {
        $script:relative | Should -Contain 'src/Hephaestus/Hephaestus.psm1'
    }

    It 'returns build.ps1 from the repository root' {
        $script:relative | Should -Contain 'build.ps1'
    }

    It 'returns .ps1 files under tests' {
        $script:relative | Should -Contain 'tests/unit/Sample.Tests.ps1'
    }

    It 'returns .psm1 files under tests' {
        $script:relative | Should -Contain 'tests/helpers/HDTTestTools/HDTTestTools.psm1'
    }

    It 'excludes anything under tests/fixtures' {
        $script:relative | Should -Not -Contain 'tests/fixtures/workspace/Broken.ps1'
    }

    It 'excludes .psd1 manifests' {
        @($script:relative | Where-Object { $_ -like '*.psd1' }).Count | Should -Be 0
    }

    It 'excludes the out directory' {
        $script:relative | Should -Not -Contain 'out/Hephaestus/0.1.0/Hephaestus.psm1'
    }

    It 'excludes bin and obj directories' {
        $script:relative | Should -Not -Contain 'src/HDT.Console/bin/Debug/Generated.ps1'
        $script:relative | Should -Not -Contain 'src/HDT.Console/obj/Generated.ps1'
    }

    It 'ignores PowerShell files outside src, tests and the root build.ps1' {
        $script:relative | Should -Not -Contain 'docs/Snippet.ps1'
    }

    It 'returns absolute paths' {
        $script:result.Count | Should -BeGreaterThan 0
        foreach ($path in $script:result) {
            [System.IO.Path]::IsPathRooted($path) | Should -BeTrue
        }
    }

    It 'returns a sorted, duplicate-free list' {
        ($script:result -join '|') | Should -BeExactly ((@($script:result) | Sort-Object) -join '|')
        @($script:result | Select-Object -Unique).Count | Should -Be $script:result.Count
    }

    It 'throws when RepositoryRoot does not exist' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-repository'
        { Get-HDTSourceFile -RepositoryRoot $missing } | Should -Throw
    }

    It 'finds at least one file in the real repository' {
        @(Get-HDTSourceFile -RepositoryRoot $script:repoRoot).Count | Should -BeGreaterThan 0
    }
}
