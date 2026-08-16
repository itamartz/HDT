# New-HDTBootIso against fakes: no ADK, no oscdimg, no ISO, nothing burned.
#
# The ISO is DESIGN 5.2's first-class debugging artifact, and everything this
# command decides - which El Torito image to stage, where to stage it, what
# oscdimg's command line says - is decided before a single byte is written. So
# it is all provable here, in milliseconds, on a machine with no ADK at all.
#
# THE STAGING IS THE POINT, AND IT IS SPIKES S2. The ADK lives under
# 'C:\Program Files (x86)\...', and oscdimg's -bootdata: cannot take a quoted
# path. This command copies the two or three boot bits it needs into a
# space-free directory FIRST and builds the argument against that. A test asserts
# the staged path has no space in it, because a future "simplification" that
# passed the ADK path straight through would fail with Error 123 fifteen minutes
# into a build.
#
# The ADK is resolved through the fake IRegistryService seeded from
# tests/fixtures/adk/adk-layout-10.1.26100.2454.json, a real capture of this
# host's ADK - so a path this file asserts is a path that exists somewhere in the
# world, and no literal is read.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:layout = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/adk/adk-layout-10.1.26100.2454.json') -Raw |
        ConvertFrom-Json

    $script:kitsRoot10 = [string] $script:layout.kitsRoot10
    $script:adkRoot = [string] $script:layout.adkRoot
    $script:oscdimgDirectory = $script:adkRoot + '\Deployment Tools\amd64\Oscdimg'

    $script:adkSeed = @{}
    foreach ($row in @($script:layout.file)) {
        $script:adkSeed[($script:adkRoot + [string] $row.Path)] = 'fixture'
    }

    $script:mediaRoot = 'C:\HDTLab\scratch\bootimage\work\media'
    $script:isoPath = 'C:\HDTLab\scratch\bootimage\Share\Boot\HDTPE_x64.iso'
    $script:bitPath = 'C:\HDTLab\scratch\bootimage\work\bootbits'

    function New-HDTBootIsoTestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test doubles; it changes no state.')]
        [CmdletBinding()]
        param()

        $journal = [System.Collections.ArrayList]::new()

        $seed = @{}
        foreach ($key in @($script:adkSeed.Keys)) { $seed[$key] = $script:adkSeed[$key] }
        $seed[($script:mediaRoot + '\sources\boot.wim')] = 'the exported wim'

        $fs = New-HDTFakeFileSystem -File $seed -Journal $journal
        $registry = New-HDTFakeRegistryService -Value @{
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' = @{ KitsRoot10 = $script:kitsRoot10 }
        } -Journal $journal
        $boot = New-HDTFakeBootImageService -FileSystem $fs -Journal $journal

        return [pscustomobject] @{
            Journal    = $journal
            FileSystem = $fs
            Registry   = $registry
            Boot       = $boot
        }
    }
}

