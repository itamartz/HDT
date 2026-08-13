# Get-HDTOperatingSystem reads a catalog entry back out of the workspace and
# resolves its image to a full path.
#
# THE RESOLVED PATH IS THE SEAM M4 REPLACES. DESIGN 6 abstracts content access
# behind Resolve-Content / Copy-Content / Test-Content, and M4 ships the Smb and
# Local providers. Until then this resolves an image path from the workspace root
# it is given, which is exactly what a provider would return for Local. When M4
# lands, ApplyImage changes from "ask the catalog" to "ask the provider" and no
# step logic moves.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:osFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/os'
    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\Share'
    $script:catalogPath = 'C:\HDTLab\does-not-exist\Share\OperatingSystems\Win11-LTSC-2024\os.yaml'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:osFixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }
}

Describe 'Get-HDTOperatingSystem' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            $script:catalogPath = $script:fixture['valid-win11-ltsc.yaml']
        }
    }

    Context 'reading the catalog' {

        It 'returns the catalog for an id' {
            $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $script:fileSystem

            $catalog.Id | Should -BeExactly 'Win11-LTSC-2024'
            $catalog.Name | Should -BeExactly 'Windows 11 Enterprise LTSC 2024'
            $catalog.Type | Should -BeExactly 'wim'
            $catalog.DefaultIndex | Should -Be 1
        }

        It 'reads through the injected filesystem' {
            $null = Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $script:fileSystem

            $script:fileSystem.GetOperationName() | Should -Contain 'ReadAllText'
            Test-Path -LiteralPath $script:catalogPath | Should -BeFalse
        }

        It 'returns every image the catalog carries' {
            $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $script:fileSystem

            @($catalog.Images | ForEach-Object { $_.Index }) | Should -Be @(1, 2)
            @($catalog.Images | ForEach-Object { $_.Edition }) | Should -Be @('EnterpriseS', 'EnterpriseSN')
            $catalog.Images[0].SizeBytes | Should -Be 18356832906
        }

        It 'returns images Resolve-HDTImageIndex can resolve' {
            $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $script:fileSystem

            (Resolve-HDTImageIndex -Image $catalog.Images -Edition 'EnterpriseS').Index | Should -Be 1
        }
    }

    Context 'resolving the image path' {

        It 'resolves ImagePath to a full path under the workspace' {
            $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $script:fileSystem

            $catalog.ImagePath | Should -BeExactly 'C:\HDTLab\does-not-exist\Share\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }

        It 'keeps a rooted sourcePath as it is' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\HDTLab\does-not-exist\Share\OperatingSystems\Win11-FFU\os.yaml' = $script:fixture['valid-ffu.yaml']
            }

            $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-FFU' -FileSystem $fileSystem

            $catalog.ImagePath | Should -BeExactly 'D:\Captures\surface.ffu'
        }

        It 'resolves a UNC workspace root' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                '\\contoso\HdtShare\OperatingSystems\Win11-LTSC-2024\os.yaml' = $script:fixture['valid-win11-ltsc.yaml']
            }

            $catalog = Get-HDTOperatingSystem -WorkspaceRoot '\\contoso\HdtShare' -Id 'Win11-LTSC-2024' -FileSystem $fileSystem

            $catalog.ImagePath | Should -BeExactly '\\contoso\HdtShare\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }
    }

    Context 'refusals' {

        It 'throws HDTConfigurationError naming the id when no catalog exists' {
            $empty = New-HDTFakeFileSystem

            $record = $null
            try { Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-Absent' -FileSystem $empty } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Win11-Absent*'
        }

        It 'reports a malformed catalog as a configuration error naming the file' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                $script:catalogPath = $script:fixture['invalid-missing-id.yaml']
            }

            $record = $null
            try { Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $fileSystem } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*os.yaml*'
        }

        It 'reports unparseable YAML with the line' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                $script:catalogPath = $script:fixture['unparseable-indentation.yaml']
            }

            $record = $null
            try { Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $fileSystem } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*os.yaml(*'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Get-HDTOperatingSystem -ErrorAction Stop

            $help.Name | Should -BeExactly 'Get-HDTOperatingSystem'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
