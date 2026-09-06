# Get-HDTDeploymentPhase answers ONE question: did this run START in WinPE or in
# the running full OS? Everything downstream hangs off it - _HDTPhase, the log
# root, the run state, and HDTDeploymentType, which is NEWCOMPUTER on the first
# and REFRESH on the second (DESIGN 3.2).
#
# IT IS THE MAPPING, NOT THE READING. The raw evidence is the system drive, and
# MDT reads exactly that: LiteTouch.wsf:373-387 tests oEnv("SystemDrive") = "X:"
# and calls the run NEWCOMPUTER when the drive is the RAM disk. HDT splits that
# in two so the half with the decision in it can be tested - the environment is
# read through the IEnvironmentProvider adapter, and the comparison lives here,
# against a string the caller passes in.
#
# SO THE VARIANTS ARE THE POINT. $env:SystemDrive is 'C:' with no trailing
# separator on a real machine and 'X:' in WinPE, but a caller reading it through
# a fake, a rule, or a future adapter can hand over 'X:\', 'x:' or a padded
# string, and a comparison fooled by any of those picks the deployment type that
# governs whether a volume gets wiped.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTDeploymentPhase' {

    Context 'the two phases, and there are only two' {

        It 'is exported by Hephaestus' {
            # A payload script can only call what the manifest exports, and this
            # is called by one - PayloadExportedCommand.Contract.Tests.ps1 says
            # so over the set, and this says it for the name being added.
            $manifest = Import-PowerShellDataFile -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1')

            @($manifest.FunctionsToExport) | Should -Contain 'Get-HDTDeploymentPhase'
            Get-Command -Name 'Get-HDTDeploymentPhase' -Module 'Hephaestus' -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }

        It 'answers WinPE for X:, the RAM disk' {
            Get-HDTDeploymentPhase -SystemDrive 'X:' | Should -BeExactly 'WinPE'
        }

        It 'answers FullOS for C:, the running Windows' {
            Get-HDTDeploymentPhase -SystemDrive 'C:' | Should -BeExactly 'FullOS'
        }

        It 'answers FullOS for any other letter, because only X: is the RAM disk' {
            foreach ($drive in @('D:', 'W:', 'S:', 'Z:')) {
                Get-HDTDeploymentPhase -SystemDrive $drive |
                    Should -BeExactly 'FullOS' -Because ('{0} is a real volume, not the WinPE RAM disk' -f $drive)
            }
        }
    }

    Context 'the shapes the value really takes' {

        It 'reads the value $env:SystemDrive actually holds on this machine' {
            # NOT A LITERAL. On Windows the variable is 'C:' with NO trailing
            # separator, and a function written against 'C:\' would be green in
            # every hand-written case and wrong on every machine. This is the
            # one assertion that reads the real shape.
            $real = [System.Environment]::GetEnvironmentVariable('SystemDrive')

            $real | Should -Not -BeNullOrEmpty
            Get-HDTDeploymentPhase -SystemDrive $real | Should -BeIn @('WinPE', 'FullOS')
        }

        It 'is not fooled by a trailing separator' {
            Get-HDTDeploymentPhase -SystemDrive 'X:\' | Should -BeExactly 'WinPE'
            Get-HDTDeploymentPhase -SystemDrive 'X:/' | Should -BeExactly 'WinPE'
            Get-HDTDeploymentPhase -SystemDrive 'C:\' | Should -BeExactly 'FullOS'
        }

        It 'is not fooled by case' {
            Get-HDTDeploymentPhase -SystemDrive 'x:' | Should -BeExactly 'WinPE'
            Get-HDTDeploymentPhase -SystemDrive 'x:\' | Should -BeExactly 'WinPE'
        }

        It 'is not fooled by surrounding whitespace' {
            Get-HDTDeploymentPhase -SystemDrive ' X: ' | Should -BeExactly 'WinPE'
            Get-HDTDeploymentPhase -SystemDrive " C:`t" | Should -BeExactly 'FullOS'
        }

        It 'does not mistake a path that merely starts with X for the RAM disk' {
            # 'X:\Windows' is a directory, not a system drive. A StartsWith test
            # would call it WinPE; so would a Contains one for 'D:\X:'. Neither
            # is the RAM disk.
            Get-HDTDeploymentPhase -SystemDrive 'X:\Windows' | Should -BeExactly 'FullOS'
            Get-HDTDeploymentPhase -SystemDrive 'XX:' | Should -BeExactly 'FullOS'
        }
    }

    Context 'a value it cannot read' {

        It 'refuses an empty system drive rather than guessing a phase' {
            # BOTH GUESSES ARE DESTRUCTIVE. Guessing WinPE publishes NEWCOMPUTER
            # on a machine that is running Windows; guessing FullOS publishes
            # REFRESH, which DESIGN 3.2 makes the one deployment type that
            # unlocks ApplyImage on a resumed leg. Every Windows and every WinPE
            # sets SystemDrive, so an empty one is a broken environment and not
            # a case to have an opinion about.
            foreach ($empty in @('', '   ')) {
                { Get-HDTDeploymentPhase -SystemDrive $empty } |
                    Should -Throw -ExpectedMessage '*SystemDrive*'
            }
        }
    }

    Context 'the answer fits every -Phase parameter in the module' {

        It 'answers with a value every -Phase ValidateSet in the module accepts' {
            # ASSERTED OVER THE SET, NOT OVER THE FOUR CALL SITES THAT EXIST
            # TODAY. This command exists to feed every -Phase parameter the
            # engine has; a command that grows one tomorrow, or one whose set
            # gains a third leg, is caught here rather than on a booted machine.
            $withPhase = @(Get-Command -Module 'Hephaestus' -CommandType Function |
                    Where-Object { $_.Parameters.ContainsKey('Phase') })

            $withPhase.Count | Should -BeGreaterThan 2 -Because 'the log path, the log context, the run state and the execution context all take one'

            $answer = @(
                (Get-HDTDeploymentPhase -SystemDrive 'X:'),
                (Get-HDTDeploymentPhase -SystemDrive 'C:')
            )

            foreach ($command in $withPhase) {
                $set = @($command.Parameters['Phase'].Attributes |
                        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })

                if ($set.Count -eq 0) { continue }

                foreach ($value in $answer) {
                    @($set[0].ValidValues) | Should -Contain $value -Because ('{0} -Phase would refuse the value Get-HDTDeploymentPhase returns' -f $command.Name)
                }
            }
        }
    }

    Context 'what it says about itself' {

        It 'has comment-based help naming the evidence and both phases' {
            $help = Get-Help -Name 'Get-HDTDeploymentPhase' -Full

            $help.Synopsis | Should -Not -BeNullOrEmpty
            $description = ($help.Description | Out-String)

            $description | Should -Match 'WinPE'
            $description | Should -Match 'FullOS'
            $description | Should -Match 'X:'
        }
    }
}
