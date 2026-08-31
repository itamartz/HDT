# NO SOURCE FILE CARRIES A STRAY CONTROL CHARACTER.
#
# THIS CONTRACT EXISTS BECAUSE ONE COST A REFERENCE BUILD, and it is the most
# expensive kind of defect this repository can hold: invisible to the eye,
# invisible to grep, and invisible to a green test suite.
#
# WHAT HAPPENED. New-HDTImageService.ps1 invoked bcdedit as
#
#     & "$env:SystemRoot\System32<0x08>cdedit.exe" @argument
#
# where <0x08> is a literal BACKSPACE byte standing where `\b` was meant to be -
# written in by an edit that let something interpret `\b` as an escape sequence
# before the bytes reached the file. The line READS as
# `$env:SystemRoot\System32\bcdedit.exe` in most editors, because a terminal
# rendering a backspace erases the character before it. Searching for
# `System32\bcdedit` does not match it. Searching for `System32cdedit` does not
# match it either, because the byte is still between them.
#
# WHY THE SUITE COULD NOT SEE IT. Adapters over external tools are branch-free
# and deliberately NOT unit tested (CLAUDE.md rule 1) - the whole point of the
# rule is that there is nothing in them to test but the call itself. So 12822
# passing tests said nothing at all about whether that call names a program that
# exists. It surfaced on a real machine, in the full OS, at step 12 of 16, after
# an operating system had been deployed and an application installed: every
# bcdedit call the run made died with "The term
# 'C:\Windows\System32cdedit.exe' is not recognized".
#
# AND IT WAS NOT ALONE. A scan for the same byte found four more, every one of
# them a `\b` in a path: `scratch\bootimage`, `Share\bootstrap-rules.yaml`,
# `\HDT\Boot\boot.wim` and `\windows\system32\boot\winload.efi` - plus a `\3` in
# a PCI device id that had become 0x03 the same way. THE WORST OF THEM WAS IN A
# FAKE: New-HDTFakeImageService.Tests.ps1 asserted the ramdisk boot paths that
# the BootToWinPE mechanism is built on, so the fake agreed with itself about a
# corrupted string while the real path was wrong. CLAUDE.md's own list of
# surfaces names that trap - "the fake was wrong, not the caller" - and this is
# it happening.
#
# WHAT IS ALLOWED. Tab, line feed and carriage return, which are ordinary text.
# Everything below 0x20 other than those three is refused, as is 0x7F. A test
# that genuinely needs a control character in its data should build it from an
# escape the language evaluates - "`e", [char] 0x1B - rather than embedding the
# raw byte, so that the intent is visible in the source.
#
# THE FILES ARE READ AS BYTES, never as text. Get-Content decodes, and a decoder
# is exactly what would hide the thing being looked for.

BeforeDiscovery {
    $script:contractRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE TEXT THIS REPOSITORY AUTHORS. Binary assets - .wim, .png, .exe - are
    # not text and are not scanned; the extension list is the filter rather than
    # a guess at what looks textual.
    $script:textExtension = @('.ps1', '.psm1', '.psd1', '.yaml', '.yml', '.json',
        '.md', '.xml', '.ini', '.cmd', '.bat', '.txt')

    # out\ is the build's own output and .git\ is not authored at all.
    $script:skipDirectory = @('.git', 'out', 'node_modules')

    $script:scanFile = {
        $all = @()
        foreach ($item in @(Get-ChildItem -LiteralPath $script:repoRoot -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $relative = $item.FullName.Substring($script:repoRoot.Length).TrimStart('\')

            $skip = $false
            foreach ($dir in $script:skipDirectory) {
                if ($relative -like ('{0}\*' -f $dir)) { $skip = $true; break }
            }
            if ($skip) { continue }

            if ($script:textExtension -notcontains $item.Extension.ToLowerInvariant()) { continue }

            $all += [pscustomobject] @{ Path = $item.FullName; Relative = $relative }
        }
        return $all
    }

    $script:candidate = @(& $script:scanFile)

    # 9 TAB, 10 LF, 13 CR. Everything else below 0x20, plus 0x7F DEL.
    #
    # EVERY OCCURRENCE, NOT THE FIRST IN EACH FILE. Reporting one at a time
    # turns a cleanup into a run-fix-rerun loop, which is the worst possible
    # ergonomics for a character nobody can see - and it is how the sixth of
    # these was nearly missed: the first scan stopped at one per file and one
    # file held two.
    $script:offender = @()
    foreach ($file in $script:candidate) {
        $byte = [System.IO.File]::ReadAllBytes($file.Path)

        # The line number is what makes the failure actionable - the character is
        # invisible, so "somewhere in this file" would send the next person
        # hunting. Counted in ONE pass rather than by rescanning from the start
        # for every hit.
        $line = 1
        for ($i = 0; $i -lt $byte.Length; $i++) {
            $b = $byte[$i]

            if ($b -eq 10) { $line++; continue }

            if (($b -lt 32 -and $b -ne 9 -and $b -ne 13) -or $b -eq 127) {
                $script:offender += [pscustomobject] @{
                    Relative = $file.Relative
                    Line     = $line
                    Byte     = ('0x{0:X2}' -f $b)
                }
            }
        }
    }
}

Describe 'no authored file carries a stray control character' {

    It 'finds the files to judge' {
        # A CONTRACT THAT SCANS NOTHING PASSES FOR THE WRONG REASON. If the walk
        # ever returns an empty set - a moved root, a changed extension list -
        # this is the assertion that says so instead of reporting green.
        @($script:candidate).Count | Should -BeGreaterThan 200
    }

    It 'includes the adapter the original defect was found in' {
        # NAMED, because the scan is only as good as its reach. This file is the
        # one that shipped a backspace inside a program path, so a walk that no
        # longer reaches it has stopped testing the thing it was written for.
        @($script:candidate | Where-Object { $_.Relative -like '*New-HDTImageService.ps1' }) |
            Should -Not -BeNullOrEmpty
    }

    It 'has no control character other than tab, CR and LF anywhere in it' {
        $detail = (@($script:offender |
                    ForEach-Object { '  {0}:{1} contains {2}' -f $_.Relative, $_.Line, $_.Byte }) -join "`n")

        @($script:offender) | Should -BeNullOrEmpty -Because (
            "a raw control character in source is invisible to the eye, to grep and to a green suite. " +
            "A backspace standing where ``\b`` was meant cost a reference build at step 12 of 16, on a " +
            "machine that had already deployed an OS and installed an application. Build a control " +
            "character the language can show you - ```e`` or [char] 0x1B - never a raw byte:`n" + $detail)
    }
}
