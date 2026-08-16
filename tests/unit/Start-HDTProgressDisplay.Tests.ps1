# THE PROGRESS WINDOW DECIDES NOTHING FOR ITSELF, AND MUST NEVER STOP A
# DEPLOYMENT.
#
# DESIGN 11.1: "It must degrade to the console. If XAML fails to load - a boot
# image built without the right components, an exotic display, a serial console
# - the engine logs the reason and writes styled console lines instead, then
# carries on. A deployment that refused to run because it cannot draw a progress
# bar would be a worse toolkit than one with no progress bar at all. A contract
# test asserts the fallback path is taken when WPF is unavailable, because the
# fallback is exactly the path nobody exercises until the night it matters."
#
# THIS IS THAT TEST. Every way the window can fail to open is a mode, not an
# error: Window, Console, Suppressed - and nothing here throws.
#
# HDTSkipProgress SUPPRESSES IT ENTIRELY for unattended runs, which is not the
# same as failing to draw it: a machine nobody is standing at does not need a
# screen, and the log is where that run is read from.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:xamlPath = 'X:\HDT\UI\HDTProgress.xaml'

    # The real window, read off disk rather than retyped, so the shipped file
    # and the file these tests exercise cannot drift.
    $script:realXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTProgress.xaml'))

    function New-HDTProgressTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fake file system; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Xaml = $script:realXaml,

            [Parameter()]
            [switch] $Missing
        )

        $file = @{}
        if (-not $Missing) { $file[$script:xamlPath] = $Xaml }

        return New-HDTFakeFileSystem -File $file
    }
}

