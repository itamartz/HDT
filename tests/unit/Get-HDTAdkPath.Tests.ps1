# Runtime resolution of every ADK asset the boot image build needs.
#
# PROJECT.md: "Resolve ADK paths at runtime via Get-HDTAdkPath; the layout has
# moved between ADK releases." So this file proves resolution, not a path
# literal - and it proves it on a machine with NO ADK installed, because the
# registry and the filesystem are both injected. Only the last Context touches
# the real one, and it skips itself with a warning where the ADK is absent.
#
# The fake filesystem is seeded from tests/fixtures/adk/adk-layout-10.1.26100.2454.json,
# a real capture of this host's ADK, so a path this file asserts is a path that
# exists somewhere in the world (tests/fixtures/README.md, "captured").

BeforeDiscovery {
    $script:adkInstalled = $false
    try {
        $kitsRoot = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
        $script:adkInstalled = [bool] (Test-Path -LiteralPath (Join-Path -Path $kitsRoot -ChildPath 'Assessment and Deployment Kit') -PathType Container)
    } catch {
        $script:adkInstalled = $false
    }

    if (-not $script:adkInstalled) {
        Write-Warning 'Get-HDTAdkPath: the real-ADK Context is SKIPPED - no Windows Kits\Installed Roots\KitsRoot10 with an Assessment and Deployment Kit under it on this machine.'
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # SPIKES S9.15: a BeforeDiscovery variable is NOT readable from BeforeAll -
    # discovery and run do not share a scope, and under StrictMode reading it
    # throws. Recomputed here rather than borrowed.
    $script:realAdkRoot = ''
    try {
        $kitsRoot = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
        $candidate = Join-Path -Path $kitsRoot -ChildPath 'Assessment and Deployment Kit'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $script:realAdkRoot = $candidate }
    } catch {
        $script:realAdkRoot = ''
    }

    $script:layout = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/adk/adk-layout-10.1.26100.2454.json') -Raw |
        ConvertFrom-Json

    $script:kitsRoot10 = [string] $script:layout.kitsRoot10
    $script:adkRoot = [string] $script:layout.adkRoot

    # A fake filesystem carrying exactly the files the real ADK carries. Seeding
    # a file seeds its parents, so the directories come with it.
    $script:seed = @{}
    foreach ($row in @($script:layout.file)) {
        $script:seed[($script:adkRoot + [string] $row.Path)] = 'fixture'
    }

    function New-HDTAdkTestFileSystem {
        return (New-HDTFakeFileSystem -File $script:seed)
    }

    function New-HDTAdkTestRegistry {
        return (New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' = @{ KitsRoot10 = $script:kitsRoot10 }
            })
    }

    $script:oscdimgDirectory = $script:adkRoot + '\Deployment Tools\amd64\Oscdimg'
    $script:winPeRoot = $script:adkRoot + '\Windows Preinstallation Environment\amd64'
}

