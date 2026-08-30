# DESIGN 9.3: generalize the reference machine, then let a separate Restart step
# take it to WinPE so the capture can read it.
#
# THE SWITCH IS /quit AND NEVER /shutdown, and that is the first thing this file
# asserts. MDT settled it in LTISysprep.wsf:257 and DESIGN 9.3 note 1 gives the
# reasoning: a step whose only outcome is "the power went out" reports the same
# thing whether it worked or not, and it bypasses the checkpoint the resume
# depends on.
#
# AND AN EXIT CODE OF ZERO IS NOT EVIDENCE. sysprep can return 0 having declined
# to generalize, so the step reads ImageState afterwards and fails unless the
# machine actually reached IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE. This is the
# same failure family as reagentc /setreimage, which exits 0, prints "Operation
# Successful" and registers nothing (DESIGN 9.2 note 5) - a tool that reports
# success is not evidence that the thing happened.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:sysprepExe = 'C:\Windows\system32\sysprep\sysprep.exe'
    $script:sysprepArgument = '/quiet /generalize /oobe /quit'
    $script:sysprepCommand = '{0} {1}' -f $script:sysprepExe, $script:sysprepArgument

    $script:setupStateKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
    $script:sessionManagerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

    # A WORKGROUP MACHINE, WHICH IS THE ONLY KIND SYSPREP WILL GENERALIZE.
    # DomainRole 2 is Standalone Server; 0 and 1 are the workstation pair, of
    # which 1 - Member Workstation - is already a refusal.
    $script:workgroup = @([pscustomobject] @{
            Name = 'REF-BUILD-01'; Domain = 'WORKGROUP'; DomainRole = 2; PartOfDomain = $false
        })

    $script:newStep = {
        param([System.Collections.IDictionary] $Property, [int] $TimeoutMinute = 60)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 9; Name = 'Sysprep'; Type = 'Sysprep'; TimeoutMinutes = $TimeoutMinute
            Log = $null; Property = $bag
        }
    }
}