Describe 'Start-HDTProgressDisplay' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Start-HDTProgressDisplay' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected display host, so it can run with no display' {
            (Get-Command -Name 'Start-HDTProgressDisplay').Parameters.ContainsKey('DisplayHost') | Should -BeTrue
        }
    }

    Context 'when everything works' {

        It 'opens the window' {
            $displayHost = New-HDTFakeProgressHost

            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost $displayHost -FileSystem (New-HDTProgressTestFileSystem)

            [string] $display.Mode | Should -BeExactly 'Window'
            @($displayHost.Operations | Where-Object { $_ -like 'Open*' }).Count | Should -Be 1
        }

        It 'hands the host the markup it read, so the host touches no file system' {
            $displayHost = New-HDTFakeProgressHost

            Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost $displayHost -FileSystem (New-HDTProgressTestFileSystem) | Out-Null

            [string] $displayHost.LastXaml | Should -BeLike '*HDTProgressBar*'
        }

        It 'hands the host a command prompt path, because F8 has to work here too' {
            # THE CASE MDT IS ACTUALLY KNOWN FOR. A technician hits F8 while the
            # deployment is running, not while the wizard is up. This window
            # lives in its own STA runspace with no Hephaestus module in it, so
            # it cannot call Start-HDTCommandPrompt - it is handed the path.
            $displayHost = New-HDTFakeProgressHost

            Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost $displayHost -FileSystem (New-HDTProgressTestFileSystem) | Out-Null

            [string] $displayHost.LastCommandPromptPath | Should -Not -BeNullOrEmpty
        }

        It 'uses the environment it was given to find it' {
            $environment = [pscustomobject] @{}
            $environment | Add-Member -MemberType ScriptMethod -Name GetVariable -Value {
                param([string] $Name)
                if ($Name -eq 'ComSpec') { return 'X:\Windows\System32\cmd.exe' }
                return ''
            }

            $displayHost = New-HDTFakeProgressHost

            Start-HDTProgressDisplay -XamlPath $script:xamlPath -DisplayHost $displayHost `
                -FileSystem (New-HDTProgressTestFileSystem) -EnvironmentProvider $environment | Out-Null

            [string] $displayHost.LastCommandPromptPath | Should -BeExactly 'X:\Windows\System32\cmd.exe'
        }

        It 'says nothing went wrong' {
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost (New-HDTFakeProgressHost) -FileSystem (New-HDTProgressTestFileSystem)

            [string] $display.Reason | Should -BeNullOrEmpty
        }
    }

    Context 'when it cannot draw' {

        It 'falls back to the console when the window file is not there' {
            $displayHost = New-HDTFakeProgressHost

            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost $displayHost -FileSystem (New-HDTProgressTestFileSystem -Missing)

            [string] $display.Mode | Should -BeExactly 'Console'
            @($displayHost.Operations) | Should -BeNullOrEmpty
        }

        It 'falls back when the window file does not parse' {
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost (New-HDTFakeProgressHost) `
                -FileSystem (New-HDTProgressTestFileSystem -Xaml '<Window><this is not xaml')

            [string] $display.Mode | Should -BeExactly 'Console'
        }

        It 'falls back when WPF itself will not load' {
            # THE PATH NOBODY EXERCISES UNTIL THE NIGHT IT MATTERS: a boot image
            # built without WinPE-NetFx has no PresentationFramework, and
            # Add-Type throws where a window should have opened.
            $displayHost = New-HDTFakeProgressHost -FailOpen

            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost $displayHost -FileSystem (New-HDTProgressTestFileSystem)

            [string] $display.Mode | Should -BeExactly 'Console'
        }

        It 'says why, because a fallback nobody can explain is a defect nobody finds' {
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost (New-HDTFakeProgressHost -FailOpen) `
                -FileSystem (New-HDTProgressTestFileSystem)

            [string] $display.Reason | Should -Not -BeNullOrEmpty
        }

        It 'hands back a host that writes the console lines instead' {
            # THE FALLBACK IS A HOST, NOT A BRANCH AT THE CALL SITE. The engine
            # calls Update the same way on every machine; a caller that had to
            # ask which mode it got would be a caller that forgets to, on
            # exactly the machines this path exists for.
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost (New-HDTFakeProgressHost -FailOpen) `
                -FileSystem (New-HDTProgressTestFileSystem)

            $display.DisplayHost | Should -Not -BeNullOrEmpty
            @($display.DisplayHost.PSObject.Methods.Name) | Should -Contain 'Update'
            @($display.DisplayHost.PSObject.Methods.Name) | Should -Contain 'Close'
        }

        It 'the fallback host writes a line rather than throwing' {
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -DisplayHost (New-HDTFakeProgressHost -FailOpen) `
                -FileSystem (New-HDTProgressTestFileSystem)

            $progress = [pscustomobject] @{
                SequenceId = 'STD-CLIENT'; StepNumber = 1; StepCount = 3; StepName = 'Partition disk'
                StepType = 'DiskPartition'; CompletedCount = 0; PercentComplete = 0
                Phase = 'WinPE'; Status = 'Running'; ElapsedSecond = 5
            }

            { $display.DisplayHost.Update($progress) } | Should -Not -Throw 6>$null
        }

        It 'never throws, whatever went wrong' -ForEach @('Missing', 'Malformed', 'NoWpf') {
            # THE RULE THIS COMMAND EXISTS FOR. A deployment that refused to run
            # because it could not draw a progress bar would be a worse toolkit
            # than one with no progress bar at all.
            $fileSystem = New-HDTProgressTestFileSystem
            $displayHost = New-HDTFakeProgressHost

            if ($PSItem -eq 'Missing') { $fileSystem = New-HDTProgressTestFileSystem -Missing }
            if ($PSItem -eq 'Malformed') { $fileSystem = New-HDTProgressTestFileSystem -Xaml '<broken' }
            if ($PSItem -eq 'NoWpf') { $displayHost = New-HDTFakeProgressHost -FailOpen }

            { Start-HDTProgressDisplay -XamlPath $script:xamlPath -DisplayHost $displayHost -FileSystem $fileSystem } |
                Should -Not -Throw
        }
    }

    Context 'HDTSkipProgress' {

        It 'shows nothing at all when the rules said not to' {
            $displayHost = New-HDTFakeProgressHost

            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -Variable @{ HDTSkipProgress = $true } `
                -DisplayHost $displayHost -FileSystem (New-HDTProgressTestFileSystem)

            [string] $display.Mode | Should -BeExactly 'Suppressed'
            @($displayHost.Operations) | Should -BeNullOrEmpty
        }

        It 'is not the console fallback, because they are different facts' {
            # Suppressed is a machine nobody is standing at; Console is a
            # machine that could not draw. Reporting one as the other would hide
            # a broken boot image behind a deliberate setting.
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -Variable @{ HDTSkipProgress = $true } `
                -DisplayHost (New-HDTFakeProgressHost) -FileSystem (New-HDTProgressTestFileSystem)

            [string] $display.Mode | Should -Not -BeExactly 'Console'
        }

        It 'does not read the window file it was never going to show' {
            # A missing file is not a failure on a run that was never going to
            # draw anything.
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -Variable @{ HDTSkipProgress = $true } `
                -DisplayHost (New-HDTFakeProgressHost) -FileSystem (New-HDTProgressTestFileSystem -Missing)

            [string] $display.Mode | Should -BeExactly 'Suppressed'
        }

        It 'reads <_> as true, because rules and command lines deliver both' -ForEach @($true, 'true', 'YES', '1') {
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -Variable @{ HDTSkipProgress = $PSItem } `
                -DisplayHost (New-HDTFakeProgressHost) -FileSystem (New-HDTProgressTestFileSystem)

            [string] $display.Mode | Should -BeExactly 'Suppressed'
        }

        It 'shows the window when <_> means false' -ForEach @($false, 'false', 'no', '') {
            $display = Start-HDTProgressDisplay -XamlPath $script:xamlPath `
                -Variable @{ HDTSkipProgress = $PSItem } `
                -DisplayHost (New-HDTFakeProgressHost) -FileSystem (New-HDTProgressTestFileSystem)

            [string] $display.Mode | Should -BeExactly 'Window'
        }
    }

    Context 'the shipped window' {

        It 'exists at src/Hephaestus/UI/HDTProgress.xaml' {
            Test-Path -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTProgress.xaml') -PathType Leaf |
                Should -BeTrue
        }

        It 'names every control the host fills' {
            foreach ($name in @('HDTProgressComputerName', 'HDTProgressSequenceName', 'HDTProgressPhase',
                    'HDTProgressStepName', 'HDTProgressStepGroup', 'HDTProgressStepCounter',
                    'HDTProgressBar', 'HDTProgressStatus', 'HDTProgressElapsed')) {

                $script:realXaml | Should -BeLike ('*{0}*' -f $name)
            }
        }

        It 'has no way out of it, because it is a status board and not a dialog' {
            # Every other window in this image carries Next and Cancel. This one
            # must not: there is nothing here to answer, and a corner that makes
            # a deployment screen disappear is a deployment nobody can account
            # for.
            $script:realXaml | Should -Not -BeLike '*HDTNextButton*'
            $script:realXaml | Should -Not -BeLike '*HDTCancelButton*'
        }

        It 'declares no code-behind, which WinPE could not compile anyway' {
            $document = [xml] $script:realXaml

            $document.DocumentElement.GetAttribute('Class', 'http://schemas.microsoft.com/winfx/2006/xaml') |
                Should -BeNullOrEmpty
        }
    }
}
