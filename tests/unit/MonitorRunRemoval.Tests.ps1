# CLEARING A RUN OFF THE MONITORING NODE.
#
# A heartbeat file is the one deletable thing on this share that BREAKS NOTHING.
# No task sequence reads it, no boot image names it, and the engine writes a new
# one on the next step of the next deployment - so the dialog must not borrow the
# sentence the other four use. Telling somebody that clearing a finished run
# "cannot be undone" and leaving it there is how a screen teaches that its
# warnings are noise.
#
# THE REFUSALS ARE THE POINT. This command takes a name off a row and turns it
# into a delete, which is the shape that costs people their share. A run id is a
# FILE NAME and nothing else: a separator, a '..', a rooted path or a wildcard in
# it is a defect, not a path to normalise and accept.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    BeforeAll {
        # A HAND-WRITTEN FAKE, not Mock - a readable failure, and it records
        # exactly what was asked of the disk.
        function New-HDTTestMonitorFileSystem {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory test double; it changes no state.')]
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param([string[]] $Present = @())

            $fake = [pscustomobject] @{
                Present = [string[]] @($Present)
                Removed = New-Object System.Collections.ArrayList
            }

            $fake | Add-Member -MemberType ScriptMethod -Name TestPath -Value {
                param([string] $Path)
                return @($this.Present) -contains $Path
            }

            $fake | Add-Member -MemberType ScriptMethod -Name RemoveItem -Value {
                param([string] $Path, [bool] $Recurse)
                [void] $this.Removed.Add([pscustomobject] @{ Path = $Path; Recurse = $Recurse })
            }

            return $fake
        }

        $script:runRoot = 'C:\HDTLab\Share'
        $script:runFile = 'C:\HDTLab\Share\Logs\_active\run-20260827-191455.json'
    }

    Describe 'Remove-HDTMonitorRun' {

        Context 'a run that is there' {

            BeforeAll {
                $script:fs = New-HDTTestMonitorFileSystem -Present @($script:runFile)

                $script:result = Remove-HDTMonitorRun -Root $script:runRoot `
                    -RunId 'run-20260827-191455' -FileSystem $script:fs -Confirm:$false
            }

            It 'deletes the heartbeat file and says so' {
                $script:result.Removed | Should -BeTrue
                $script:result.RunId | Should -BeExactly 'run-20260827-191455'
            }

            It 'deletes exactly one thing, by the full path it built itself' {
                @($script:fs.Removed).Count | Should -Be 1
                $script:fs.Removed[0].Path | Should -BeExactly $script:runFile
            }

            It 'does not delete recursively - a run is a file, not a tree' {
                # -Recurse on a path that turns out to be a directory is how a
                # single-file delete takes a folder with it.
                $script:fs.Removed[0].Recurse | Should -BeFalse
            }

            It 'reports the path it removed, so the caller can echo it' {
                $script:result.Path | Should -BeExactly $script:runFile
            }
        }

        Context 'a run that has already gone' {

            BeforeAll {
                $script:goneFs = New-HDTTestMonitorFileSystem -Present @()

                $script:gone = Remove-HDTMonitorRun -Root $script:runRoot `
                    -RunId 'run-20260827-191455' -FileSystem $script:goneFs -Confirm:$false
            }

            It 'says it removed nothing rather than throwing' {
                # Two people clearing the same finished run is not an error.
                $script:gone.Removed | Should -BeFalse
            }

            It 'touches the disk not at all' {
                @($script:goneFs.Removed).Count | Should -Be 0
            }
        }

        Context 'refusing a run id that is not a file name' {

            BeforeAll {
                $script:refuseFs = New-HDTTestMonitorFileSystem -Present @($script:runFile)
            }

            # EACH OF THESE IS A REAL SHAPE somebody can put on a row or a
            # command line, and every one of them resolves outside _active.
            It 'refuses <Why>' -ForEach @(
                @{ RunId = '..\..\..\Windows\System32\config'; Why = 'a traversal' }
                @{ RunId = 'C:\Windows\System32\config'; Why = 'a rooted path' }
                @{ RunId = 'sub\run'; Why = 'a path with a separator' }
                @{ RunId = 'sub/run'; Why = 'a path with a forward slash' }
                @{ RunId = '*'; Why = 'a wildcard' }
                @{ RunId = 'run?1'; Why = 'a single-character wildcard' }
                @{ RunId = '   '; Why = 'a run id of nothing but spaces' }
            ) {
                { Remove-HDTMonitorRun -Root $script:runRoot -RunId $RunId `
                        -FileSystem $script:refuseFs -Confirm:$false } | Should -Throw
            }

            It 'deletes nothing while refusing' {
                @($script:refuseFs.Removed).Count | Should -Be 0
            }
        }

        Context 'what it will not be talked into' {

            It 'names the run in the refusal, so the row can be recognised' {
                $message = ''
                try {
                    Remove-HDTMonitorRun -Root $script:runRoot -RunId '..\evil' `
                        -FileSystem (New-HDTTestMonitorFileSystem) -Confirm:$false
                } catch {
                    $message = [string] $_.Exception.Message
                }

                $message | Should -BeLike '*evil*'
            }
        }

        Context 'WhatIf' {

            BeforeAll {
                $script:whatIfFs = New-HDTTestMonitorFileSystem -Present @($script:runFile)

                $script:whatIf = Remove-HDTMonitorRun -Root $script:runRoot `
                    -RunId 'run-20260827-191455' -FileSystem $script:whatIfFs -WhatIf
            }

            It 'removes nothing' {
                @($script:whatIfFs.Removed).Count | Should -Be 0
            }

            It 'still answers, so a caller can report what would happen' {
                $script:whatIf.Removed | Should -BeFalse
            }
        }

        It 'supports ShouldProcess, because it deletes' {
            (Get-Command -Name Remove-HDTMonitorRun).Parameters.ContainsKey('WhatIf') |
                Should -BeTrue
        }

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Remove-HDTMonitorRun -ErrorAction Stop

            $help.Name | Should -BeExactly 'Remove-HDTMonitorRun'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Describe 'Get-HDTConsoleRemoval for a monitor run' {

        BeforeAll {
            $script:ask = Get-HDTConsoleRemoval -Kind 'MonitorRun' -Root 'C:\HDTLab\Share' `
                -Id 'run-20260827-191455'
        }

        It 'can be removed' {
            $script:ask.CanRemove | Should -BeTrue
        }

        It 'titles the dialog for what is being cleared, not removed' {
            # 'Remove' is the word this window uses for things that leave a hole.
            $script:ask.Title | Should -BeExactly 'Clear Monitored Run'
        }

        It 'names the run and the share' {
            $script:ask.Question | Should -Match 'run-20260827-191455'
            $script:ask.Question | Should -Match 'C:\\HDTLab\\Share'
        }

        # THE SENTENCE THAT MUST NOT BE BORROWED FROM THE OTHER FOUR.
        It 'says the deployment itself is untouched' {
            $script:ask.Question | Should -Match 'deployment'
        }

        It 'does not claim a task sequence stops working' {
            $script:ask.Warning | Should -BeNullOrEmpty
        }

        It 'echoes a command that binds' {
            $script:ask.Command |
                Should -BeExactly "Remove-HDTMonitorRun -Root 'C:\HDTLab\Share' -RunId 'run-20260827-191455'"
        }

        It 'refuses a row that names no run' {
            (Get-HDTConsoleRemoval -Kind 'MonitorRun' -Root 'C:\HDTLab\Share' -Id '').CanRemove |
                Should -BeFalse
        }
    }

    Describe 'the right-click menu on a monitored run' {

        It 'opens at all' {
            # A menu item that is Visible on a cancelled menu is invisible in the
            # only sense that matters. This is the guard that decides.
            (Get-HDTConsoleTreeMenuRow -Kind 'MonitorRun' -Name 'run-20260827-191455').Opens |
                Should -BeTrue
        }

        It 'still opens nothing on a row with nothing to offer' {
            (Get-HDTConsoleTreeMenuRow -Kind 'Step' -Name 'Apply OS').Opens | Should -BeFalse
        }
    }
}
