# THE ZERO-KEYSTROKE CLAIM, MADE CHECKABLE WITHOUT HYPER-V.
#
# tests/e2e/UnattendedDeployment.E2E.Tests.ps1 is ROADMAP M4's exit criterion:
# a VM boots the ISO Update-HDTBootImage produced and deploys Windows 11 with
# ZERO KEYSTROKES SENT TO IT. That run takes about half an hour, needs elevation,
# Hyper-V and 30 GB of disk, and is executed on the days somebody remembers.
#
# A CLAIM A SUITE MAKES ABOUT ITSELF MUST BE CHECKABLE WITHOUT RUNNING IT. So
# this file parses that one and asserts the properties that make the claim true -
# in three seconds, in the fast suite, on every commit. It is the same technique
# tests/unit/StartHDTLabDeploymentPayload.Tests.ps1 uses on the M3 launcher, for
# the same reason.
#
# WHAT IT ASSERTS, AND WHY EACH ONE IS HERE:
#
#   * no Send-HDTLabVmText, no TypeText, no TypeKey, no Msvm_Keyboard - four
#     separate assertions with four separate messages, so a failure says WHICH
#     one crept back in. SPIKES S4 records those as the technique phase 04 used
#     to type one line at the WinPE prompt; M4's whole point is that nobody
#     types it;
#   * it boots the ISO the code built, not SPIKES S1/S3's hand-built artifact -
#     a run against the spike ISO would prove the harness works and say nothing
#     about Update-HDTBootImage;
#   * PROJECT.md's lab safety rules, every one of them, over the token stream:
#     module-qualified Hyper-V calls (S9.9 - PowerCLI shadows Get-VM on this
#     host), no unfiltered Get-VM, VMs only through New-HDTLabVirtualMachine, and
#     THE 'HDT Lab' SWITCH AND NOTHING ELSE. That last one matters most in this
#     plan: the temptation to reach a host share is exactly what rule 2 exists to
#     resist;
#   * SPIKES S9.15's skip condition recomputed inside BeforeAll;
#   * deliverable 7's relocated log, named, so it cannot be quietly dropped;
#   * A VOLUME-RELATIVE deployRoot. This is a three-second test standing in front
#     of a twenty-five-minute one. SPIKES S9.1: WinPE gave the content disk C:
#     and the RAM disk X:, and a boot image built with a LETTERED deployRoot
#     would boot, find nothing and shut the machine down - which looks exactly
#     like the success path from outside, because the discriminator for the whole
#     plan is "the VM powered itself off".
#
# THE SCAN IS OVER THE COMMENT-FREE TOKEN STREAM. The E2E's own header says in
# prose that it types nothing, and a raw text scan would fail on that sentence -
# which would teach the next author to delete the sentence rather than keep the
# property.