Describe 'Get-HDTAdkPath' {

    Context 'the root' {

        It 'reads KitsRoot10 from the 64-bit view' {
            $registry = New-HDTAdkTestRegistry

            Get-HDTAdkPath -Asset Root -Registry $registry -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly $script:adkRoot
        }

        It 'falls back to the 32-bit view when the WOW node has no value' {
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' = @{ KitsRoot10 = $script:kitsRoot10 }
            }

            Get-HDTAdkPath -Asset Root -Registry $registry -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly $script:adkRoot
        }

        It 'prefers an explicit -Root over the registry' {
            $registry = New-HDTAdkTestRegistry

            Get-HDTAdkPath -Asset Root -Root $script:adkRoot -Registry $registry -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly $script:adkRoot

            @($registry.GetOperationName()) | Should -Not -Contain 'GetValue'
        }

        It 'trims the trailing separator KitsRoot10 carries' {
            # The captured value ends '\10\'. A doubled separator in the build
            # manifest is noise, and the manifest records these strings.
            $script:kitsRoot10 | Should -BeLike '*\'

            Get-HDTAdkPath -Asset Root -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -Not -BeLike '*\\Assessment and Deployment Kit'
        }

        It 'throws HDTDependencyError when no key answers' {
            $record = $null
            try {
                Get-HDTAdkPath -Asset Root -Registry (New-HDTFakeRegistryService) -FileSystem (New-HDTAdkTestFileSystem)
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
        }

        It 'names both registry keys in that error' {
            $record = $null
            try {
                Get-HDTAdkPath -Asset Root -Registry (New-HDTFakeRegistryService) -FileSystem (New-HDTAdkTestFileSystem)
            } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*WOW6432Node\Microsoft\Windows Kits\Installed Roots*'
            $record.Exception.Message | Should -BeLike '*KitsRoot10*'
        }

        It 'tells the operator to install the Deployment Tools in that error' {
            $record = $null
            try {
                Get-HDTAdkPath -Asset Root -Registry (New-HDTFakeRegistryService) -FileSystem (New-HDTAdkTestFileSystem)
            } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*Deployment Tools*'
        }
    }

    Context 'the assets' {

        It 'resolves Root' {
            Get-HDTAdkPath -Asset Root -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly $script:adkRoot
        }

        It 'resolves DeploymentTools under the architecture folder' {
            Get-HDTAdkPath -Asset DeploymentTools -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:adkRoot + '\Deployment Tools\amd64')
        }

        It 'resolves OscdimgDirectory' {
            Get-HDTAdkPath -Asset OscdimgDirectory -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly $script:oscdimgDirectory
        }

        It 'resolves Oscdimg' {
            Get-HDTAdkPath -Asset Oscdimg -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:oscdimgDirectory + '\oscdimg.exe')
        }

        It 'resolves EtfsBoot' {
            Get-HDTAdkPath -Asset EtfsBoot -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:oscdimgDirectory + '\etfsboot.com')
        }

        It 'resolves EfiSys' {
            Get-HDTAdkPath -Asset EfiSys -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:oscdimgDirectory + '\efisys.bin')
        }

        It 'resolves EfiSysNoPrompt under Deployment Tools\amd64\Oscdimg' {
            # SPIKES S3: efisys_noprompt.bin lives under Oscdimg, NOT under the
            # WinPE add-on's Media\EFI tree, which holds bootloaders only.
            $path = Get-HDTAdkPath -Asset EfiSysNoPrompt -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem)

            $path | Should -BeExactly ($script:oscdimgDirectory + '\efisys_noprompt.bin')
            $path | Should -BeLike '*\Deployment Tools\amd64\Oscdimg\*'
            $path | Should -Not -BeLike '*Media\EFI*'
        }

        It 'resolves WinPeRoot' {
            Get-HDTAdkPath -Asset WinPeRoot -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly $script:winPeRoot
        }

        It 'resolves WinPeWim under the language folder' {
            Get-HDTAdkPath -Asset WinPeWim -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:winPeRoot + '\en-us\winpe.wim')
        }

        It 'resolves WinPeMedia' {
            Get-HDTAdkPath -Asset WinPeMedia -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:winPeRoot + '\Media')
        }

        It 'resolves WinPeOptionalComponent' {
            Get-HDTAdkPath -Asset WinPeOptionalComponent -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:winPeRoot + '\WinPE_OCs')
        }

        It 'resolves WinPeOptionalComponentLanguage under WinPE_OCs\en-us' {
            Get-HDTAdkPath -Asset WinPeOptionalComponentLanguage -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:winPeRoot + '\WinPE_OCs\en-us')
        }

        It 'honours -Architecture arm64 in every architecture-bearing asset' {
            $architectureBearing = @('DeploymentTools', 'OscdimgDirectory', 'Oscdimg', 'EtfsBoot',
                'EfiSys', 'EfiSysNoPrompt', 'WinPeRoot', 'WinPeWim', 'WinPeMedia',
                'WinPeOptionalComponent', 'WinPeOptionalComponentLanguage')

            foreach ($asset in $architectureBearing) {
                $path = Get-HDTAdkPath -Asset $asset -Architecture arm64 -Registry (New-HDTAdkTestRegistry) `
                    -FileSystem (New-HDTAdkTestFileSystem) -SkipExistenceCheck

                $path | Should -BeLike '*\arm64\*' -Because ("{0} carries the architecture" -f $asset)
                $path | Should -Not -BeLike '*\amd64\*'
            }
        }

        It 'leaves Root alone under -Architecture arm64' {
            Get-HDTAdkPath -Asset Root -Architecture arm64 -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly $script:adkRoot
        }

        It 'honours -Language for the wim and the language OC folder only' {
            $registry = New-HDTAdkTestRegistry

            Get-HDTAdkPath -Asset WinPeWim -Language 'de-de' -Registry $registry -FileSystem (New-HDTAdkTestFileSystem) -SkipExistenceCheck |
                Should -BeExactly ($script:winPeRoot + '\de-de\winpe.wim')

            Get-HDTAdkPath -Asset WinPeOptionalComponentLanguage -Language 'de-de' -Registry $registry -FileSystem (New-HDTAdkTestFileSystem) -SkipExistenceCheck |
                Should -BeExactly ($script:winPeRoot + '\WinPE_OCs\de-de')

            Get-HDTAdkPath -Asset WinPeMedia -Language 'de-de' -Registry $registry -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:winPeRoot + '\Media')

            Get-HDTAdkPath -Asset WinPeOptionalComponent -Language 'de-de' -Registry $registry -FileSystem (New-HDTAdkTestFileSystem) |
                Should -BeExactly ($script:winPeRoot + '\WinPE_OCs')
        }

        It 'refuses an asset outside the closed set' {
            # The set is closed on purpose: an unknown asset is a defect, not a
            # path - exactly as Get-HDTWorkspacePath -Kind is closed. Asserted on
            # the BINDING error, so a command that merely failed to find a path
            # would not satisfy it.
            $record = $null
            try {
                Get-HDTAdkPath -Asset 'Nonesuch' -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem)
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
        }
    }

    Context 'existence' {

        It 'throws when the asset is not on disk' {
            $filesystem = New-HDTFakeFileSystem -Directory @($script:adkRoot)

            { Get-HDTAdkPath -Asset Oscdimg -Registry (New-HDTAdkTestRegistry) -FileSystem $filesystem } |
                Should -Throw
        }

        It 'names the asset, the path and the ADK feature that installs it' {
            $filesystem = New-HDTFakeFileSystem -Directory @($script:adkRoot)

            $record = $null
            try {
                Get-HDTAdkPath -Asset Oscdimg -Registry (New-HDTAdkTestRegistry) -FileSystem $filesystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*Oscdimg*'
            $record.Exception.Message | Should -BeLike ('*' + $script:oscdimgDirectory + '\oscdimg.exe*')
            $record.Exception.Message | Should -BeLike '*Deployment Tools*'
        }

        It 'names the WinPE add-on for a WinPE asset that is absent' {
            $filesystem = New-HDTFakeFileSystem -Directory @($script:adkRoot)

            $record = $null
            try {
                Get-HDTAdkPath -Asset WinPeWim -Registry (New-HDTAdkTestRegistry) -FileSystem $filesystem
            } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*Windows PE add-on*'
        }

        It 'reports a missing asset as HDTDependencyError' {
            $filesystem = New-HDTFakeFileSystem -Directory @($script:adkRoot)

            $record = $null
            try {
                Get-HDTAdkPath -Asset Oscdimg -Registry (New-HDTAdkTestRegistry) -FileSystem $filesystem
            } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
        }

        It 'constructs the path anyway under -SkipExistenceCheck' {
            $filesystem = New-HDTFakeFileSystem -Directory @($script:adkRoot)

            Get-HDTAdkPath -Asset Oscdimg -Registry (New-HDTAdkTestRegistry) -FileSystem $filesystem -SkipExistenceCheck |
                Should -BeExactly ($script:oscdimgDirectory + '\oscdimg.exe')
        }

        It 'checks existence through the injected filesystem, not Test-Path' {
            $filesystem = New-HDTAdkTestFileSystem

            Get-HDTAdkPath -Asset Oscdimg -Registry (New-HDTAdkTestRegistry) -FileSystem $filesystem | Out-Null

            @($filesystem.GetOperationName()) | Should -Contain 'TestPath'
        }

        It 'performs no existence check at all under -SkipExistenceCheck' {
            $filesystem = New-HDTAdkTestFileSystem

            Get-HDTAdkPath -Asset Oscdimg -Registry (New-HDTAdkTestRegistry) -FileSystem $filesystem -SkipExistenceCheck | Out-Null

            @($filesystem.GetOperationName()) | Should -Not -Contain 'TestPath'
        }
    }

    Context '-All' {

        It 'returns one row per asset' {
            # Read from the parameter's own ValidateSet, so the table and the
            # command cannot drift apart without this going red.
            $validValue = @((Get-Command -Name Get-HDTAdkPath).Parameters['Asset'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                    ForEach-Object { $_.ValidValues })

            $row = @(Get-HDTAdkPath -All -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem))

            $validValue.Count | Should -BeGreaterThan 0
            $row.Count | Should -Be $validValue.Count
        }

        It 'returns rows in the documented order' {
            $row = @(Get-HDTAdkPath -All -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem))

            @($row | ForEach-Object { $_.Name }) | Should -Be @(
                'Root', 'DeploymentTools', 'OscdimgDirectory', 'Oscdimg', 'EtfsBoot',
                'EfiSys', 'EfiSysNoPrompt', 'WinPeRoot', 'WinPeWim', 'WinPeMedia',
                'WinPeOptionalComponent', 'WinPeOptionalComponentLanguage')
        }

        It 'carries Name, Path and Exists on every row' {
            $row = @(Get-HDTAdkPath -All -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem))

            foreach ($item in $row) {
                @($item.PSObject.Properties.Name) | Should -Be @('Name', 'Path', 'Exists')
            }
        }

        It 'reports Exists true for every asset this ADK carries' {
            $row = @(Get-HDTAdkPath -All -Registry (New-HDTAdkTestRegistry) -FileSystem (New-HDTAdkTestFileSystem))

            @($row | Where-Object { -not $_.Exists }) | Should -BeNullOrEmpty
        }

        It 'reports Exists false rather than throwing for a missing asset' {
            $filesystem = New-HDTFakeFileSystem -Directory @($script:adkRoot)

            $row = $null
            { $row = @(Get-HDTAdkPath -All -Registry (New-HDTAdkTestRegistry) -FileSystem $filesystem) } | Should -Not -Throw

            @($row | Where-Object { $_.Name -eq 'Oscdimg' }).Exists | Should -BeFalse
            @($row | Where-Object { $_.Name -eq 'Root' }).Exists | Should -BeTrue
        }
    }

    Context 'the real ADK on this machine' -Skip:(-not $script:adkInstalled) {

        It 'finds oscdimg.exe' {
            $script:realAdkRoot | Should -Not -BeNullOrEmpty

            $path = Get-HDTAdkPath -Asset Oscdimg
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }

        It 'finds efisys_noprompt.bin' {
            $path = Get-HDTAdkPath -Asset EfiSysNoPrompt

            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
            $path | Should -BeLike '*\Oscdimg\efisys_noprompt.bin'
        }

        It 'finds winpe.wim' {
            Test-Path -LiteralPath (Get-HDTAdkPath -Asset WinPeWim) -PathType Leaf | Should -BeTrue
        }

        It 'finds the WinPE_OCs folder' {
            Test-Path -LiteralPath (Get-HDTAdkPath -Asset WinPeOptionalComponent) -PathType Container | Should -BeTrue
        }

        It 'reports the winpe.wim this machine actually has' {
            # 340 134 390 bytes on ADK 10.1.26100.2454. A different number means
            # the ADK moved, and the fixture must be recaptured rather than the
            # assertion relaxed.
            (Get-Item -LiteralPath (Get-HDTAdkPath -Asset WinPeWim)).Length | Should -Be 340134390
        }

        It 'reports Exists true for every asset under -All' {
            $row = @(Get-HDTAdkPath -All)

            @($row | Where-Object { -not $_.Exists } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
        }
    }
}