Describe 'Invoke-HDTSysprepStep' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 31, 10, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 500

        # THE MACHINE AS IT IS THE INSTANT SYSPREP RETURNS: generalized, sealed,
        # waiting for OOBE on the next boot of Windows - which a reference build
        # never gives it, because the boot media comes first.
        $script:registry = New-HDTFakeRegistryService -Value @{
            $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
        }

        $script:process = New-HDTFakeProcessService -Result @{
            $script:sysprepCommand = @{ ExitCode = 0; StandardOutput = '' }
        }

        $script:cim = New-HDTFakeCimProvider -Instance @{ 'Win32_ComputerSystem' = $script:workgroup }
        $script:lsa = New-HDTFakeLsaService
        $script:environment = New-HDTFakeEnvironmentProvider -Variable @{ SystemRoot = 'C:\Windows' }

        $script:newContext = {
            param([System.Collections.IDictionary] $Variable)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Registry $script:registry -Process $script:process -Cim $script:cim `
                -Lsa $script:lsa -Environment $script:environment

            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:context = & $script:newContext $null
    }

    Context 'the command line' {

        It 'runs sysprep out of the system32 folder, generalizing to OOBE' {
            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $script:context

            $result.Status | Should -BeExactly 'Completed'

            $start = @($script:process.Operations | Where-Object { $_.Operation -eq 'Start' })
            @($start).Count | Should -Be 1
            [string] $start[0].Arguments[0] | Should -BeExactly $script:sysprepExe
        }

        It 'never passes /shutdown' {
            # DESIGN 9.3 note 1. /shutdown cuts the power inside the call, so the
            # step never returns, never reports and can check nothing - and it
            # bypasses the checkpoint the WinPE leg resumes from.
            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $script:context)

            $start = @($script:process.Operations | Where-Object { $_.Operation -eq 'Start' })
            [string] $start[0].Arguments[1] | Should -Not -BeLike '*shutdown*'
        }

        It 'passes the four switches MDT passes, in MDT s order' {
            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $script:context)

            $start = @($script:process.Operations | Where-Object { $_.Operation -eq 'Start' })
            [string] $start[0].Arguments[1] | Should -BeExactly $script:sysprepArgument
        }

        It 'reads the Windows folder from the environment rather than assuming C:' {
            $script:environment = New-HDTFakeEnvironmentProvider -Variable @{ SystemRoot = 'D:\WINDOWS' }
            $script:process = New-HDTFakeProcessService -Result @{
                ('D:\WINDOWS\system32\sysprep\sysprep.exe {0}' -f $script:sysprepArgument) = @{ ExitCode = 0 }
            }
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Completed'
        }

        It 'turns the step s timeout into the process timeout' {
            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null 45) -Context $script:context)

            $start = @($script:process.Operations | Where-Object { $_.Operation -eq 'Start' })
            [int] $start[0].Arguments[3] | Should -Be (45 * 60000)
        }
    }

    Context 'the answer file' {

        It 'appends /unattend: when one is configured' {
            $script:fileSystem.WriteAllText('Z:\Deploy\TaskSequences\REF\sysprep-unattend.xml', '<unattend/>')

            $staged = 'C:\Windows\system32\sysprep\unattend.xml'
            $script:process = New-HDTFakeProcessService -Result @{
                ('{0} {1} /unattend:{2}' -f $script:sysprepExe, $script:sysprepArgument, $staged) = @{ ExitCode = 0 }
            }
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep ([ordered] @{
                        unattend = 'Z:\Deploy\TaskSequences\REF\sysprep-unattend.xml'
                    })) -Context $context

            $result.Status | Should -BeExactly 'Completed'
        }

        It 'stages it where sysprep looks, not where the author kept it' {
            $script:fileSystem.WriteAllText('Z:\Deploy\TaskSequences\REF\sysprep-unattend.xml', '<unattend/>')

            $staged = 'C:\Windows\system32\sysprep\unattend.xml'
            $script:process = New-HDTFakeProcessService -Result @{
                ('{0} {1} /unattend:{2}' -f $script:sysprepExe, $script:sysprepArgument, $staged) = @{ ExitCode = 0 }
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep ([ordered] @{
                            unattend = 'Z:\Deploy\TaskSequences\REF\sysprep-unattend.xml'
                        })) -Context $context)

            @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'CopyItem' }).Count |
                Should -BeGreaterThan 0
        }

        It 'removes the staged answer file so it does not travel inside the image' {
            # MDT deletes it after the call for exactly this reason
            # (LTISysprep.wsf). A reference image carrying one site's answer file
            # answers Setup on every machine ever built from it.
            $script:fileSystem.WriteAllText('Z:\Deploy\TaskSequences\REF\sysprep-unattend.xml', '<unattend/>')

            $staged = 'C:\Windows\system32\sysprep\unattend.xml'
            $script:process = New-HDTFakeProcessService -Result @{
                ('{0} {1} /unattend:{2}' -f $script:sysprepExe, $script:sysprepArgument, $staged) = @{ ExitCode = 0 }
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep ([ordered] @{
                            unattend = 'Z:\Deploy\TaskSequences\REF\sysprep-unattend.xml'
                        })) -Context $context)

            $script:fileSystem.TestPath($staged) | Should -BeFalse
        }

        It 'refuses an answer file that is not there, by name' {
            $result = Invoke-HDTSysprepStep -Step (& $script:newStep ([ordered] @{
                        unattend = 'Z:\Deploy\TaskSequences\REF\missing.xml'
                    })) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*missing.xml*'
        }

        It 'runs sysprep with no /unattend: at all when none is configured' {
            # The seeded command line above carries no /unattend:, so a step that
            # invented one would meet an unseeded command and throw.
            (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $script:context).Status |
                Should -BeExactly 'Completed'
        }
    }

    Context 'proving the capture can be written, before the point of no return' {

        # DESIGN 9.3 note 5, and ROADMAP M7's capture exit in its own words:
        # "the Captures\ write was proven BEFORE sysprep ran, not after the
        # build". Sysprep is where a reference build stops being recoverable -
        # the machine is generalized and cannot be picked up where it left off -
        # so a share that cannot take the image has to be found out here.

        It 'probes Captures\ before it starts sysprep' {
            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $script:context)

            @($script:fileSystem.Operations |
                    Where-Object { $_.Operation -eq 'WriteAllText' -and [string] $_.Arguments[0] -like 'Z:\Deploy\Captures\*' }) |
                Should -Not -BeNullOrEmpty
        }

        It 'refuses, and generalizes nothing, when the account cannot write Captures\' {
            # THE WHOLE POINT. A machine sealed against a share that will not
            # take the image is hours of work with no way back.
            $failing = New-HDTFakeFileSystem -WriteFailure @{
                'Z:\Deploy\Captures\.hdt-write-probe-run-0001.tmp' = 'Access to the path is denied.'
            }

            $catalog = New-HDTServiceCatalog -FileSystem $failing -Clock $script:clock `
                -Registry $script:registry -Process $script:process -Cim $script:cim `
                -Lsa $script:lsa -Environment $script:environment

            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'Z:\Deploy' `
                -Variable ([System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)) `
                -Service $catalog -Log $log

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Captures*'
            @($script:process.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'refuses under the Local provider, where there is nowhere to capture to' {
            $media = New-HDTFakeContentProvider -Root 'D:\Deploy' -Kind Local

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Registry $script:registry -Process $script:process -Cim $script:cim `
                -Lsa $script:lsa -Environment $script:environment -Content $media

            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'D:\Deploy' `
                -Variable ([System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)) `
                -Service $catalog -Log $log

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*media*'
            @($script:process.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'leaves no probe file behind in Captures\' {
            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $script:context)

            $script:fileSystem.TestPath('Z:\Deploy\Captures\.hdt-write-probe-run-0001.tmp') | Should -BeFalse
        }
    }

    Context 'a domain member' {

        # MDT CHECKS Win32_ComputerSystem.DomainRole AND SO DOES THIS. sysprep
        # will not generalize a domain member, and finding that out from sysprep
        # is finding it out at the end of a reference build.
        It 'refuses DomainRole <Role>, which is <Meaning>' -ForEach @(
            @{ Role = 1; Meaning = 'a member workstation' }
            @{ Role = 3; Meaning = 'a member server' }
            @{ Role = 4; Meaning = 'a backup domain controller' }
            @{ Role = 5; Meaning = 'a primary domain controller' }
        ) {
            $script:cim = New-HDTFakeCimProvider -Instance @{
                'Win32_ComputerSystem' = @([pscustomobject] @{
                        Name = 'REF-BUILD-01'; Domain = 'contoso.com'; DomainRole = $Role; PartOfDomain = $true
                    })
            }
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*domain*'
        }

        It 'runs nothing at all when it refuses' {
            # THE REFUSAL IS A PRECONDITION, NOT A CLEAN-UP. A step that cleared
            # the autologon and then refused would have disarmed the resume of a
            # deployment that is still running.
            $script:cim = New-HDTFakeCimProvider -Instance @{
                'Win32_ComputerSystem' = @([pscustomobject] @{
                        Name = 'REF-BUILD-01'; Domain = 'contoso.com'; DomainRole = 3; PartOfDomain = $true
                    })
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context)

            @($script:process.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'accepts DomainRole <Role>, which is not domain-joined' -ForEach @(
            @{ Role = 0 }
            @{ Role = 2 }
        ) {
            $script:cim = New-HDTFakeCimProvider -Instance @{
                'Win32_ComputerSystem' = @([pscustomobject] @{
                        Name = 'REF-BUILD-01'; Domain = 'WORKGROUP'; DomainRole = $Role; PartOfDomain = $false
                    })
            }
            $context = & $script:newContext $null

            (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context).Status |
                Should -BeExactly 'Completed'
        }
    }

    Context 'a pending file rename' {

        # sysprep REFUSES on a machine with file renames queued for the next
        # boot, and MDT guards it with a once-only sentinel so a machine that
        # cannot clear the queue does not reboot for ever.
        It 'asks for a restart rather than running sysprep' {
            $script:registry = New-HDTFakeRegistryService -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
                $script:sessionManagerKey = @{ PendingFileRenameOperations = @('\??\C:\a.dll', '!\??\C:\b.dll') }
            }
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'RebootRequested'
            @($script:process.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'sets a sentinel so the next pass knows it has already restarted once' {
            $script:registry = New-HDTFakeRegistryService -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
                $script:sessionManagerKey = @{ PendingFileRenameOperations = @('\??\C:\a.dll') }
            }
            $variable = [ordered] @{}
            $context = & $script:newContext $variable

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context)

            [string] $context.Variable['HDTSysprepRestarted'] | Should -BeExactly 'true'
        }

        It 'refuses rather than restarting a second time' {
            # THE PING-PONG THIS EXISTS TO STOP. A machine whose rename queue
            # never clears would otherwise reboot on every pass for ever, and
            # every one of those passes looks like progress in the log.
            $script:registry = New-HDTFakeRegistryService -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
                $script:sessionManagerKey = @{ PendingFileRenameOperations = @('\??\C:\a.dll') }
            }
            $context = & $script:newContext ([ordered] @{ HDTSysprepRestarted = 'true' })

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*still*'
            @($script:process.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'runs when the queue is empty' {
            $script:registry = New-HDTFakeRegistryService -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
                $script:sessionManagerKey = @{ PendingFileRenameOperations = @() }
            }
            $context = & $script:newContext $null

            (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context).Status |
                Should -BeExactly 'Completed'
        }
    }

    Context "HDT's own resume hook" {

        # AN IMAGE THAT CARRIES THE HOOK RE-ENTERS A FINISHED DEPLOYMENT ON THE
        # FIRST BOOT OF EVERY MACHINE BUILT FROM IT. MDT strips LiteTouch.lnk
        # and RunOnce\LiteTouch here; HDT's equivalents are the Winlogon values,
        # RunOnce\HDTResume, the LSA secret Winlogon reads and the staged answer
        # files - which is exactly the set Clear-HDTAutoLogon removes.
        It 'clears the autologon before it generalizes' {
            $script:registry = New-HDTFakeRegistryService -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' = @{
                    AutoAdminLogon = '1'; DefaultUserName = 'Administrator'; AutoLogonCount = 1
                }
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' = @{ HDTResume = 'powershell.exe -File C:\HDT\Start-HDTResume.ps1' }
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context)

            $script:registry.GetValue('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', 'AutoAdminLogon') |
                Should -BeNullOrEmpty
            $script:registry.GetValue('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 'HDTResume') |
                Should -BeNullOrEmpty
        }

        It 'clears it BEFORE sysprep runs, not after' {
            # AFTERWARDS IS TOO LATE. The value has to be gone from the registry
            # at the moment the machine is generalized, because that registry is
            # what the capture reads.
            $script:registry = New-HDTFakeRegistryService -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' = @{ HDTResume = 'x' }
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context)

            $removed = @($script:registry.Operations | Where-Object { $_.Operation -eq 'RemoveValue' })
            @($removed).Count | Should -BeGreaterThan 0

            # The whole journal is one fake per service, so the ordering is
            # asserted against the process fake's own record instead: sysprep was
            # started exactly once, and every RemoveValue happened before the
            # step returned. The stronger claim - registry before process - is
            # the ordered-journal test below.
            @($script:process.Operations | Where-Object { $_.Operation -eq 'Start' }).Count | Should -Be 1
        }

        It 'clears the registry hook before it starts sysprep, in one ordered journal' {
            $journal = New-Object -TypeName System.Collections.ArrayList

            $script:registry = New-HDTFakeRegistryService -Journal $journal -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' = @{ HDTResume = 'x' }
            }
            $script:process = New-HDTFakeProcessService -Journal $journal -Result @{
                $script:sysprepCommand = @{ ExitCode = 0 }
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context)

            $order = @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation })

            $lastRemove = [array]::LastIndexOf($order, 'RegistryService.RemoveValue')
            $started = [array]::IndexOf($order, 'ProcessService.Start')

            $lastRemove | Should -BeGreaterThan -1
            $started | Should -BeGreaterThan $lastRemove
        }
    }

    Context 'what sysprep did, rather than what it returned' {

        It 'fails when ImageState says the machine was not generalized' {
            # THE POINT OF THE CHECK. sysprep exited 0 and generalized nothing,
            # which is a reference image that is a copy of one machine.
            $script:registry = New-HDTFakeRegistryService -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_COMPLETE' }
            }
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*IMAGE_STATE_COMPLETE*'
        }

        It 'names the log the reason is actually in' {
            $script:registry = New-HDTFakeRegistryService -Value @{
                $script:setupStateKey = @{ ImageState = 'IMAGE_STATE_COMPLETE' }
            }
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Message | Should -BeLike '*sysprep\panther\setupact.log*'
        }

        It 'fails when ImageState is missing entirely' {
            $script:registry = New-HDTFakeRegistryService
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*setupact.log*'
        }
    }

    Context 'a sysprep that failed on its own terms' {

        It 'fails on a non-zero exit code, naming it' {
            $script:process = New-HDTFakeProcessService -Result @{
                $script:sysprepCommand = @{ ExitCode = 31; StandardError = 'A fatal error occurred while trying to sysprep the machine.' }
            }
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.ExitCode | Should -Be 31
        }

        It "carries the tool's own output into the log" {
            # DESIGN 12.2.3: every native failure carries the tool's own output.
            # sysprep's one useful sentence is the one it printed.
            $script:process = New-HDTFakeProcessService -Result @{
                $script:sysprepCommand = @{ ExitCode = 31; StandardError = 'A fatal error occurred while trying to sysprep the machine.' }
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context)

            $text = [string] $script:fileSystem.ReadAllText('C:\HDT\Logs\HDT.log')
            $text | Should -BeLike '*A fatal error occurred while trying to sysprep the machine.*'
        }

        It 'reports a timeout as a failure and says how long it waited' {
            $script:process = New-HDTFakeProcessService -Result @{
                $script:sysprepCommand = @{ ExitCode = -1; TimedOut = $true }
            }
            $context = & $script:newContext $null

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null 60) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*60*'
        }

        It 'does not read ImageState after a failure, because there is nothing to read' {
            $script:process = New-HDTFakeProcessService -Result @{
                $script:sysprepCommand = @{ ExitCode = 31 }
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context)

            @($script:registry.Operations |
                    Where-Object { $_.Operation -eq 'GetValue' -and [string] $_.Arguments[1] -eq 'ImageState' }) |
                Should -BeNullOrEmpty
        }
    }

    Context 'saying something while it waits' {

        # sysprep IS SILENT FOR MINUTES. It prints no meter of any kind, so the
        # only honest thing the step can report is that the machine is still
        # alive and how long it has been - which is what the heartbeat says.
        It 'writes a progress record while sysprep is running' {
            $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 31, 10, 0, 0, [System.DateTimeKind]::Utc)) `
                -TickMillisecond 20000

            $script:process = New-HDTFakeProcessService -Result @{
                $script:sysprepCommand = @{ ExitCode = 0; TickCount = 6 }
            }
            $context = & $script:newContext $null

            [void] (Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context)

            @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'C:\HDT\Logs\HDT.jsonl' -Event 'step.progress') |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'a step with nothing configured and bare fakes' {

        It 'fails rather than throwing when the machine cannot even be read' {
            # The step contract: a minimal step against bare fakes returns a
            # result from the closed set. A machine whose Win32_ComputerSystem
            # cannot be read is a refusal naming that, not an exception.
            $catalog = New-HDTServiceCatalog -FileSystem (New-HDTFakeFileSystem) -Clock $script:clock `
                -Registry (New-HDTFakeRegistryService) -Process (New-HDTFakeProcessService) `
                -Cim (New-HDTFakeCimProvider)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'Z:\Deploy' `
                -Variable ([System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)) `
                -Service $catalog -Log $log

            $result = Invoke-HDTSysprepStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-HDTSysprepStepDescription' {

    It 'says what the step does, not what it is called' {
        $step = [pscustomobject] @{
            Index = 1; Name = 'Sysprep'; Type = 'Sysprep'; TimeoutMinutes = 0; Log = $null
            Property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        Get-HDTSysprepStepDescription -Step $step | Should -BeLike 'Sysprep*'
    }

    It 'names the answer file when one is configured' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['unattend'] = 'sysprep-unattend.xml'

        $step = [pscustomobject] @{
            Index = 1; Name = 'Sysprep'; Type = 'Sysprep'; TimeoutMinutes = 0; Log = $null; Property = $bag
        }

        Get-HDTSysprepStepDescription -Step $step | Should -BeLike '*sysprep-unattend.xml*'
    }
}

Describe 'Get-HDTSysprepStepTemplate' {

    It 'declares the type, so the console can offer it' {
        $line = @(Get-HDTSysprepStepTemplate)

        ($line -join "`n") | Should -BeLike '*type: Sysprep*'
    }

    It 'takes a name of its own' {
        $line = @(Get-HDTSysprepStepTemplate -Name 'Generalize the reference build')

        $line[0] | Should -BeExactly '- name: Generalize the reference build'
    }

    It 'runs in the full OS, which is the only place sysprep exists' {
        # A Sysprep step left to the default would run in WinPE, where
        # sysprep.exe is not present at all.
        ($line = @(Get-HDTSysprepStepTemplate)) | Out-Null

        ($line -join "`n") | Should -BeLike '*runIn: FullOS*'
    }
}