BeforeDiscovery {
    # Discovery-time, and deliberately not a $script: variable read later from
    # BeforeAll (SPIKES S9.15): -Skip: on a Context is evaluated HERE, and
    # BeforeAll recomputes what it needs for itself.
    $script:e2eExists = Test-Path -LiteralPath (
        Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'tests/e2e/UnattendedDeployment.E2E.Tests.ps1') -PathType Leaf
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:e2ePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e/UnattendedDeployment.E2E.Tests.ps1'

    $script:exists = Test-Path -LiteralPath $script:e2ePath -PathType Leaf

    # Assigned before the read, never inside it: a $null here would make
    # @($script:parseError).Count report 1 for a file that was never parsed
    # (SPIKES S9.15b).
    $script:parseError = @()
    $script:token = $null
    $script:ast = $null
    $script:text = ''
    $script:codeOnly = ''

    if ($script:exists) {
        $error1 = $null
        $token1 = $null

        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:e2ePath, [ref] $token1, [ref] $error1)

        $script:token = $token1
        $script:parseError = @($error1)
        $script:text = [System.IO.File]::ReadAllText($script:e2ePath)

        $script:codeOnly = (@($script:token |
                    Where-Object { $_.Kind -ne 'Comment' } |
                    ForEach-Object { [string] $_.Text }) -join ' ')
    }

    $script:commandNamed = {
        param([string] $Name)

        if ($null -eq $script:ast) { return @() }

        $wanted = $Name

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true))
    }

    $script:everyCommand = @()
    if ($null -ne $script:ast) {
        $script:everyCommand = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))
    }

    $script:everyCommandName = @($script:everyCommand |
            ForEach-Object { [string] $_.GetCommandName() } | Where-Object { $_ })

    # The Hyper-V commands a lab E2E plausibly reaches for. Any of these written
    # WITHOUT the Hyper-V\ prefix is SPIKES S9.9's trap: PowerCLI is installed on
    # this host and shadows Get-VM, Start-VM, Stop-VM and New-VM.
    $script:hyperVCommand = @(
        'Get-VM', 'New-VM', 'Remove-VM', 'Start-VM', 'Stop-VM', 'Set-VM',
        'Get-VMFirmware', 'Set-VMFirmware', 'Get-VMNetworkAdapter', 'Add-VMNetworkAdapter',
        'Connect-VMNetworkAdapter', 'Add-VMHardDiskDrive', 'Remove-VMHardDiskDrive',
        'Add-VMDvdDrive', 'Set-VMDvdDrive', 'Get-VMDvdDrive', 'Remove-VMDvdDrive',
        'New-VHD', 'Get-VHD', 'Get-VMIntegrationService', 'Get-VMSwitch', 'Set-VMProcessor',
        'Set-VMMemory', 'Get-VMHardDiskDrive', 'Checkpoint-VM', 'Restore-VMCheckpoint'
    )
}

Describe 'the M4 E2E exists at all' {

    It 'exists at tests/e2e/UnattendedDeployment.E2E.Tests.ps1' {
        # THE GUARD ON EVERYTHING BELOW. Every other assertion in this file scans
        # a token stream, and a token stream from a file that is not there is
        # empty - which would satisfy every "names no ..." assertion for the
        # wrong reason (tests/helpers/README.md section 12, SPIKES S9.15b). The
        # Contexts below are skipped while this is red, so a run of this file
        # reads "1 failed, N skipped" rather than "all green, nothing scanned".
        Test-Path -LiteralPath $script:e2ePath -PathType Leaf | Should -BeTrue -Because (
            'ROADMAP M4''s exit criterion has no executable form without it')
    }
}

