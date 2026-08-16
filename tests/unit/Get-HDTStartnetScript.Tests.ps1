# startnet.cmd - five lines, and every one of them is load-bearing.
#
# This is the file WinPE runs when it finishes booting, and it is the only thing
# standing between "a machine booted our image" and "a machine ran our engine".
# Phase 04's E2E had to TYPE a line at the WinPE prompt because no such file
# existed yet; 05-05 asserts HDT_LAUNCHED_BY=startnet in RESULT.json to prove
# nobody typed anything.
#
# It is a pure function so the exact bytes can be asserted here in milliseconds,
# and tests/integration/BootImage.Integration.Tests.ps1 reads the same text back
# out of a MOUNTED IMAGE and compares it line by line. One function, two
# witnesses.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:startnet = InModuleScope Hephaestus { Get-HDTStartnetScript }
    $script:line = @($script:startnet.TrimEnd("`r", "`n") -split "`r`n")
}

Describe 'Get-HDTStartnetScript' {

    It 'has exactly five lines' {
        $script:line.Count | Should -Be 5 -Because ('the script was:' + [System.Environment]::NewLine + $script:startnet)
    }

    It 'starts with @echo off' {
        $script:line[0] | Should -BeExactly '@echo off'
    }

    It 'carries a rem line naming Update-HDTBootImage' {
        # Somebody WILL open this file inside a mounted image at three in the
        # morning. It should say where it came from.
        $script:line[1] | Should -BeLike 'rem *Update-HDTBootImage*'
    }

    It 'sets HDT_LAUNCHED_BY to startnet' {
        # The field Start-HDTDeployment.ps1 records into RESULT.json, and the
        # one 05-05 asserts to prove the launch was automatic.
        $script:line[2] | Should -BeExactly 'set HDT_LAUNCHED_BY=startnet'
    }

    It 'runs wpeinit before PowerShell' {
        # Compared BY LINE INDEX, not by substring presence: wpeinit is what
        # brings networking up, and a share connect before it would fail on a
        # machine that was going to work.
        $wpeinit = -1
        $powershell = -1
        for ($index = 0; $index -lt $script:line.Count; $index++) {
            if ($script:line[$index] -eq 'wpeinit') { $wpeinit = $index }
            if ($script:line[$index] -like 'powershell.exe*') { $powershell = $index }
        }

        $wpeinit | Should -BeGreaterThan -1
        $powershell | Should -BeGreaterThan $wpeinit
    }

    It 'launches X:\HDT\Start-HDTDeployment.ps1' {
        $script:line[4] | Should -BeLike '*X:\HDT\Start-HDTDeployment.ps1'
    }

    It 'passes -NoProfile and -ExecutionPolicy Bypass' {
        $script:line[4] | Should -BeLike '*-NoProfile*'
        $script:line[4] | Should -BeLike '*-ExecutionPolicy Bypass*'
        $script:line[4] | Should -BeLike '*-File *'
    }

    It 'names no drive letter but X' {
        # X: is the RAM disk, the ONE letter WinPE guarantees. SPIKES S9.1
        # recorded WinPE giving the content disk C: while the RAM disk was X:,
        # so a C: here would be a guess about a machine that has not booted yet.
        $drive = @([regex]::Matches($script:startnet, '[A-Za-z]:\\') | ForEach-Object { $_.Value })

        $drive.Count | Should -BeGreaterThan 0
        foreach ($item in $drive) { $item | Should -BeExactly 'X:\' }
    }

    It 'contains no for loop and no drive scan' {
        # The phase-04 harness types 'for %d in (C D E F G H)' because a HUMAN
        # was typing it at a prompt with no bootstrap document. This file must
        # not inherit that line: the engine reads X:\HDT\bootstrap.json and
        # Resolve-HDTDeployRoot does the discovering.
        $script:startnet | Should -Not -BeLike '*for %*'
        $script:startnet | Should -Not -BeLike '*C D E F G H*'
    }

    It 'ends every line with CRLF' {
        # It is a .cmd. A bare LF is not a line ending cmd.exe is obliged to
        # understand, and the failure it produces says nothing useful.
        @([regex]::Matches($script:startnet, "`r`n")).Count | Should -Be 5
        @([regex]::Matches($script:startnet, "(?<!`r)`n")).Count | Should -Be 0
    }

    It 'honours -Command for a different entry point' {
        $custom = InModuleScope Hephaestus {
            Get-HDTStartnetScript -Command 'powershell.exe -NoProfile -File X:\HDT\Start-HDTDiagnostic.ps1'
        }
        $customLine = @($custom.TrimEnd("`r", "`n") -split "`r`n")

        $customLine.Count | Should -Be 5
        $customLine[4] | Should -BeExactly 'powershell.exe -NoProfile -File X:\HDT\Start-HDTDiagnostic.ps1'
    }

    It 'keeps wpeinit and the environment variable under -Command' {
        # A different entry point is still a WinPE boot: it still needs
        # networking up and it still records how it was launched.
        $custom = InModuleScope Hephaestus { Get-HDTStartnetScript -Command 'cmd.exe /k' }

        $custom | Should -BeLike '*wpeinit*'
        $custom | Should -BeLike '*set HDT_LAUNCHED_BY=startnet*'
    }

    It 'runs the start commands after wpeinit and before the entry command' {
        # THE ORDER IS THE WHOLE POINT. A tool started before wpeinit has no
        # network, and one started after the entry command never starts at all -
        # the entry command is the deployment and it does not return.
        $withStart = InModuleScope Hephaestus {
            Get-HDTStartnetScript -StartCommand @(
                'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0',
                'X:\HDT\Tools\VNC\winvnc.exe -service')
        }
        $startLine = @($withStart.TrimEnd("`r", "`n") -split "`r`n")

        $startLine.Count | Should -Be 7
        $startLine[3] | Should -BeExactly 'wpeinit'
        $startLine[4] | Should -BeExactly 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'
        $startLine[5] | Should -BeExactly 'X:\HDT\Tools\VNC\winvnc.exe -service'
        $startLine[6] | Should -BeLike '*X:\HDT\Start-HDTDeployment.ps1'
    }

    It 'writes the five lines and nothing else when there are no start commands' {
        # An empty list is not a blank line in a .cmd. AN EMPTY LINE IS HARMLESS
        # and a stray one is confusing, but the real reason is the integration
        # test: it compares this text byte for byte against a mounted image.
        $empty = InModuleScope Hephaestus { Get-HDTStartnetScript -StartCommand @() }

        $empty | Should -BeExactly $script:startnet
    }

    It 'keeps the start commands under a custom entry command' {
        $both = InModuleScope Hephaestus {
            Get-HDTStartnetScript -Command 'cmd.exe /k' -StartCommand @('X:\HDT\Tools\bginfo.exe')
        }
        $bothLine = @($both.TrimEnd("`r", "`n") -split "`r`n")

        $bothLine[4] | Should -BeExactly 'X:\HDT\Tools\bginfo.exe'
        $bothLine[5] | Should -BeExactly 'cmd.exe /k'
    }

    It 'ends every start command line with CRLF too' {
        $withStart = InModuleScope Hephaestus {
            Get-HDTStartnetScript -StartCommand @('X:\HDT\Tools\bginfo.exe')
        }

        @([regex]::Matches($withStart, "`r`n")).Count | Should -Be 6
        @([regex]::Matches($withStart, "(?<!`r)`n")).Count | Should -Be 0
    }

    It 'is private to the module' {
        # It is an implementation detail of Update-HDTBootImage, not a command
        # an administrator runs. BOTH HALVES ARE ASSERTED: a test that only
        # checked "not exported" would pass for a function that does not exist
        # at all, which is README section 12's trap.
        InModuleScope Hephaestus {
            Get-Command -Name 'Get-HDTStartnetScript' -ErrorAction SilentlyContinue
        } | Should -Not -BeNullOrEmpty

        Get-Command -Name 'Get-HDTStartnetScript' -Module Hephaestus -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}
