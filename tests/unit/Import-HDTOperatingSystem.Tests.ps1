# DESIGN 9.3: "Import-HDTOperatingSystem promotes a capture into the OS catalog."
# DESIGN 2.1 fixes where it lands: OperatingSystems\<id>\os.yaml.
#
# THE IMAGE LIST IS READ FROM THE WIM, NEVER TYPED BY HAND. A catalog whose
# indices an author entered is a catalog that lies the first time the media is
# rebuilt, and it lies to the step that decides what to apply. It comes through
# IImageService.GetImageInfo, so the importer is provable with no WIM present.
#
# Every path is built with Get-HDTWorkspacePath. That command exists because a
# plan once did not: Start-HDTResume built its path from the literal 'Sequences'
# while the layout said 'TaskSequences', the unit suite was green, and a
# deployment would have died at its first reboot.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:imageFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image'

    # F12: assign first, wrap second.
    $text = Get-Content -LiteralPath (Join-Path -Path $script:imageFixtureRoot -ChildPath 'win11-ltsc-2024-install.json') -Raw
    $content = ConvertFrom-Json -InputObject $text
    $script:win11 = [object[]] @($content)

    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\Share'
    $script:sourcePath = 'C:\media\Win11-LTSC-2024\sources\install.wim'
    $script:catalogPath = 'C:\HDTLab\does-not-exist\Share\OperatingSystems\Win11-LTSC-2024\os.yaml'
}

