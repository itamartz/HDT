# The list of cabs Update-HDTBootImage will apply, decided before anything is
# mounted: SPIKES S1's verified order, merged with what the admin declared,
# dependency-validated, and existence-checked.
#
# 05-04 mounts a 340 MB WIM and applies nine cabs to it - fifteen minutes and an
# elevated session. Everything decidable before that run is decided here, against
# a fake seeded from tests/fixtures/adk/winpe-ocs-amd64.json, in seconds.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:componentRoot = 'C:\Adk\WinPE_OCs'

    # ConvertFrom-Json DOES NOT ENUMERATE ITS ARRAY UNDER WINDOWS POWERSHELL 5.1
    # (04-04 hit this and recorded it). @(... | ConvertFrom-Json) there yields
    # ONE element that is the whole Object[], so $row.Name silently becomes an
    # array of 33 names and the seeded path is 'System.Object[].cab'. Parsing
    # first and enumerating through the pipeline behaves the same on both
    # editions.
    $script:ocParsed = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/adk/winpe-ocs-amd64.json') -Raw |
        ConvertFrom-Json
    $script:ocFixture = @($script:ocParsed | ForEach-Object { $_ })

    # SPIKES S1's order, the one that booted. Written out here so a reordering of
    # the shipped constant has to be argued with this file.
    $script:requiredOrder = @('WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting',
        'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets')

    function New-HDTComponentTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter()]
            [string[]] $ExtraComponent
        )

        $seed = @{}
        foreach ($row in $script:ocFixture) {
            $seed[('{0}\{1}.cab' -f $script:componentRoot, $row.Name)] = 'cab'

            if ($row.HasEnUs) {
                $seed[('{0}\en-us\{1}_en-us.cab' -f $script:componentRoot, $row.Name)] = 'cab'
            }
        }

        foreach ($name in @($ExtraComponent)) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $seed[('{0}\{1}.cab' -f $script:componentRoot, $name)] = 'cab'
            $seed[('{0}\en-us\{1}_en-us.cab' -f $script:componentRoot, $name)] = 'cab'
        }

        return (New-HDTFakeFileSystem -File $seed)
    }
}

