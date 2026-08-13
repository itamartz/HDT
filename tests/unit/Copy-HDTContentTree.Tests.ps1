# Copy-HDTContentTree copies a source tree into the workspace through the
# injected IFileSystem and nothing else, so importing 4 GB of media is provable
# under Pester with nothing on disk.
#
# It is private, so every assertion runs inside InModuleScope.
#
# A directory is told from a file by GetLength: the real adapter and the fake
# both throw System.IO.FileNotFoundException for a path that is not a file
# (tests/helpers/README.md section 5 - error parity is what makes this legal).
# There is no TestDirectory on IFileSystem, and adding one to copy a tree would
# have widened a service contract 04-01 fixed.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Copy-HDTContentTree' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            'C:\media\Win11\sources\install.wim'         = 'WIM'
            'C:\media\Win11\sources\lang.ini'            = 'LANG'
            'C:\media\Win11\sources\sxs\netfx.cab'       = 'CAB'
            'C:\media\Win11\setup.exe'                   = 'EXE'
        } -Directory @('C:\media\Win11\empty')
    }

    Context 'copying' {

        It 'creates the destination directory' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\ws\OperatingSystems\Win11\sources' -FileSystem $FileSystem

                $FileSystem.TestPath('C:\ws\OperatingSystems\Win11\sources') | Should -BeTrue
            }
        }

        It 'copies every file in the tree' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\ws\os' -FileSystem $FileSystem

                $FileSystem.TestPath('C:\ws\os\setup.exe') | Should -BeTrue
                $FileSystem.TestPath('C:\ws\os\sources\install.wim') | Should -BeTrue
                $FileSystem.TestPath('C:\ws\os\sources\lang.ini') | Should -BeTrue
                $FileSystem.TestPath('C:\ws\os\sources\sxs\netfx.cab') | Should -BeTrue
            }
        }

        It 'preserves the relative structure' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\ws\os' -FileSystem $FileSystem

                $FileSystem.ReadAllText('C:\ws\os\sources\sxs\netfx.cab') | Should -BeExactly 'CAB'
                $FileSystem.TestPath('C:\ws\os\netfx.cab') | Should -BeFalse
            }
        }

        It 'creates an empty directory rather than skipping it' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\ws\os' -FileSystem $FileSystem

                $FileSystem.TestPath('C:\ws\os\empty') | Should -BeTrue
            }
        }

        It 'copies through the injected filesystem only' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\ws\os' -FileSystem $FileSystem

                $operation = @($FileSystem.GetOperationName() | Sort-Object -Unique)

                $operation | Should -Contain 'CreateDirectory'
                $operation | Should -Contain 'GetChildItem'
                $operation | Should -Contain 'CopyItem'
                foreach ($name in $operation) {
                    @('TestPath', 'CreateDirectory', 'GetChildItem', 'GetLength', 'CopyItem') |
                        Should -Contain $name
                }

                Test-Path -LiteralPath 'C:\ws\os' | Should -BeFalse
            }
        }

        It 'returns the number of files it copied' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\ws\os' -FileSystem $FileSystem |
                    Should -Be 4
            }
        }

        It 'copies nothing when the source is empty' {
            InModuleScope Hephaestus {
                $empty = New-HDTFakeFileSystem -Directory @('C:\media\Nothing')

                Copy-HDTContentTree -Source 'C:\media\Nothing' -Destination 'C:\ws\os' -FileSystem $empty |
                    Should -Be 0

                $empty.GetOperationName() | Should -Not -Contain 'CopyItem'
                $empty.TestPath('C:\ws\os') | Should -BeTrue
            }
        }
    }

    Context 'refusals' {

        It 'throws when the source does not exist' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                $record = $null
                try { Copy-HDTContentTree -Source 'C:\media\Absent' -Destination 'C:\ws\os' -FileSystem $FileSystem } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*Absent*'
            }
        }

        It 'refuses to copy a tree into itself' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                # The loop that fills a disk: every pass copies what the previous
                # pass wrote.
                $record = $null
                try { Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\media\Win11\copy' -FileSystem $FileSystem } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $FileSystem.GetOperationName() | Should -Not -Contain 'CopyItem'
            }
        }

        It 'refuses to copy a tree onto itself' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                $record = $null
                try { Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\media\Win11' -FileSystem $FileSystem } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'allows a destination that merely shares a name prefix' {
            InModuleScope Hephaestus -Parameters @{ FileSystem = $script:fileSystem } {
                param($FileSystem)

                # C:\media\Win11-copy is NOT inside C:\media\Win11, and a
                # StartsWith check without a separator would say it was.
                Copy-HDTContentTree -Source 'C:\media\Win11' -Destination 'C:\media\Win11-copy' -FileSystem $FileSystem |
                    Should -Be 4
            }
        }
    }
}