Describe 'Import-HDTOperatingSystem' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            $script:sourcePath                                     = 'WIM'
            'C:\media\Win11-LTSC-2024\sources\lang.ini'            = 'LANG'
            'C:\media\Win11-LTSC-2024\setup.exe'                   = 'EXE'
        }

        $script:imageService = New-HDTFakeImageService -Image @{ $script:sourcePath = $script:win11 }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::SpecifyKind([datetime]::Parse('2026-08-13T09:14:22'), 'Utc'))
    }

    Context 'reading the source' {

        It 'reads the image list through the injected image service' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $script:imageService.GetOperationName() | Should -Contain 'GetImageInfo'
        }

        It 'records every index the WIM carries' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            @($catalog.Images | ForEach-Object { $_.Index }) | Should -Be @(1, 2)
        }

        It 'records the edition of each index' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            @($catalog.Images | ForEach-Object { $_.Edition }) | Should -Be @('EnterpriseS', 'EnterpriseSN')
        }

        It 'throws when the source image does not exist' {
            $record = $null
            try {
                Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                    -SourcePath 'C:\media\absent\install.wim' -FileSystem $script:fileSystem `
                    -ImageService $script:imageService -Clock $script:clock
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*install.wim*'
        }

        It 'refuses an id that is not a legal folder name' {
            $record = $null
            try {
                Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id '../escape' `
                    -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                    -ImageService $script:imageService -Clock $script:clock
            } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'writing the catalog' {

        # The name carries no angle brackets: Pester expands <name> in an It
        # title as a data variable, and 'OperatingSystems\<id>' made the whole
        # test fail with "the variable $id has not been set".
        It 'writes os.yaml under the OperatingSystems folder for the id' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $script:fileSystem.TestPath($script:catalogPath) | Should -BeTrue
        }

        It 'builds that path with Get-HDTWorkspacePath' {
            # A UNC root, so a literal 'OperatingSystems' concatenated by hand
            # would produce a visibly different path.
            $unc = '\\contoso\HdtShare'
            $expected = Get-HDTWorkspacePath -Root $unc -Kind OperatingSystems -ChildPath 'Win11-LTSC-2024', 'os.yaml'

            $null = Import-HDTOperatingSystem -WorkspaceRoot $unc -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $script:fileSystem.TestPath($expected) | Should -BeTrue
        }

        It 'writes through the injected filesystem' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $script:fileSystem.GetOperationName() | Should -Contain 'WriteAllText'
            Test-Path -LiteralPath $script:catalogPath | Should -BeFalse
        }

        It 'stamps importedUtc from the injected clock' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $script:clock.GetOperationName() | Should -Contain 'GetUtcNow'
            $catalog.ImportedUtc | Should -BeLike '2026-08-13T09:14:22*'
        }

        It 'records the source path as given when nothing is copied' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $catalog.SourcePath | Should -BeExactly $script:sourcePath
        }

        It 'defaults the name to the id' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $catalog.Name | Should -BeExactly 'Win11-LTSC-2024'
        }

        It 'keeps an explicit name and description' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock `
                -Name 'Windows 11 Enterprise LTSC 2024' -Description 'Staged from the volume licence media'

            $catalog.Name | Should -BeExactly 'Windows 11 Enterprise LTSC 2024'
            $catalog.Description | Should -BeExactly 'Staged from the volume licence media'
        }

        It 'records the schema version' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $catalog.SchemaVersion | Should -Be 1
        }

        It 'records the type as wim for a .wim source' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $catalog.Type | Should -BeExactly 'wim'
        }

        It 'records the type as ffu for a .ffu source' {
            $fileSystem = New-HDTFakeFileSystem -File @{ 'D:\Captures\surface.ffu' = 'FFU' }
            $imageService = New-HDTFakeImageService -Image @{ 'D:\Captures\surface.ffu' = $script:win11 }

            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Surface-FFU' `
                -SourcePath 'D:\Captures\surface.ffu' -FileSystem $fileSystem `
                -ImageService $imageService -Clock $script:clock

            $catalog.Type | Should -BeExactly 'ffu'
        }

        It 'writes a document Assert-HDTOperatingSystemDocument accepts' {
            # The round trip that keeps the writer and the validator honest.
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $yaml = $script:fileSystem.ReadAllText($script:catalogPath)

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'writes a document Get-HDTOperatingSystem reads back' {
            $written = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $read = Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $script:fileSystem

            $read.Id | Should -BeExactly $written.Id
            $read.Name | Should -BeExactly $written.Name
            $read.Type | Should -BeExactly $written.Type
            $read.SourcePath | Should -BeExactly $written.SourcePath
            @($read.Images | ForEach-Object { $_.Index }) | Should -Be @($written.Images | ForEach-Object { $_.Index })
        }
    }

    Context 'overwriting' {

        It 'refuses to overwrite an existing catalog without -Force' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $record = $null
            try {
                Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                    -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                    -ImageService $script:imageService -Clock $script:clock
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Force*'
        }

        It 'overwrites with -Force' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock -Name 'Second' -Force

            $catalog.Name | Should -BeExactly 'Second'
            (Get-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $script:fileSystem).Name |
                Should -BeExactly 'Second'
        }

        It 'supports -WhatIf and writes nothing' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock -WhatIf

            $script:fileSystem.TestPath($script:catalogPath) | Should -BeFalse
            $script:fileSystem.GetOperationName() | Should -Not -Contain 'WriteAllText'
        }
    }

    Context 'copying' {

        It 'does not copy the source tree by default' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'CopyItem'
        }

        It 'copies the source tree with -Copy' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock -Copy

            $script:fileSystem.TestPath('C:\HDTLab\does-not-exist\Share\OperatingSystems\Win11-LTSC-2024\sources\install.wim') |
                Should -BeTrue
            $script:fileSystem.TestPath('C:\HDTLab\does-not-exist\Share\OperatingSystems\Win11-LTSC-2024\sources\lang.ini') |
                Should -BeTrue
        }

        It 'records a relative sourcePath after copying' {
            $catalog = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock -Copy

            $catalog.SourcePath | Should -BeExactly 'sources\install.wim'
        }

        It 'copies nothing under -WhatIf' {
            $null = Import-HDTOperatingSystem -WorkspaceRoot $script:workspaceRoot -Id 'Win11-LTSC-2024' `
                -SourcePath $script:sourcePath -FileSystem $script:fileSystem `
                -ImageService $script:imageService -Clock $script:clock -Copy -WhatIf

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'CopyItem'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Import-HDTOperatingSystem -ErrorAction Stop

            $help.Name | Should -BeExactly 'Import-HDTOperatingSystem'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }

        It 'declares SupportsShouldProcess' {
            $command = Get-Command -Name Import-HDTOperatingSystem -ErrorAction Stop

            $command.Name | Should -BeExactly 'Import-HDTOperatingSystem'
            $command.Parameters.Keys | Should -Contain 'WhatIf'
        }
    }
}
