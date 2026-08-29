#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# THE QUOTING RULE THAT DECIDES WHETHER dism GETS THREE ARGUMENTS OR ONE.
#
# New-HDTImageService.ApplyUnattend runs dism.exe as a POLLED process rather
# than a pipeline, so that a pass which prints nothing for three minutes still
# ticks a heartbeat. A polled process is started through
# System.Diagnostics.ProcessStartInfo, and under .NET Framework - which is what
# WinPE has - that class takes ONE Arguments STRING and no ArgumentList. So the
# command line has to be built by hand, and Windows parses it back with
# CommandLineToArgvW.
#
# THE TRAP, MEASURED ON THIS MACHINE RATHER THAN REMEMBERED. Every path DISM is
# handed here is a volume root or a path under one, and /Image: takes the ROOT -
# 'W:\', ending in a backslash. Quoted the obvious way:
#
#   "/Image:W:\" "/Apply-Unattend:W:\Windows\Panther\unattend.xml" "/ScratchDir:W:\HDT\Scratch"
#
# argv[0] comes back as
#
#   /Image:W:" /Apply-Unattend:W:\Windows\Panther\unattend.xml /ScratchDir:W:\HDT\Scratch
#
# ONE ARGUMENT, because the backslash before the closing quote escaped it and
# the rest of the line was swallowed as text. dism would have been handed a
# single nonsense switch. That is a silent corruption of the only call that runs
# the offlineServicing pass, so the rule gets its own function and its own tests
# instead of living inline in an adapter nothing unit tests.
#
# THE RULE IS CommandLineToArgvW's, and it is not "escape every backslash":
# backslashes are only special IMMEDIATELY BEFORE A QUOTE. So a run of them at
# the end of a quoted argument is doubled, a run before an embedded quote is
# doubled, and every other backslash - which is every separator in every Windows
# path - is left exactly as it is.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') `
        -Force -ErrorAction Stop

    # THE ANSWER IS NOT ASSERTED FROM MEMORY, IT IS ASKED OF WINDOWS. This runs
    # the built command line through a real process and reports the argv the
    # parser produced, which is the only authority on whether the quoting worked.
    # The child is powershell.exe printing its own $args - no file is opened by
    # association, and nothing appears on a screen.
    $script:echoPath = Join-Path -Path $TestDrive -ChildPath 'HDTArgvEcho.ps1'
    [System.IO.File]::WriteAllText($script:echoPath,
        '$i = 0; foreach ($a in $args) { Write-Output ("{0}={1}" -f $i, $a); $i++ }')

    # A PRIVATE FUNCTION IS NOT EXPORTED, so every call goes through the module's
    # own scope, as ConvertFrom-HDTDismProgressLine's tests do.
    $script:quote = {
        param([string] $Value)

        return [string] (InModuleScope Hephaestus -Parameters @{ Value = $Value } {
                ConvertTo-HDTNativeArgument -Argument $Value
            })
    }

    function Get-HDTTestArgv {
        param([string[]] $Argument)

        $built = @($Argument | ForEach-Object { & $script:quote $_ }) -join ' '

        $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $script:echoPath, $built
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $output = $process.StandardOutput.ReadToEnd()
        [void] $process.WaitForExit(30000)

        return , ([string[]] @($output -split "`r?`n" |
                    Where-Object { $_ -match '^\d+=' } |
                    ForEach-Object { $_ -replace '^\d+=', '' }))
    }
}

Describe 'ConvertTo-HDTNativeArgument' {

    Context 'an argument that needs no quoting is left alone' {

        # EVERY PATH THIS ADAPTER ACTUALLY PASSES IS ONE OF THESE, and a quoted
        # form would be a change to a call that already works on real hardware.
        It 'returns <Argument> unchanged' -ForEach @(
            @{ Argument = '/Image:W:\' }
            @{ Argument = '/Apply-Unattend:W:\Windows\Panther\unattend.xml' }
            @{ Argument = '/ScratchDir:W:\HDT\Scratch' }
            @{ Argument = 'dism.exe' }
        ) {
            & $script:quote $Argument | Should -BeExactly $Argument
        }
    }

    Context 'an argument with a space is quoted' {

        It 'wraps it in quotes' {
            & $script:quote '/ScratchDir:C:\some dir\Scratch' |
                Should -BeExactly '"/ScratchDir:C:\some dir\Scratch"'
        }

        # THE ONE THAT BREAKS. A quoted argument ending in a backslash needs the
        # trailing run doubled, or the closing quote is escaped and the rest of
        # the command line joins this argument.
        It 'doubles a trailing backslash so the closing quote survives' {
            & $script:quote '/Image:C:\some dir\' |
                Should -BeExactly '"/Image:C:\some dir\\"'
        }

        It 'doubles a trailing RUN of backslashes, not just the last one' {
            & $script:quote 'C:\some dir\\' |
                Should -BeExactly '"C:\some dir\\\\"'
        }

        # BACKSLASHES ARE ONLY SPECIAL BEFORE A QUOTE. Doubling the separators
        # inside a path would hand dism a path that does not exist.
        It 'leaves the separators inside the path alone' {
            & $script:quote 'C:\a b\c\d.xml' |
                Should -BeExactly '"C:\a b\c\d.xml"'
        }

        It 'quotes an argument containing a tab' {
            & $script:quote "a`tb" | Should -BeExactly "`"a`tb`""
        }
    }

    Context 'an argument containing a quote' {

        It 'escapes the quote' {
            & $script:quote 'say "hi"' |
                Should -BeExactly '"say \"hi\""'
        }

        It 'doubles the backslashes that precede an embedded quote' {
            & $script:quote 'a\"b' |
                Should -BeExactly '"a\\\"b"'
        }

        # A quote with no space still has to be quoted: unquoted, argv would
        # lose it.
        It 'quotes an argument that has a quote but no space' {
            & $script:quote 'a"b' | Should -BeExactly '"a\"b"'
        }
    }

    Context 'an empty argument' {

        # An empty string is a real argument and must survive as one - bare, it
        # would vanish from the command line entirely.
        It 'becomes a pair of quotes' {
            & $script:quote '' | Should -BeExactly '""'
        }
    }

    Context 'Windows itself parses the result back' {

        # THE ASSERTION THAT WOULD HAVE CAUGHT THE TRAP. Everything above states
        # what the string should look like; this states what Windows does with
        # it, which is the only thing that matters.
        It 'gives dism its three arguments back, separately' {
            $argv = Get-HDTTestArgv -Argument @(
                '/Image:W:\',
                '/Apply-Unattend:W:\Windows\Panther\unattend.xml',
                '/ScratchDir:W:\HDT\Scratch')

            @($argv).Count | Should -Be 3
            $argv[0] | Should -BeExactly '/Image:W:\'
            $argv[1] | Should -BeExactly '/Apply-Unattend:W:\Windows\Panther\unattend.xml'
            $argv[2] | Should -BeExactly '/ScratchDir:W:\HDT\Scratch'
        }

        It 'gives back a path with a space and a trailing backslash as ONE argument' {
            $argv = Get-HDTTestArgv -Argument @('/Image:C:\some dir\', '/Second:x')

            @($argv).Count | Should -Be 2
            $argv[0] | Should -BeExactly '/Image:C:\some dir\'
            $argv[1] | Should -BeExactly '/Second:x'
        }

        It 'gives back an argument carrying a quote' {
            $argv = Get-HDTTestArgv -Argument @('a"b', 'c')

            @($argv).Count | Should -Be 2
            $argv[0] | Should -BeExactly 'a"b'
            $argv[1] | Should -BeExactly 'c'
        }
    }
}
