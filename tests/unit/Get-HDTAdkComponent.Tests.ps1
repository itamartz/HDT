# What can be injected into a boot image on THIS build host.
#
# Get-HDTBootImageComponent validates a list an administrator has already
# written. Nothing answered the question that comes before it - "what is there to
# add?" - so the only way to find out was to open Explorer on the ADK, or to
# guess a name and wait for the build to refuse it.
#
# THE ROOT IS RESOLVED, NEVER A LITERAL. PROJECT.md: the ADK layout has moved
# between releases, so this goes through Get-HDTAdkPath like everything else -
# and that is asserted here with an injected registry, on a machine that may have
# no ADK at all.
#
# The fake filesystem is seeded from tests/fixtures/adk/adk-layout-10.1.26100.2454.json,
# a real capture of this host's ADK, so every count and every name below is a
# fact about a real WinPE_OCs folder rather than an invented shape.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:layout = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/adk/adk-layout-10.1.26100.2454.json') -Raw |
        ConvertFrom-Json

    $script:kitsRoot10 = [string] $script:layout.kitsRoot10
    $script:adkRoot = [string] $script:layout.adkRoot
    $script:componentRoot = $script:adkRoot + '\Windows Preinstallation Environment\amd64\WinPE_OCs'

    # A DISTINCT LENGTH FOR ONE FILE, so "reports the size" cannot be satisfied
    # by a constant: every other cab is seeded with the same seven bytes.
    $script:markerText = 'x' * 4242

    $script:seed = @{}
    foreach ($row in @($script:layout.file)) {
        $script:seed[($script:adkRoot + [string] $row.Path)] = 'fixture'
    }
    $script:seed[($script:componentRoot + '\WinPE-WMI.cab')] = $script:markerText

    $script:workspaceRoot = 'C:\ws'
    $script:workspaceText = @'
schemaVersion: 1
id: HDT-LAB
name: HDT lab deployment share
bootImage:
  optionalComponents:
    - WinPE-HTA
    - WinPE-FMAPI
