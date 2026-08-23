# THE ENGINE TELLING THE SCREEN WHAT IT JUST DID.
#
# DESIGN 11.1: "The UI subscribes to that stream and renders it. There is
# exactly one source of truth for what the deployment is doing, so the screen
# and the log can never disagree."
#
# THIS IS THE SUBSCRIPTION, and it is deliberately the dullest possible one: the
# engine has just written a record to the JSONL, so this reads the JSONL back,
# derives progress from it and hands that to whatever host is attached. No
# second channel, no progress API a step could call, nothing the log does not
# already say.
#
# IT MUST NEVER FAIL A DEPLOYMENT. It runs inside the step loop, on a machine
# that is partitioning disks. A log line that will not parse, a file that has
# gone with the RAM disk, a UI thread that has died - none of those are a reason
# to stop building a computer, and every one of them is a reason nobody would
# ever guess from the outside.
#
# NO PROGRESS SERVICE IS THE NORMAL CASE. Every existing sequence test runs
# without one, and this must cost them nothing.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:jsonlPath = 'X:\HDT\Logs\HDT.jsonl'

    function New-HDTProgressJsonl {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Extra = ''
        )

        $line = @(
            '{"ts":"2026-08-16T09:00:00.0000000Z","runId":"r-1","seq":1,"level":"Info","phase":"WinPE","component":"Engine","event":"run.start","message":"starting","data":{"sequenceId":"STD-CLIENT","stepIndex":0,"stepCount":3,"leg":1}}'
            '{"ts":"2026-08-16T09:00:01.0000000Z","runId":"r-1","seq":2,"level":"Info","phase":"WinPE","stepIndex":1,"stepName":"Partition disk","stepType":"DiskPartition","component":"Engine","event":"step.start","message":"starting","data":{"index":1,"name":"Partition disk","type":"DiskPartition","attempt":1}}'
            '{"ts":"2026-08-16T09:00:20.0000000Z","runId":"r-1","seq":3,"level":"Info","phase":"WinPE","stepIndex":1,"stepName":"Partition disk","stepType":"DiskPartition","component":"Engine","event":"step.complete","message":"done","data":{"index":1,"attempt":1,"exitCode":0}}'
        )

        if (-not [string]::IsNullOrWhiteSpace($Extra)) { $line += $Extra }

        return (($line -join "`n") + "`n")
    }

    function New-HDTProgressTestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test context; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowNull()]
            [object] $Progress,

            [Parameter()]
            [AllowNull()]
            [object] $FileSystem,

            [Parameter()]
            [AllowEmptyString()]
            [string] $JsonlPath = $script:jsonlPath
        )

        $fs = $FileSystem
        if ($null -eq $fs) {
            $fs = New-HDTFakeFileSystem -File @{ $script:jsonlPath = (New-HDTProgressJsonl) }
        }

        return [pscustomobject] @{
            Log     = [pscustomobject] @{ JsonlPath = $JsonlPath; FileSystem = $fs }
            Service = [pscustomobject] @{ Progress = $Progress }
        }
    }
}

Describe 'Update-HDTProgressDisplay' {

    Context 'the command exists' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Update-HDTProgressDisplay' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'with a display attached' {

        It 'hands it what the log says' {
            $display = New-HDTFakeProgressHost

            Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $display)

            @($display.Operations | Where-Object { $_ -eq 'Update' }).Count | Should -Be 1
            [string] $display.LastProgress.SequenceId | Should -BeExactly 'STD-CLIENT'
        }

        It 'derives the same answer Get-HDTDeploymentProgress would, because it is the same command' {
            $display = New-HDTFakeProgressHost

            Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $display)

            [int] $display.LastProgress.StepNumber | Should -Be 1
            [int] $display.LastProgress.StepCount | Should -Be 3
            [int] $display.LastProgress.CompletedCount | Should -Be 1
            [string] $display.LastProgress.Phase | Should -BeExactly 'WinPE'
        }

        It 'follows the log as it grows' {
            $display = New-HDTFakeProgressHost
            $extra = '{"ts":"2026-08-16T09:00:21.0000000Z","runId":"r-1","seq":4,"level":"Info","phase":"WinPE","stepIndex":2,"stepName":"Apply image","stepType":"ApplyImage","component":"Engine","event":"step.start","message":"starting","data":{"index":2,"name":"Apply image","type":"ApplyImage","attempt":1}}'

            $fs = New-HDTFakeFileSystem -File @{ $script:jsonlPath = (New-HDTProgressJsonl -Extra $extra) }

            Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $display -FileSystem $fs)

            [string] $display.LastProgress.StepName | Should -BeExactly 'Apply image'
        }
    }

    Context 'with no display attached, which is every run that was never asked for one' {

        It 'does nothing and says nothing' {
            { Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $null) } | Should -Not -Throw
        }

        It 'does not read the log it has nobody to show' {
            # A read per step on a machine with no screen is pure cost, and the
            # log lives on a RAM disk that may already have moved.
            $fs = New-HDTFakeFileSystem -File @{}

            { Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $null -FileSystem $fs) } |
                Should -Not -Throw
        }
    }

    Context 'everything that can go wrong while a disk is being partitioned' {

        It 'survives a log that is not there' {
            $display = New-HDTFakeProgressHost
            $fs = New-HDTFakeFileSystem -File @{}

            { Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $display -FileSystem $fs) } |
                Should -Not -Throw
        }

        It 'survives a line that will not parse, and still renders the rest' {
            # A JSONL a machine was cut off in the middle of writing has a half
            # line at the end. The window showing the run that died must not be
            # the second thing that dies.
            $display = New-HDTFakeProgressHost
            $fs = New-HDTFakeFileSystem -File @{ $script:jsonlPath = (New-HDTProgressJsonl -Extra '{"ts":"2026-08-16T09:00:2') }

            Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $display -FileSystem $fs)

            @($display.Operations | Where-Object { $_ -eq 'Update' }).Count | Should -Be 1
            [string] $display.LastProgress.SequenceId | Should -BeExactly 'STD-CLIENT'
        }

        It 'survives a display that throws when it is updated' {
            # A UI thread that has died must not take the deployment with it.
            $display = New-HDTFakeProgressHost
            $display | Add-Member -MemberType ScriptMethod -Name Update -Force -Value {
                param([object] $Progress)

                # The argument is named in the message so this double is a
                # faithful replacement rather than a signature the analyzer
                # reports as taking something it never looks at.
                throw ('the window has gone, and it was told about step {0}' -f $Progress.StepNumber)
            }

            { Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $display) } | Should -Not -Throw
        }

        It 'survives a context with no log at all' {
            $context = [pscustomobject] @{
                Log     = $null
                Service = [pscustomobject] @{ Progress = (New-HDTFakeProgressHost) }
            }

            { Update-HDTProgressDisplay -Context $context } | Should -Not -Throw
        }

        It 'survives a context with no service catalog at all' {
            $context = [pscustomobject] @{ Log = $null }

            { Update-HDTProgressDisplay -Context $context } | Should -Not -Throw
        }

        It 'survives an empty log file' {
            $display = New-HDTFakeProgressHost
            $fs = New-HDTFakeFileSystem -File @{ $script:jsonlPath = '' }

            { Update-HDTProgressDisplay -Context (New-HDTProgressTestContext -Progress $display -FileSystem $fs) } |
                Should -Not -Throw
        }
    }
}


}
