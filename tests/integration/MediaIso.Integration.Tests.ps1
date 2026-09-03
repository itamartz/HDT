# THE THIN ADAPTER OVER REAL oscdimg, AND NOTHING ELSE.
#
# tests/unit/Update-HDTMediaContent.Tests.ps1 proves the media build DECIDES
# correctly - what travels, what is refused, the provider swap, the order - in
# thirteen seconds against fakes. This file proves the TOOL does what the fake
# was told it does: a real oscdimg turns a directory into an ISO with a boot
# catalog in it.
#
# IT IS DELIBERATELY SMALL, AND THAT IS A DECISION RATHER THAN AN OMISSION.
# Building a real disc means projecting a real share, a real DISM mount and ten
# minutes; that is the orchestrator's two-VM proof, not this suite's. What is
# unproven WITHOUT this file is one thing - that New-HDTBootIso's argument
# reaches oscdimg in a form it accepts - and a tiny tree proves it in seconds.
#
# THE ONE TRAP IT EXISTS FOR IS SPIKES S2: oscdimg's -bootdata: cannot take a
# quoted path and the ADK lives under 'C:\Program Files (x86)\', so the boot bits
# are staged to a space-free directory and the argument built unquoted. A fake
# cannot catch a regression in that, because the fake never parses the argument.
#
# EVERY SKIP CONDITION IS RECOMPUTED INSIDE BeforeAll (SPIKES S9.15): Pester's
# discovery and run phases do not share a scope.

BeforeDiscovery {
    $script:discoveryAdk = $false

    try {
        Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset EfiSysNoPrompt -ErrorAction Stop)
        $script:discoveryAdk = $true
    } catch {
        $script:discoveryAdk = $false
    }

    $script:skipBurn = -not $script:discoveryAdk
}

Describe 'Media ISO - real oscdimg' -Tag 'Integration' -Skip:$script:skipBurn {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        $script:adkPresent = $false
        try {
            [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
            $script:adkPresent = $true
        } catch {
            $script:adkPresent = $false
        }

        if (-not $script:adkPresent) {
            Write-Warning 'The ADK is not installed, so the real oscdimg row is skipped. That is the correct outcome, not a failure.'
        }

        # A DIRECTORY THIS TEST CREATES, under C:\HDTLab\scratch\, with an HDT-
        # name, removed by explicit -LiteralPath in AfterAll. PROJECT.md permits
        # exactly this and nothing wider: no enumeration of a parent, no
        # variable handed to -Recurse without knowing what it holds.
        $script:scratchRoot = Join-Path -Path 'C:\HDTLab\scratch' -ChildPath ('HDT-media-iso-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:mediaRoot = Join-Path -Path $script:scratchRoot -ChildPath 'media'
        $script:bitPath = Join-Path -Path $script:scratchRoot -ChildPath 'bootbits'
        $script:isoPath = Join-Path -Path $script:scratchRoot -ChildPath 'HDT-tiny.iso'

        New-Item -Path (Join-Path -Path $script:mediaRoot -ChildPath 'sources') -ItemType Directory -Force | Out-Null

        # A TINY TREE, NOT A DISC. Enough for oscdimg to have something to write
        # and for a projected share to be recognisable in the result.
        Set-Content -LiteralPath (Join-Path -Path $script:mediaRoot -ChildPath 'sources\boot.wim') `
            -Value 'not a real wim, and oscdimg does not care' -Encoding Ascii

        New-Item -Path (Join-Path -Path $script:mediaRoot -ChildPath 'Share') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $script:mediaRoot -ChildPath 'Share\rules.yaml') `
            -Value 'schemaVersion: 1' -Encoding Ascii

        $script:result = $null
        if ($script:adkPresent) {
            $script:result = New-HDTBootIso -MediaRoot $script:mediaRoot -Path $script:isoPath `
                -NoPromptForKey -BootBitPath $script:bitPath -Label 'HDT_TINY' -Confirm:$false
        }
    }

    AfterAll {
        # BY EXPLICIT -LiteralPath TO THE DIRECTORY THIS TEST CREATED, and the
        # guard is not decoration: PROJECT.md forbids handing a variable to
        # -Recurse without asserting first what it is.
        if (-not [string]::IsNullOrWhiteSpace($script:scratchRoot) -and
            $script:scratchRoot -like 'C:\HDTLab\scratch\HDT-media-iso-*' -and
            (Test-Path -LiteralPath $script:scratchRoot)) {

            Remove-Item -LiteralPath $script:scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes an ISO where it was told to' {
        Test-Path -LiteralPath $script:isoPath | Should -BeTrue
        $script:result.Path | Should -BeExactly $script:isoPath
    }

    It 'reports a size and a SHA256 that match the file on disk' {
        $file = Get-Item -LiteralPath $script:isoPath

        $script:result.SizeBytes | Should -Be $file.Length
        $script:result.Sha256 | Should -BeExactly (Get-FileHash -LiteralPath $script:isoPath -Algorithm SHA256).Hash
    }

    It 'is bootable-shaped - it carries an El Torito boot catalog' {
        # THE ONE THING A FAKE CANNOT SAY. oscdimg writes the boot catalog from
        # the -bootdata: argument, and an argument it rejected produces either no
        # file or a file with no catalog in it. 'CD001' is the ISO 9660 volume
        # descriptor signature and 'EL TORITO SPECIFICATION' is the boot record's.
        $byte = [System.IO.File]::ReadAllBytes($script:isoPath)
        $text = [System.Text.Encoding]::ASCII.GetString($byte, 0, [math]::Min(262144, $byte.Length))

        $text | Should -Match 'CD001'
        $text | Should -Match 'EL TORITO SPECIFICATION'
    }

    It 'staged the no-prompt El Torito image, so a VM nobody is standing at boots' {
        # SPIKES S2's staging, checked on disk: the bits went to a space-free
        # directory, which is the only form oscdimg's -bootdata: accepts.
        $script:bitPath | Should -Not -Match '\s'
        Test-Path -LiteralPath (Join-Path -Path $script:bitPath -ChildPath 'efisys_noprompt.bin') | Should -BeTrue

        $script:result.NoPromptForKey | Should -BeTrue
    }
}