'@

    function New-HDTAdkComponentTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        param()

        $file = @{}
        foreach ($key in @($script:seed.Keys)) { $file[$key] = $script:seed[$key] }
        $file[($script:workspaceRoot + '\workspace.yaml')] = $script:workspaceText

        return (New-HDTFakeFileSystem -File $file)
    }

    function New-HDTAdkComponentTestRegistry {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        param()

        return (New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' = @{ KitsRoot10 = $script:kitsRoot10 }
            })
    }

    $script:row = @(Get-HDTAdkComponent -ComponentRoot $script:componentRoot `
            -FileSystem (New-HDTAdkComponentTestFileSystem))
}

Describe 'Get-HDTAdkComponent' {

    Context 'what the ADK offers' {

        It 'lists every optional component cab in the folder' {
            # 33 in ADK 10.1.26100.2454 amd64.
            $script:row.Count | Should -Be 33
        }

        It 'names a component the way the ADK names its cab' {
            @($script:row | ForEach-Object { $_.Name }) | Should -Contain 'WinPE-WMI'
        }

        It 'keeps the lowercase x of WinPE-NetFx, because no cab of the other spelling exists' {
            @($script:row | ForEach-Object { $_.Name }) | Should -Contain 'WinPE-NetFx'
        }

        It 'ignores the language folders lp.cab, which is not an optional component' {
            @($script:row | Where-Object { $_.Name -eq 'lp' }) | Should -BeNullOrEmpty
        }

        It 'returns the rows in name order, so two runs read the same' {
            $name = @($script:row | ForEach-Object { [string] $_.Name })

            ($name -join ',') | Should -BeExactly ((@($name) | Sort-Object) -join ',')
        }

        It 'carries the cab path a build would apply' {
            $wmi = @($script:row | Where-Object { $_.Name -eq 'WinPE-WMI' })[0]

            $wmi.CabPath | Should -BeExactly ($script:componentRoot + '\WinPE-WMI.cab')
        }

        It 'reports the size of the cab rather than a constant' {
            $wmi = @($script:row | Where-Object { $_.Name -eq 'WinPE-WMI' })[0]

            $wmi.SizeBytes | Should -Be $script:markerText.Length
        }
    }

    Context 'the language packs beside it' {

        It 'lists every language a component ships a pack for' {
            # 38 language folders in this ADK.
            $wmi = @($script:row | Where-Object { $_.Name -eq 'WinPE-WMI' })[0]

            @($wmi.LanguagePack).Count | Should -Be 38
            $wmi.LanguagePack | Should -Contain 'en-us'
        }

        It 'reports none for a component that ships none' {
            # Twelve of this ADK's 33 have no language pack at all - WinPE-FMAPI
            # among them - which is why the builder probes rather than assumes.
            $fmapi = @($script:row | Where-Object { $_.Name -eq 'WinPE-FMAPI' })[0]

            @($fmapi.LanguagePack).Count | Should -Be 0
        }
    }

    Context 'what it depends on' {

        It 'reports the dependency the shipped table cites' {
            $powerShell = @($script:row | Where-Object { $_.Name -eq 'WinPE-PowerShell' })[0]

            $powerShell.Requires | Should -Be @('WinPE-NetFx')
        }

        It 'reports nothing for a component the table does not name' {
            # A component absent from the table is allowed with no dependencies:
            # a fleet needs components this project never anticipated.
            $hta = @($script:row | Where-Object { $_.Name -eq 'WinPE-HTA' })[0]

            @($hta.Requires).Count | Should -Be 0
        }
    }

    Context 'what a build always applies' {

        It 'marks the boot-verified six as required' {
            @($script:row | Where-Object { $_.Required } | ForEach-Object { $_.Name } | Sort-Object) |
                Should -Be (@('WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell',
                    'WinPE-StorageWMI', 'WinPE-DismCmdlets') | Sort-Object)
        }

        It 'marks nothing else required' {
            @($script:row | Where-Object { $_.Required }).Count | Should -Be 6
        }
    }

    Context 'narrowing the list' {

        It 'filters by name with a wildcard' {
            $font = @(Get-HDTAdkComponent -ComponentRoot $script:componentRoot `
                    -Name 'WinPE-FontSupport-*' -FileSystem (New-HDTAdkComponentTestFileSystem))

            $font.Count | Should -Be 6
            @($font | Where-Object { $_.Name -notlike 'WinPE-FontSupport-*' }) | Should -BeNullOrEmpty
        }

        It 'returns nothing rather than throwing when the filter matches nothing' {
            $none = @(Get-HDTAdkComponent -ComponentRoot $script:componentRoot `
                    -Name 'WinPE-Nothing*' -FileSystem (New-HDTAdkComponentTestFileSystem))

            $none.Count | Should -Be 0
        }
    }

    Context 'what a workspace already declares' {

        It 'declares nothing when no workspace was named' {
            @($script:row | Where-Object { $_.Declared }) | Should -BeNullOrEmpty
        }

        It 'marks the components the workspace lists' {
            $marked = @(Get-HDTAdkComponent -ComponentRoot $script:componentRoot `
                    -WorkspaceRoot $script:workspaceRoot -FileSystem (New-HDTAdkComponentTestFileSystem))

            @($marked | Where-Object { $_.Declared } | ForEach-Object { $_.Name } | Sort-Object) |
                Should -Be @('WinPE-FMAPI', 'WinPE-HTA')
        }

        It 'leaves the rest unmarked' {
            $marked = @(Get-HDTAdkComponent -ComponentRoot $script:componentRoot `
                    -WorkspaceRoot $script:workspaceRoot -FileSystem (New-HDTAdkComponentTestFileSystem))

            @($marked | Where-Object { $_.Name -eq 'WinPE-WDS-Tools' })[0].Declared | Should -BeFalse
        }
    }

    Context 'resolving the folder' {

        It 'resolves the component root through Get-HDTAdkPath when it is not told one' {
            # PROJECT.md: the ADK layout has moved between releases, so the path
            # is resolved at runtime. Proven with an injected registry, so this
            # passes on a machine with no ADK.
            $resolved = @(Get-HDTAdkComponent -Registry (New-HDTAdkComponentTestRegistry) `
                    -FileSystem (New-HDTAdkComponentTestFileSystem))

            $resolved.Count | Should -Be 33
            @($resolved | Where-Object { $_.Name -eq 'WinPE-WMI' })[0].CabPath |
                Should -BeExactly ($script:componentRoot + '\WinPE-WMI.cab')
        }

        It 'refuses a component root that is not there, naming the Windows PE add-on' {
            { Get-HDTAdkComponent -ComponentRoot 'C:\nowhere\WinPE_OCs' `
                    -FileSystem (New-HDTAdkComponentTestFileSystem) } |
                Should -Throw -ExpectedMessage '*Windows PE add-on*'
        }

        It 'refuses that as a dependency error, because a missing ADK is the machine and not the document' {
            $record = $null
            try {
                Get-HDTAdkComponent -ComponentRoot 'C:\nowhere\WinPE_OCs' `
                    -FileSystem (New-HDTAdkComponentTestFileSystem)
            } catch {
                $record = $_
            }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
        }
    }
}
