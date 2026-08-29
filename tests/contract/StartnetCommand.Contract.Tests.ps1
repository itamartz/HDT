#requires -Module Pester

# EVERY COMMAND startnet.cmd EMITS HAS TO EXIST IN WinPE, AND THIS IS THE TEST
# THAT SAYS SO.
#
# HDT shipped `tzutil /s "<id>"` in startnet.cmd for a whole release. tzutil.exe
# IS NOT IN WinPE. cmd.exe printed "'tzutil' is not recognized", startnet carried
# on to the next line, and nothing anywhere failed - so the boot image built
# green, the manifest recorded the startnet text that contained the line, and the
# engine spent every WinPE run eleven hours out on a clock nobody had moved.
# It was found by a human typing tzutil at a WinPE prompt.
#
# The defect was not the wrong command. The defect was that NOTHING CHECKED, and
# a per-command test written the day tzutil was added would have passed - because
# it would have been written by the same person making the same assumption. So
# this is written against the SET: build the script with every feature it has
# turned on, take the command off the front of every line HDT authored, and
# require each one to be something WinPE actually has. The next tzutil-shaped
# assumption fails here, at the gate, rather than at a bench with a mounted
# image and a wrong clock.
#
# WHERE THE ANSWER COMES FROM: tests/fixtures/winpe/winpe-command-amd64.json is a
# real capture - Get-WindowsImageContent over an HDT boot image that
# Update-HDTBootImage actually built, listing the executables reachable on
# WinPE's PATH. It is not a list somebody wrote down from memory, which is the
# failure mode being fixed. Re-capture it when the ADK or the component set
# moves; the header in the file says how.
#
# ADMINISTRATOR START COMMANDS ARE NOT HDT'S TO VET. A workspace that declares
# `X:\Tools\TightVNC\tvnserver.exe -run` ships that binary itself through
# extraContent, and refusing it here would refuse the feature. What IS checked is
# the wrapping HDT puts around it - the `echo` announcement and the `call` - and
# the fixture-native commands this test drives it with.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:winPe = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/winpe/winpe-command-amd64.json') -Raw |
        ConvertFrom-Json

    $script:winPeCommand = @($script:winPe.command)

    # cmd.exe's own keywords. They are not files and never will be, so a fixture
    # of executables cannot answer for them - but they are still commands
    # startnet emits, so they are named here rather than waved through.
    $script:cmdIntrinsic = @(
        '@echo', 'echo', 'rem', 'set', 'call', 'start', 'if', 'for', 'goto',
        'exit', 'cd', 'md', 'rd', 'del', 'copy', 'move', 'type', 'pause',
        'title', 'setlocal', 'endlocal', 'pushd', 'popd', 'ver', 'cls'
    )

    # The leading command of one startnet line, lower-cased and stripped of the
    # .exe WinPE does not need typed.
    function Get-HDTStartnetLineCommand {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string] $Line
        )

        $text = $Line.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }

        # A quoted first token is a path with a space in it, not a command name.
        if ($text.StartsWith('"')) { return $text }

        $token = @($text -split '\s+')[0]

        # A rooted or relative path is a file the image carries, not a PATH
        # lookup - the caller shipped it and answers for it.
        if ($token -match '^[A-Za-z]:\\' -or $token.Contains('\') -or $token.Contains('/')) { return $token }

        if ($token.ToLowerInvariant().EndsWith('.exe')) {
            $token = $token.Substring(0, $token.Length - 4)
        }

        return $token.ToLowerInvariant()
    }
}

