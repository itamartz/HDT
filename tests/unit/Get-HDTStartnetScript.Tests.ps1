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

    # =====================================================================
    # A BATCH FILE NEEDS `call`, AND WITHOUT IT THE DEPLOYMENT NEVER STARTS.
    #
    # cmd.exe does not return from one batch file to another: a bare
    # `X:\Tools\run.cmd` inside startnet.cmd TRANSFERS control, and the entry
    # command below it - the deployment - is never reached. The machine sits at
    # whatever run.cmd left behind, having booted, initialised and run the
    # administrator's tools, and looks for all the world like a deployment that
    # hung.
    #
    # It is fixed HERE rather than in Add-HDTBootImageStartCommand so that a
    # hand-edited workspace.yaml gets it too. What the administrator typed is
    # what the document keeps; `call` is a fact about cmd.exe, and belongs with
    # the code that writes cmd.
    # =====================================================================

    It 'calls a <_> start command, so control comes back' -ForEach @('run.cmd', 'run.bat') {
        $file = $_
        $withStart = InModuleScope Hephaestus -Parameters @{ File = $file } {
            param($File)
            Get-HDTStartnetScript -StartCommand @('X:\Tools\{0}' -f $File)
        }
        $startLine = @($withStart.TrimEnd("`r", "`n") -split "`r`n")

        $startLine[4] | Should -BeExactly ('call X:\Tools\{0}' -f $file)
    }

    It 'calls a batch file that carries arguments, and keeps them' {
        $withStart = InModuleScope Hephaestus {
            Get-HDTStartnetScript -StartCommand @('X:\Tools\run.cmd -vnc -bginfo')
        }
        $startLine = @($withStart.TrimEnd("`r", "`n") -split "`r`n")

        $startLine[4] | Should -BeExactly 'call X:\Tools\run.cmd -vnc -bginfo'
    }

    It 'calls a quoted batch path, which is the one an admin with spaces types' {
        $withStart = InModuleScope Hephaestus {
            Get-HDTStartnetScript -StartCommand @('"X:\Program Files\HDT\run.cmd"')
        }
        $startLine = @($withStart.TrimEnd("`r", "`n") -split "`r`n")

        $startLine[4] | Should -BeExactly 'call "X:\Program Files\HDT\run.cmd"'
    }

    It 'does not call a <_> twice' -ForEach @('call X:\Tools\run.cmd', 'CALL X:\Tools\run.cmd') {
        $typed = $_
        $withStart = InModuleScope Hephaestus -Parameters @{ Typed = $typed } {
            param($Typed)
            Get-HDTStartnetScript -StartCommand @($Typed)
        }
        $startLine = @($withStart.TrimEnd("`r", "`n") -split "`r`n")

        $startLine[4] | Should -BeExactly $typed
    }

    It 'leaves a start-ed batch file alone, because start already returns' {
        # `start` launches it in its own window and comes straight back, which
        # is what an administrator writes when the tool has to stay up. Adding
        # `call` there would change what they asked for.
        $withStart = InModuleScope Hephaestus {
            Get-HDTStartnetScript -StartCommand @('start "" X:\Tools\run.cmd')
        }
        $startLine = @($withStart.TrimEnd("`r", "`n") -split "`r`n")

        $startLine[4] | Should -BeExactly 'start "" X:\Tools\run.cmd'
    }

    It 'leaves an executable alone' {
        # An .exe is a process, not a batch file: cmd.exe waits for it and
        # carries on by itself. `call` here would be noise.
        $withStart = InModuleScope Hephaestus {
            Get-HDTStartnetScript -StartCommand @('X:\Tools\BGInfo\bginfo64.exe /timer:0')
        }
        $startLine = @($withStart.TrimEnd("`r", "`n") -split "`r`n")

        $startLine[4] | Should -BeExactly 'X:\Tools\BGInfo\bginfo64.exe /timer:0'
    }

    # =====================================================================
    # THE ANSWER FILE, WHICH IS wpeinit's OWN ARGUMENT.
    #
    # wpeinit -unattend:<path> processes a WinPE answer file: Display,
    # EnableFirewall, EnableNetwork, LogPath, PageFile, Restart, RunSynchronous
    # and RunAsynchronous. It is the supported way to turn the WinPE firewall
    # on or off, and it happens as part of the line that already exists rather
    # than as a new one.
    # =====================================================================

    It 'points wpeinit at the answer file when there is one' {
        $withUnattend = InModuleScope Hephaestus {
            Get-HDTStartnetScript -UnattendPath 'X:\Unattend.xml'
        }
        $unattendLine = @($withUnattend.TrimEnd("`r", "`n") -split "`r`n")

        $unattendLine.Count | Should -Be 5
        $unattendLine[3] | Should -BeExactly 'wpeinit -unattend:X:\Unattend.xml'
    }

    It 'quotes an answer file path with a space in it' {
        $withUnattend = InModuleScope Hephaestus {
            Get-HDTStartnetScript -UnattendPath 'X:\HDT Files\Unattend.xml'
        }
        $unattendLine = @($withUnattend.TrimEnd("`r", "`n") -split "`r`n")

        $unattendLine[3] | Should -BeExactly 'wpeinit -unattend:"X:\HDT Files\Unattend.xml"'
    }

    It 'writes a plain wpeinit when there is no answer file' {
        $none = InModuleScope Hephaestus { Get-HDTStartnetScript -UnattendPath '' }

        $none | Should -BeExactly $script:startnet
    }

    It 'still runs the start commands after wpeinit when an answer file is set' {
        $both = InModuleScope Hephaestus {
            Get-HDTStartnetScript -UnattendPath 'X:\Unattend.xml' -StartCommand @('X:\Tools\run.cmd')
        }
        $bothLine = @($both.TrimEnd("`r", "`n") -split "`r`n")

        $bothLine[3] | Should -BeExactly 'wpeinit -unattend:X:\Unattend.xml'
        $bothLine[4] | Should -BeExactly 'call X:\Tools\run.cmd'
        $bothLine[5] | Should -BeLike '*X:\HDT\Start-HDTDeployment.ps1'
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