Describe 'Get-HDTBootImageComponent' {

    Context 'the required set' {

        It 'returns the six required components first, in SPIKES S1 order' {
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | Where-Object { $_.Required } | ForEach-Object { $_.Name }) | Should -Be $script:requiredOrder
        }

        It 'puts them at the head of the list, whatever else is in it' {
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | Select-Object -First 6 | ForEach-Object { $_.Name }) | Should -Be $script:requiredOrder
        }

        It 'spells NetFx with a lowercase x' {
            # DESIGN 5.1's named trap: an earlier draft wrote WinPE-NetFX and the
            # cab of that name does not exist. Its own It, so the failure says
            # which mistake was made.
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))
            $name = @($row | ForEach-Object { $_.Name })

            # -ceq, not Should -Contain: Pester's -Contain compares without
            # regard to case, so it would happily accept the very spelling this
            # test exists to refuse.
            @($name | Where-Object { $_ -ceq 'WinPE-NetFx' }).Count | Should -Be 1
            @($name | Where-Object { $_ -ceq 'WinPE-NetFX' }) | Should -BeNullOrEmpty

            # And the cab it will look for carries that spelling too.
            @($row | Where-Object { $_.Name -eq 'WinPE-NetFx' })[0].CabPath |
                Should -BeExactly ('{0}\WinPE-NetFx.cab' -f $script:componentRoot)
        }

        It 'marks exactly six components Required' {
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | Where-Object { $_.Required }).Count | Should -Be 6
        }

        It 'numbers Order from one with no gaps' {
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | ForEach-Object { $_.Order }) | Should -Be @(1..$row.Count)
        }

        It 'carries Order, Name, Required, CabPath and LanguageCabPath on every row' {
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            foreach ($item in $row) {
                @($item.PSObject.Properties.Name) | Should -Be @('Order', 'Name', 'Required', 'CabPath', 'LanguageCabPath')
            }
        }
    }

    Context 'the defaults' {

        It 'adds SecureStartup, EnhancedStorage and WDS-Tools when none were declared' {
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | ForEach-Object { $_.Name }) | Should -Be @(
                'WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell',
                'WinPE-StorageWMI', 'WinPE-DismCmdlets',
                'WinPE-SecureStartup', 'WinPE-EnhancedStorage', 'WinPE-WDS-Tools')
        }

        It 'adds nothing beyond the six for an explicit empty array' {
            # Unset and set-to-nothing are different instructions.
            $row = @(Get-HDTBootImageComponent -OptionalComponent @() -ComponentRoot $script:componentRoot `
                    -FileSystem (New-HDTComponentTestFileSystem))

            @($row | ForEach-Object { $_.Name }) | Should -Be $script:requiredOrder
        }
    }

    Context 'merging what the admin declared' {

        It 'keeps the declared order of the extras' {
            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-WDS-Tools', 'WinPE-HTA', 'WinPE-SecureStartup') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | Where-Object { -not $_.Required } | ForEach-Object { $_.Name }) |
                Should -Be @('WinPE-WDS-Tools', 'WinPE-HTA', 'WinPE-SecureStartup')
        }

        It 'never lets a declared component reorder the six' {
            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-HTA', 'WinPE-WMI') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            $row[0].Name | Should -BeExactly 'WinPE-WMI'
            @($row | Where-Object { $_.Name -eq 'WinPE-WMI' }).Count | Should -Be 1
        }

        It 'drops a declared component that is already required' {
            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-Scripting') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | ForEach-Object { $_.Name }) | Should -Be $script:requiredOrder
        }

        It 'matches component names case-insensitively' {
            $row = @(Get-HDTBootImageComponent -OptionalComponent @('winpe-scripting', 'WINPE-HTA', 'winpe-hta') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | Where-Object { -not $_.Required }).Count | Should -Be 1
        }

        It 'accepts a component this project has never heard of' {
            # DESIGN 5.1's whole point: a fleet needs components this project
            # never anticipated. No warning, no refusal, no table entry.
            $filesystem = New-HDTComponentTestFileSystem -ExtraComponent 'WinPE-VendorThing'

            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-VendorThing') `
                    -ComponentRoot $script:componentRoot -FileSystem $filesystem -WarningVariable warning)

            @($row | ForEach-Object { $_.Name }) | Should -Contain 'WinPE-VendorThing'
            @($warning) | Should -BeNullOrEmpty
        }
    }

    Context 'dependency validation' {

        It 'refuses a component whose dependency is absent' {
            # The RULE is proven against an INJECTED table of two rows nobody has
            # to believe. Inventing a Microsoft dependency in order to produce a
            # refusal would refuse builds that work, in the name of documentation
            # that does not say so.
            $filesystem = New-HDTComponentTestFileSystem -ExtraComponent @('WinPE-VendorRadio', 'WinPE-VendorBase')
            $table = @{ 'WinPE-VendorRadio' = @{ Requires = @('WinPE-VendorBase'); Source = 'this test' } }

            { Get-HDTBootImageComponent -OptionalComponent @('WinPE-VendorRadio') -ComponentRoot $script:componentRoot `
                    -FileSystem $filesystem -Dependency $table } | Should -Throw
        }

        It 'names both components and points at optionalComponents in that refusal' {
            $filesystem = New-HDTComponentTestFileSystem -ExtraComponent @('WinPE-VendorRadio', 'WinPE-VendorBase')
            $table = @{ 'WinPE-VendorRadio' = @{ Requires = @('WinPE-VendorBase'); Source = 'this test' } }

            $record = $null
            try {
                Get-HDTBootImageComponent -OptionalComponent @('WinPE-VendorRadio') -ComponentRoot $script:componentRoot `
                    -FileSystem $filesystem -Dependency $table
            } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*WinPE-VendorRadio*'
            $record.Exception.Message | Should -BeLike '*WinPE-VendorBase*'
            $record.Exception.Message | Should -BeLike '*optionalComponents*'
        }

        It 'accepts the same declaration once the dependency is declared too' {
            $filesystem = New-HDTComponentTestFileSystem -ExtraComponent @('WinPE-VendorRadio', 'WinPE-VendorBase')
            $table = @{ 'WinPE-VendorRadio' = @{ Requires = @('WinPE-VendorBase'); Source = 'this test' } }

            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-VendorBase', 'WinPE-VendorRadio') `
                    -ComponentRoot $script:componentRoot -FileSystem $filesystem -Dependency $table)

            @($row | ForEach-Object { $_.Name }) | Should -Contain 'WinPE-VendorRadio'
        }

        It 'inserts nothing on the admin behalf' {
            # An admin who is told gets a boot image they understand. HDT does
            # not quietly add the dependency.
            $filesystem = New-HDTComponentTestFileSystem -ExtraComponent @('WinPE-VendorRadio', 'WinPE-VendorBase')
            $table = @{ 'WinPE-VendorRadio' = @{ Requires = @('WinPE-VendorBase'); Source = 'this test' } }

            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-VendorBase', 'WinPE-VendorRadio') `
                    -ComponentRoot $script:componentRoot -FileSystem $filesystem -Dependency $table)

            @($row | ForEach-Object { $_.Name }) | Should -Be @(
                'WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell',
                'WinPE-StorageWMI', 'WinPE-DismCmdlets',
                'WinPE-VendorBase', 'WinPE-VendorRadio')
        }

        It 'uses the shipped table when none is injected' {
            # WinPE-Setup-Client declares WinPE-Setup as its parent in its own
            # package manifest, and both are optional - so this is a refusal the
            # SHIPPED table can produce, and it is cited rather than invented.
            $record = $null
            try {
                Get-HDTBootImageComponent -OptionalComponent @('WinPE-Setup-Client') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem)
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*WinPE-Setup*'
        }

        It 'accepts WinPE-Setup-Client once WinPE-Setup is declared too' {
            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-Setup', 'WinPE-Setup-Client') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            @($row | ForEach-Object { $_.Name }) | Should -Contain 'WinPE-Setup-Client'
        }

        It 'ships a dependency table in which every row cites a source' {
            # A table with no provenance is a table the next author extends by
            # guessing.
            InModuleScope Hephaestus {
                $table = Get-HDTBootImageComponentDependency

                @($table.Keys).Count | Should -BeGreaterThan 0

                foreach ($key in @($table.Keys)) {
                    $table[$key].Source | Should -Not -BeNullOrEmpty -Because ("{0} must say where its dependency came from" -f $key)
                    @($table[$key].Requires).Count | Should -BeGreaterThan 0
                }
            }
        }

        It 'ships a table whose every dependency is a real component of this ADK' {
            $known = @($script:ocFixture | ForEach-Object { $_.Name })

            InModuleScope Hephaestus -Parameters @{ Known = $known } {
                param($Known)

                $table = Get-HDTBootImageComponentDependency

                foreach ($key in @($table.Keys)) {
                    $Known | Should -Contain $key
                    foreach ($requirement in @($table[$key].Requires)) {
                        $Known | Should -Contain $requirement
                    }
                }
            }
        }

        It 'ships a required set that already satisfies every dependency it declares' {
            # SPIKES S1's order was arrived at by booting a machine, not by
            # reading manifests. This asserts the two agree.
            $row = @(Get-HDTBootImageComponent -OptionalComponent @() -ComponentRoot $script:componentRoot `
                    -FileSystem (New-HDTComponentTestFileSystem))

            $name = @($row | ForEach-Object { $_.Name })

            InModuleScope Hephaestus -Parameters @{ Name = $name } {
                param($Name)

                $table = Get-HDTBootImageComponentDependency

                foreach ($current in $Name) {
                    if (-not $table.ContainsKey($current)) { continue }

                    foreach ($requirement in @($table[$current].Requires)) {
                        $Name | Should -Contain $requirement

                        # And it must come BEFORE the component that needs it.
                        ([array]::IndexOf($Name, $requirement)) |
                            Should -BeLessThan ([array]::IndexOf($Name, $current))
                    }
                }
            }
        }
    }

    Context 'the filesystem' {

        It 'throws when a component cab is missing' {
            $record = $null
            try {
                Get-HDTBootImageComponent -OptionalComponent @('WinPE-NoSuchThing') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem)
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*WinPE-NoSuchThing*'
            $record.Exception.Message | Should -BeLike ('*{0}\WinPE-NoSuchThing.cab*' -f $script:componentRoot)
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:componentRoot)
        }

        It 'resolves CabPath under the component root' {
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            $row[0].CabPath | Should -BeExactly ('{0}\WinPE-WMI.cab' -f $script:componentRoot)
        }

        It 'resolves the language pack under the language folder' {
            $row = @(Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem))

            $row[0].LanguageCabPath | Should -BeExactly ('{0}\en-us\WinPE-WMI_en-us.cab' -f $script:componentRoot)
        }

        It 'returns an empty LanguageCabPath when there is no language pack' {
            # WinPE-FMAPI is the verified case: the one component in this ADK's
            # WinPE_OCs whose en-us pack does not exist. It must never be an
            # error - DESIGN 5.1 says the builder probes rather than assumes.
            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-FMAPI') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem) -WarningAction SilentlyContinue)

            @($row | Where-Object { $_.Name -eq 'WinPE-FMAPI' })[0].LanguageCabPath | Should -BeExactly ''
        }

        It 'warns once for a component with no language pack' {
            $row = @(Get-HDTBootImageComponent -OptionalComponent @('WinPE-FMAPI') `
                    -ComponentRoot $script:componentRoot -FileSystem (New-HDTComponentTestFileSystem) -WarningVariable warning)

            $row.Count | Should -Be 7
            @($warning).Count | Should -Be 1
            [string] $warning[0] | Should -BeLike '*WinPE-FMAPI*'
        }

        It 'honours -Language' {
            $filesystem = New-HDTFakeFileSystem -File @{
                ('{0}\WinPE-WMI.cab' -f $script:componentRoot)                = 'cab'
                ('{0}\de-de\WinPE-WMI_de-de.cab' -f $script:componentRoot)    = 'cab'
                ('{0}\WinPE-NetFx.cab' -f $script:componentRoot)              = 'cab'
                ('{0}\WinPE-Scripting.cab' -f $script:componentRoot)          = 'cab'
                ('{0}\WinPE-PowerShell.cab' -f $script:componentRoot)         = 'cab'
                ('{0}\WinPE-StorageWMI.cab' -f $script:componentRoot)         = 'cab'
                ('{0}\WinPE-DismCmdlets.cab' -f $script:componentRoot)        = 'cab'
            }

            $row = @(Get-HDTBootImageComponent -OptionalComponent @() -ComponentRoot $script:componentRoot `
                    -Language 'de-de' -FileSystem $filesystem -WarningAction SilentlyContinue)

            $row[0].LanguageCabPath | Should -BeExactly ('{0}\de-de\WinPE-WMI_de-de.cab' -f $script:componentRoot)
        }

        It 'reads through the injected filesystem' {
            $filesystem = New-HDTComponentTestFileSystem

            Get-HDTBootImageComponent -ComponentRoot $script:componentRoot -FileSystem $filesystem | Out-Null

            @($filesystem.GetOperationName()) | Should -Contain 'TestPath'
        }
    }
}