Describe 'startnet.cmd emits only commands WinPE has' {

    BeforeAll {
        # EVERY FEATURE ON AT ONCE, AND THE SET IS READ OFF THE FUNCTION RATHER
        # THAN LISTED HERE. A test that named the parameters it knew about would
        # pass over the next one silently, which is exactly how tzutil shipped:
        # every existing assertion went on being green because none of them had
        # heard of it. So the sample table below is checked AGAINST the
        # function's real parameter list, and a parameter with no sample fails
        # this file until somebody adds one - at which point the assertion below
        # runs over the lines it produces.
        #
        # The start commands are deliberately WinPE-native so the whole output,
        # HDT's wrapping included, can be asserted rather than exempted.
        $script:sample = @{
            Command           = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDeployment.ps1'
            StartCommand      = @('wpeutil disablefirewall', 'reg import X:\HDT\Tools.reg')
            UnattendPath      = 'X:\Unattend.xml'
            CertificateScript = 'X:\HDT\Import-HDTBootCertificate.ps1'
        }

        $script:parameterName = @(InModuleScope Hephaestus {
                $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
                @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

                @((Get-Command -Name Get-HDTStartnetScript).Parameters.Keys) |
                    Where-Object { $common -notcontains $_ }
            })

        $script:full = InModuleScope Hephaestus -Parameters @{ Splat = $script:sample } {
            param($Splat)
            Get-HDTStartnetScript @Splat
        }

        $script:fullLine = @($script:full.TrimEnd("`r", "`n") -split "`r`n")
    }

    It 'drives every parameter the function has, so a new one cannot slip past' {
        $unsampled = @($script:parameterName | Where-Object { -not $script:sample.ContainsKey($_) })

        @($unsampled).Count | Should -Be 0 -Because (
            'these parameters can put a line into startnet.cmd and this file has no sample value for them, so the WinPE check below never sees what they emit: ' +
            (@($unsampled) -join ', '))
    }

    It 'produces more lines than the default, so the set under test is the whole set' {
        # A guard on the guard. If the feature parameters were ever renamed away,
        # the loop below would pass over five harmless lines and prove nothing.
        $script:fullLine.Count | Should -BeGreaterThan 8 -Because (
            'the script was:' + [System.Environment]::NewLine + $script:full)
    }

    It 'names a command WinPE carries on every line' {
        $missing = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:fullLine) {
            $command = Get-HDTStartnetLineCommand -Line $current
            if ([string]::IsNullOrWhiteSpace($command)) { continue }

            # A path the administrator shipped; see the header.
            if ($command.Contains('\') -or $command.Contains('/') -or $command.StartsWith('"')) { continue }

            if ($script:cmdIntrinsic -contains $command) { continue }
            if ($script:winPeCommand -contains $command) { continue }

            [void] $missing.Add(('{0}   <- from: {1}' -f $command, $current))
        }

        @($missing).Count | Should -Be 0 -Because (
            'WinPE does not carry these, so cmd.exe would print "is not recognized" and startnet would carry on to the next line with nothing failing:' +
            [System.Environment]::NewLine + ((@($missing) | ForEach-Object { '  ' + $_ }) -join [System.Environment]::NewLine))
    }

    It 'does not emit tzutil, which is the command that started this' {
        # Named on purpose, as a regression marker. The assertion above is the
        # general one; this one makes the failure legible if it ever comes back.
        $script:full | Should -Not -Match 'tzutil'
    }

    It 'does not emit w32tm either' {
        # Absent from WinPE for the same reason and the obvious next guess.
        $script:full | Should -Not -Match 'w32tm'
    }
}

Describe 'the WinPE command fixture' {

    It 'is a real capture and says so' {
        [string] $script:winPe.source | Should -Not -BeNullOrEmpty
        @($script:winPe.searchPath).Count | Should -BeGreaterThan 0
    }

    It 'carries the commands startnet actually relies on' {
        # If the fixture were ever re-captured from something that was not a
        # WinPE image, these would go missing and every assertion above would
        # start failing for the wrong reason.
        foreach ($name in @('wpeinit', 'powershell', 'cmd')) {
            $script:winPeCommand | Should -Contain $name
        }
    }

    It 'does not carry tzutil or w32tm' {
        # The captured fact this whole file rests on.
        $script:winPeCommand | Should -Not -Contain 'tzutil'
        $script:winPeCommand | Should -Not -Contain 'w32tm'
    }
}