Describe 'New-HDTBootIso' {

    BeforeEach {
        $script:context = New-HDTBootIsoTestContext
    }

    Context 'resolving the ADK' {

        It 'resolves every ADK asset through Get-HDTAdkPath' {
            # Asserted from the fake registry's journal: nothing here reads a
            # literal ADK path, so the layout can move between ADK releases
            # without this command moving with it (PROJECT.md).
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -NoPromptForKey -BootImageService $script:context.Boot -FileSystem $script:context.FileSystem `
                -Registry $script:context.Registry -Confirm:$false | Out-Null

            @($script:context.Journal |
                    Where-Object { $_.Service -eq 'RegistryService' -and $_.Operation -eq 'GetValue' }).Count |
                Should -BeGreaterThan 0
        }

        It 'honours -AdkRoot over the registry' {
            $fs = New-HDTFakeFileSystem -File $script:adkSeed
            $boot = New-HDTFakeBootImageService -FileSystem $fs
            $registry = New-HDTFakeRegistryService

            { New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                    -AdkRoot $script:adkRoot -BootImageService $boot -FileSystem $fs -Registry $registry `
                    -Confirm:$false } | Should -Not -Throw
        }

        It 'refuses with a named error when the ADK is not installed' {
            $fs = New-HDTFakeFileSystem
            $boot = New-HDTFakeBootImageService -FileSystem $fs
            $registry = New-HDTFakeRegistryService

            $record = $null
            try {
                New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                    -BootImageService $boot -FileSystem $fs -Registry $registry -Confirm:$false
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
        }
    }

    Context 'staging the boot bits - SPIKES S2' {

        It 'stages the boot bits into a space-free directory before building' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -NoPromptForKey -BootImageService $script:context.Boot -FileSystem $script:context.FileSystem `
                -Registry $script:context.Registry -Confirm:$false | Out-Null

            $copy = @($script:context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' })

            $copy.Count | Should -BeGreaterThan 0
            foreach ($item in $copy) {
                [string] $item.Arguments[1] | Should -Not -Match '\s'
            }
        }

        It 'creates the staging directory' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -NoPromptForKey -BootImageService $script:context.Boot -FileSystem $script:context.FileSystem `
                -Registry $script:context.Registry -Confirm:$false | Out-Null

            $script:context.FileSystem.TestPath($script:bitPath) | Should -BeTrue
        }

        It 'stages only efisys_noprompt.bin for UEFI with -NoPromptForKey' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -Firmware UEFI -NoPromptForKey -BootImageService $script:context.Boot `
                -FileSystem $script:context.FileSystem -Registry $script:context.Registry -Confirm:$false | Out-Null

            $staged = @($script:context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { [System.IO.Path]::GetFileName([string] $_.Arguments[1]) })

            $staged | Should -Be @('efisys_noprompt.bin')
        }

        It 'stages efisys.bin for UEFI without -NoPromptForKey' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -Firmware UEFI -BootImageService $script:context.Boot `
                -FileSystem $script:context.FileSystem -Registry $script:context.Registry -Confirm:$false | Out-Null

            $staged = @($script:context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { [System.IO.Path]::GetFileName([string] $_.Arguments[1]) })

            $staged | Should -Be @('efisys.bin')
        }

        It 'stages etfsboot.com as well for -Firmware Both' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -Firmware Both -NoPromptForKey -BootImageService $script:context.Boot `
                -FileSystem $script:context.FileSystem -Registry $script:context.Registry `
                -WarningAction SilentlyContinue -Confirm:$false | Out-Null

            $staged = @($script:context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { [System.IO.Path]::GetFileName([string] $_.Arguments[1]) })

            $staged | Should -Contain 'etfsboot.com'
            $staged | Should -Contain 'efisys_noprompt.bin'
        }

        It 'stages only etfsboot.com for -Firmware BIOS' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -Firmware BIOS -BootImageService $script:context.Boot `
                -FileSystem $script:context.FileSystem -Registry $script:context.Registry -Confirm:$false | Out-Null

            $staged = @($script:context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { [System.IO.Path]::GetFileName([string] $_.Arguments[1]) })

            $staged | Should -Be @('etfsboot.com')
        }

        It 'refuses a boot bit path containing a space' {
            # The refusal comes from Get-HDTBootIsoArgument, and it must reach
            # the caller rather than being swallowed here.
            $record = $null
            try {
                New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath `
                    -BootBitPath 'C:\Program Files\HDT bits' -BootImageService $script:context.Boot `
                    -FileSystem $script:context.FileSystem -Registry $script:context.Registry -Confirm:$false
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*-bootdata*'
        }

        It 'runs oscdimg zero times when it refuses' {
            try {
                New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath `
                    -BootBitPath 'C:\Program Files\HDT bits' -BootImageService $script:context.Boot `
                    -FileSystem $script:context.FileSystem -Registry $script:context.Registry -Confirm:$false
            } catch { $null = $_ }

            @($script:context.Boot.GetOperationName()) | Should -Not -Contain 'NewIso'
        }
    }

    Context 'building the ISO' {

        It 'calls NewIso exactly once' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -NoPromptForKey -BootImageService $script:context.Boot -FileSystem $script:context.FileSystem `
                -Registry $script:context.Registry -Confirm:$false | Out-Null

            @($script:context.Boot.GetOperationName() | Where-Object { $_ -eq 'NewIso' }).Count | Should -Be 1
        }

        It 'passes the argument list Get-HDTBootIsoArgument produced' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -NoPromptForKey -BootImageService $script:context.Boot -FileSystem $script:context.FileSystem `
                -Registry $script:context.Registry -Confirm:$false | Out-Null

            $call = @($script:context.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })[0]

            [string] $call.Arguments[0] | Should -BeExactly $script:mediaRoot
            [string] $call.Arguments[1] | Should -BeExactly $script:isoPath

            $argument = @($call.Arguments[2])
            @($argument[0..3]) | Should -Be @('-m', '-o', '-u2', '-udfver102')
            $argument | Should -Contain ('-bootdata:1#pEF,e,b{0}\efisys_noprompt.bin' -f $script:bitPath)
        }

        It 'runs oscdimg zero times under -WhatIf' {
            New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath -BootBitPath $script:bitPath `
                -NoPromptForKey -BootImageService $script:context.Boot -FileSystem $script:context.FileSystem `
                -Registry $script:context.Registry -WhatIf | Out-Null

            @($script:context.Boot.GetOperationName()) | Should -Not -Contain 'NewIso'
        }
    }

    Context 'what it reports' {

        BeforeEach {
            $script:result = New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath `
                -BootBitPath $script:bitPath -NoPromptForKey -BootImageService $script:context.Boot `
                -FileSystem $script:context.FileSystem -Registry $script:context.Registry -Confirm:$false
        }

        It 'returns the sha256 of the ISO it produced' {
            $script:result.Sha256 | Should -Match '^[0-9A-F]{64}$'
            $script:result.Sha256 | Should -BeExactly $script:context.FileSystem.GetHash($script:isoPath)
        }

        It 'returns the path, size and media root' {
            $script:result.Path | Should -BeExactly $script:isoPath
            $script:result.SizeBytes | Should -BeGreaterThan 0
            $script:result.MediaRoot | Should -BeExactly $script:mediaRoot
        }

        It 'returns the firmware, the no-prompt flag and the label' {
            $script:result.Firmware | Should -BeExactly 'UEFI'
            $script:result.NoPromptForKey | Should -BeTrue
            $script:result.Label | Should -BeExactly 'HDTPE_x64'
        }
    }

    Context 'the defaults' {

        It 'defaults to -Firmware UEFI' {
            # DESIGN 5.2: Generation 2 and every modern physical machine boot
            # UEFI, so the UEFI-only case covers essentially all debugging.
            $result = New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath `
                -BootBitPath $script:bitPath -BootImageService $script:context.Boot `
                -FileSystem $script:context.FileSystem -Registry $script:context.Registry -Confirm:$false

            $result.Firmware | Should -BeExactly 'UEFI'
        }

        It 'defaults -NoPromptForKey off for a direct caller' {
            # It is ON when Update-HDTBootImage calls this command, and that is
            # that command's decision to make, not this one's.
            $result = New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath `
                -BootBitPath $script:bitPath -BootImageService $script:context.Boot `
                -FileSystem $script:context.FileSystem -Registry $script:context.Registry -Confirm:$false

            $result.NoPromptForKey | Should -BeFalse

            $call = @($script:context.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })[0]
            @($call.Arguments[2]) | Should -Contain ('-bootdata:1#pEF,e,b{0}\efisys.bin' -f $script:bitPath)
        }

        It 'defaults the boot bit path to a space-free directory' {
            $result = New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath `
                -BootImageService $script:context.Boot -FileSystem $script:context.FileSystem `
                -Registry $script:context.Registry -Confirm:$false

            $result.Path | Should -BeExactly $script:isoPath

            $staged = @($script:context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' })
            foreach ($item in $staged) {
                [string] $item.Arguments[1] | Should -Not -Match '\s'
            }
        }
    }

    Context 'the help' {

        It 'has comment-based help naming itself' {
            # Get-Help falls back to a FUZZY SEARCH and will happily return a
            # sibling command's help, so the name is asserted first
            # (tests/helpers/README.md section 12).
            $help = Get-Help -Name 'New-HDTBootIso' -ErrorAction Stop

            $help.Name | Should -BeExactly 'New-HDTBootIso'
            $help.Synopsis | Should -Not -BeNullOrEmpty
            @($help.Examples.Example).Count | Should -BeGreaterThan 0
        }

        It 'is exported' {
            Get-Command -Name 'New-HDTBootIso' -Module Hephaestus -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'supports ShouldProcess' {
            # It overwrites a file a fleet may be booting from.
            (Get-Command -Name 'New-HDTBootIso').Parameters.Keys | Should -Contain 'WhatIf'
        }
    }
}