Describe 'the M4 E2E, parsed' -Skip:(-not $script:e2eExists) {

    It 'parses with no error' {
        @($script:parseError).Count | Should -Be 0 -Because (
            (@($script:parseError | ForEach-Object { $_.Message }) -join "`n"))
    }

    It 'scanned something' {
        # ANTI-VACUITY, and asserted on a floor rather than on -gt 0: SPIKES
        # S9.15b records that @($null).Count is 1, so a count above zero can be
        # fabricated by coercion. A 300-line E2E cannot tokenise to under 500.
        $script:codeOnly.Length | Should -BeGreaterThan 4000
        @($script:everyCommandName).Count | Should -BeGreaterThan 40
    }

    Context 'it sends no keyboard input' {

        It 'names no Send-HDTLabVmText' {
            $script:codeOnly | Should -Not -Match 'Send-HDTLabVmText' -Because (
                'the M3 E2E typed one line at the WinPE prompt because the boot image predated the engine; startnet.cmd launches the payload now, and a harness that still typed would prove nothing about that')
        }

        It 'names no TypeText' {
            $script:codeOnly | Should -Not -Match 'TypeText' -Because (
                'SPIKES S4''s Msvm_Keyboard.TypeText is how phase 04 drove the VM. This phase''s VM is driven by nothing')
        }

        It 'names no TypeKey' {
            $script:codeOnly | Should -Not -Match 'TypeKey' -Because (
                'Msvm_Keyboard.TypeKey sends the Return that started the M3 run. Nothing presses Return here')
        }

        It 'names no Msvm_Keyboard' {
            $script:codeOnly | Should -Not -Match 'Msvm_Keyboard' -Because (
                'the keyboard class itself. Reaching for it at all is the thing this milestone eliminated')
        }

        It 'names none of the four in its comments either' {
            # THE CHECK A HUMAN CAN PERFORM, MADE PERMANENT.
            #
            # Everything above scans the comment-free token stream, and that is
            # the right scan: a file's header should be able to discuss the
            # property it holds, and a raw-text assertion would teach the next
            # author to delete the sentence rather than keep the property.
            #
            # But 05-05's verification asks a human to run a plain
            # Select-String over the E2E for these four names and expect nothing
            # back, because that is the simplest check anybody can perform
            # without this suite. A header that spelled them would make that
            # check report a hit on a file that is perfectly correct, and a
            # verification step that cries wolf is one nobody runs twice.
            #
            # So the names live HERE, in the file whose job is to name them, and
            # the E2E's header points at this one instead. This assertion is what
            # keeps that arrangement true.
            foreach ($name in @('Send-HDTLabVmText', 'TypeText', 'TypeKey', 'Msvm_Keyboard')) {
                $script:text | Should -Not -Match ([regex]::Escape($name)) -Because (
                    "a plain Select-String for '{0}' over the E2E must come back empty" -f $name)
            }
        }

        It 'names no switch but HDT Lab, in its comments either' {
            # Same arrangement, same reason (PROJECT.md rule 2). The three
            # forbidden switch names are written out in tests/e2e/README.md and
            # in this file, and not in the E2E.
            foreach ($switch in @('Default Switch', 'HDT External', 'FSE Switch')) {
                $script:text | Should -Not -Match ([regex]::Escape($switch)) -Because (
                    "a plain Select-String for '{0}' over the E2E must come back empty" -f $switch)
            }
        }
    }

    Context 'it boots the ISO the code built' {

        It 'boots the ISO Update-HDTBootImage produced' {
            @(& $script:commandNamed 'Update-HDTBootImage').Count | Should -BeGreaterOrEqual 1 -Because (
                'the exit criterion is about an ISO HDT built, not about a harness that boots something')
        }

        It 'does not boot the hand-built spike ISO' {
            # SPIKES S1/S3's artifact still exists at that path, and booting it
            # would produce a green run that said nothing about phase 05's code.
            $script:codeOnly | Should -Not -Match ([regex]::Escape('HDTPE_x64_uefi.iso')) -Because (
                'C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso is SPIKES S1/S3''s hand-built image')
        }

        It 'matches the ISO against the manifest' {
            $script:codeOnly | Should -Match 'isoBootWimSha256|artifacts' -Because (
                'the ISO under test is tied to the build by hash, not by filename')
        }
    }

    Context 'PROJECT.md lab safety' {

        It 'creates every VM through New-HDTLabVirtualMachine' {
            @(& $script:commandNamed 'New-HDTLabVirtualMachine').Count | Should -BeGreaterOrEqual 1

            # Assert-HDTLabVmName runs inside that helper, before the first
            # Hyper-V call, and tests/unit/New-HDTLabVirtualMachine.Tests.ps1
            # proves the refusals. A bare New-VM would bypass all of it.
            @($script:everyCommandName | Where-Object { $_ -eq 'Hyper-V\New-VM' -or $_ -eq 'New-VM' }) |
                Should -BeNullOrEmpty -Because 'a VM created outside the helper is a VM created without the name guard'
        }

        It 'module-qualifies every Hyper-V command' {
            # SPIKES S9.9: PowerCLI is installed on this host and shadows Get-VM.
            # An unqualified call may resolve to the wrong module entirely.
            $bare = @($script:everyCommandName | Where-Object { $script:hyperVCommand -contains $_ })

            $bare | Should -BeNullOrEmpty -Because (
                'unqualified: {0}. Write Hyper-V\<command>' -f ($bare -join ', '))
        }

        It 'filters every Get-VM, or filters the pipeline it feeds' {
            # PROJECT.md rule 1. An unfiltered pipeline is how a lab loses a VM
            # nobody meant to touch.
            #
            # THE ONE EXEMPTION IS THE READ-ONLY LAB-SAFETY SNAPSHOT, and it has
            # to exist: you cannot prove you left the other VMs alone without
            # listing them, and listing them by name is what rotted - the two
            # names this file used to demand were retired on 2026-08-29, leaving
            # a snapshot that compared an empty array with an empty array. So an
            # unfiltered Get-VM is allowed ONLY when its own pipeline immediately
            # discards everything named HDT-*, which is a read, never an act.
            $unfiltered = @(& $script:commandNamed 'Hyper-V\Get-VM' | Where-Object {
                    @($_.CommandElements | ForEach-Object { [string] $_.Extent.Text }) -notcontains '-Name' -and
                    [string] $_.Parent.Extent.Text -notmatch "notlike\s+'HDT-"
                })

            @($unfiltered | ForEach-Object { [string] $_.Extent.Text }) | Should -BeNullOrEmpty
        }

        It 'snapshots every VM it does not own before it starts' {
            # A SET, NOT A LIST OF NAMES. This assertion used to demand the
            # literal strings for two VMs that were retired on 2026-08-29, and a
            # suite that names the machines it protects protects nothing the day
            # one of them goes away. Do not put names back.
            $script:codeOnly | Should -Match "notlike\s+'HDT-"
        }

        It 'reads MemoryStartup and not MemoryStartupBytes off the snapshot' {
            # SPIKES S9.14: Get-VM returns MemoryStartup; New-VM takes a
            # -MemoryStartupBytes PARAMETER. Reading the parameter name off the
            # object gave $null, [long] $null is 0, and the assertion that
            # protects the user's live lab compared 0 with 0 for six green runs.
            $script:codeOnly | Should -Match 'MemoryStartup\b'
            $script:codeOnly | Should -Not -Match '\$_\.MemoryStartupBytes'
        }

        It 'asserts them identical in an AfterAll' {
            $afterAll = @(& $script:commandNamed 'AfterAll')
            $afterAll.Count | Should -BeGreaterOrEqual 1 -Because 'it has to run even when the test failed'

            $script:codeOnly | Should -Match 'protectedBefore|snapshotProtected'
        }

        It 'names only the HDT Lab switch' {
            # THE ONE THAT MATTERS MOST IN THIS PLAN. SPIKES S6 records that a VM
            # on the isolated switch cannot reach a share on the host, and the
            # temptation to move it somewhere it can is exactly what PROJECT.md
            # rule 2 exists to resist. Moving a test VM to reach an SMB share
            # would also move it off the isolated segment this phase was
            # verified on, which invalidates the verification.
            $script:codeOnly | Should -Match 'HDT Lab'

            foreach ($switch in @('Default Switch', 'HDT External', 'FSE Switch')) {
                $script:codeOnly | Should -Not -Match ([regex]::Escape($switch)) -Because (
                    "'{0}' is not the isolated lab switch (PROJECT.md rule 2)" -f $switch)
            }
        }

        It 'keeps its files under C:\HDTLab\vms' {
            $script:codeOnly | Should -Match ([regex]::Escape('C:\HDTLab\vms'))
        }

        It 'removes the VM through Remove-HDTLabVirtualMachine' {
            @(& $script:commandNamed 'Remove-HDTLabVirtualMachine').Count | Should -BeGreaterOrEqual 1
            @($script:everyCommandName | Where-Object { $_ -eq 'Hyper-V\Remove-VM' -or $_ -eq 'Remove-VM' }) |
                Should -BeNullOrEmpty -Because 'Assert-HDTLabVmPath stands in front of the delete inside the helper (SPIKES S9.13)'
        }
    }

    Context 'the skip condition' {

        It 'recomputes its skip condition inside BeforeAll' {
            # SPIKES S9.15. Pester's discovery and run phases do not share a
            # scope; without StrictMode the read evaluates to $null and
            # 'if (-not $null)' is TRUE, so the expensive body runs on a machine
            # that was supposed to be skipping it.
            $violation = @(Get-HDTSlowSuiteSkipViolation -Path $script:e2ePath)

            @($violation | ForEach-Object { '{0}({1}): ${2}' -f $_.Path, $_.Line, $_.Variable }) |
                Should -BeNullOrEmpty
        }

        It 'has a BeforeAll that computes the condition itself' {
            $beforeAll = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'BeforeAll'
                    }, $true))

            $beforeAll.Count | Should -BeGreaterOrEqual 1

            # The outermost BeforeAll is the longest one. ASSIGNED FIRST, WRAPPED
            # SECOND (tests/helpers/README.md F12): Sort-Object returns a SCALAR
            # for a one-element input, and indexing [0] into a scalar string
            # yields its first CHARACTER - which is 'B', and which matched
            # nothing while looking like it had found a body.
            $sorted = @($beforeAll | ForEach-Object { [string] $_.Extent.Text } |
                    Sort-Object -Property Length -Descending)

            $sorted.Count | Should -BeGreaterThan 0
            $sorted[0].Length | Should -BeGreaterThan 200 -Because 'a one-character "body" is the scalar-indexing trap, not a BeforeAll'

            $sorted[0] | Should -Match 'Test-Path' -Because 'the condition has to be recomputed here, not read across the discovery boundary'
        }
    }

    Context 'what the run has to prove' {

        It 'asserts the relocated WinPE log on the deployed volume' {
            # DELIVERABLE 7. 05-03's Set-HDTLogPath mirrors the log tree onto the
            # volume the deployment just formatted; without this assertion the
            # difference between "the logs were written" and "the logs survived
            # the machine" is never checked.
            $script:codeOnly | Should -Match ([regex]::Escape('HDT\Logs\HDT.jsonl'))
        }

        It 'asserts launchedBy startnet' {
            # 05-04's startnet.cmd sets HDT_LAUNCHED_BY=startnet and 05-03's
            # payload records it. A hand-typed launch leaves it empty, so this
            # one field is the guest's own statement about who started it.
            $script:codeOnly | Should -Match 'launchedBy'
            $script:codeOnly | Should -Match 'startnet'
        }

        It 'builds a workspace whose deployRoot is volume-relative' {
            # SPIKES S9.1, AND THE SINGLE LIKELIEST WAY THIS RUN FAILS. WinPE
            # chooses the content disk's letter; a lettered deployRoot baked into
            # the image would boot, find nothing and power the machine off, which
            # from outside is indistinguishable from success.
            $workspaceYaml = @([regex]::Matches($script:text, 'deployRoot:\s*(?<value>\S+)'))

            $workspaceYaml.Count | Should -BeGreaterThan 0 -Because 'the E2E writes its own workspace.yaml'

            foreach ($match in $workspaceYaml) {
                [string] $match.Groups['value'].Value | Should -Not -Match '^[A-Za-z]:' -Because (
                    'a drive letter here is the one edit that makes this whole demonstration fail in the way that looks most like success')
            }
        }

        It 'asserts deployRootSource Discovered' {
            $script:codeOnly | Should -Match 'deployRootSource'
            $script:codeOnly | Should -Match 'Discovered'
        }

        It 'reads the result off the content disk rather than off X:' {
            # X: is the RAM disk and it dies with the power-off the payload
            # performs. A harness that read RESULT.json from there would read
            # nothing (05-03's payload writes both, deploy root first).
            $script:codeOnly | Should -Match 'RESULT.json'
            $script:codeOnly | Should -Not -Match ([regex]::Escape('X:\HDT\RESULT.json'))
        }

        It 'ends by waiting for Off rather than by sleeping' {
            # THE DISCRIMINATOR. Nothing types, so a startnet.cmd that did not
            # launch the payload leaves the VM at a WinPE prompt and the wait
            # times out. A fixed sleep would report the same thing either way.
            @(& $script:commandNamed 'Wait-HDTLabVmState').Count | Should -BeGreaterOrEqual 1
        }
    }
}
