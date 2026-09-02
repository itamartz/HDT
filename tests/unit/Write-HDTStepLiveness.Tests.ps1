# ONE WRITER FOR "THE MACHINE IS STILL ALIVE".
#
# step.progress carries two different things on purpose - how far through a step
# is, and that a step with nothing to count is still alive - and
# Get-HDTDeploymentProgress reads `percent` CONDITIONALLY so the second kind
# cannot drag a bar back to zero. The ABSENCE of percent is not something a
# reader can filter on, so `heartbeat = true` is the mark that makes the second
# kind readable, and New-HDTStepHeartbeat has written it since heartbeats
# existed.
#
# THEN TWO STEPS HAND-BUILT THE SAME RECORD AND THE TWO RULES COLLIDED.
# Sysprep writes one liveness record before it starts generalizing - there is no
# cadence involved, sysprep simply prints nothing for minutes and the card's last
# word would otherwise be the step's own name - and EnableBitLocker writes one
# per poll of a volume that reports no completion figure. Both had to carry the
# mark to be readable, and the heartbeat contract next door bans a step from
# spelling out a heartbeat record of its own, because "New-HDTStepHeartbeat owns
# the shape, the interval and the rationing".
#
# THE BAN IS RIGHT AND SO IS THE MARK; WHAT WAS WRONG WAS THAT THE SHAPE HAD
# THREE AUTHORS. This is the one it has now. The INTERVAL still belongs to
# New-HDTStepHeartbeat alone - a step that beats on a clock of its own is still
# a defect - but the record itself, the event name, the mark and the nudge that
# makes the window re-read the log are here, so a step that legitimately knows a
# single moment worth reporting can say so without inventing a second dialect of
# it.

$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:startUtc = [datetime]::new(2026, 9, 2, 4, 15, 0, [System.DateTimeKind]::Utc)

    function New-HDTLivenessTestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test context; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowNull()]
            [object] $Progress
        )

        $fs = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow $script:startUtc

        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $fs -Clock $clock -ThreadId 1

        return [pscustomobject] @{
            Log        = $log
            Service    = [pscustomobject] @{ Clock = $clock; Progress = $Progress }
            Clock      = $clock
            FileSystem = $fs
        }
    }

    # Every step.progress record in the log, in order. The log context writes
    # records of its own - the clock caveat, for one - and none of those are
    # this command's.
    function Get-HDTLivenessRecord {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)] [object] $Context)

        $path = [string] $Context.Log.JsonlPath
        if (-not $Context.FileSystem.TestPath($path)) { return @() }

        $text = [string] $Context.FileSystem.ReadAllText($path)

        return @(
            foreach ($line in ($text -split "`n")) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

                $record = ConvertFrom-Json -InputObject $trimmed
                if ([string] $record.event -ne 'step.progress') { continue }

                $record
            })
    }
}

Describe 'Write-HDTStepLiveness' {

    Context 'the record it writes' {

        It 'is a command the module exposes to its own steps' {
            Get-Command -Name 'Write-HDTStepLiveness' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'writes a step.progress record carrying the mark that says it is not a measurement' {
            $context = New-HDTLivenessTestContext

            Write-HDTStepLiveness -Context $context -Component 'Sysprep' `
                -Message 'generalizing this machine; sysprep reports nothing until it is finished'

            $record = @(Get-HDTLivenessRecord -Context $context)

            $record.Count | Should -Be 1
            [string] $record[0].event | Should -BeExactly 'step.progress'
            [bool] $record[0].data.heartbeat | Should -BeTrue
            [string] $record[0].component | Should -BeExactly 'Sysprep'
            [string] $record[0].message | Should -Match 'sysprep reports nothing'
        }

        It 'keeps the fields the caller had to say, and adds the mark to them' {
            # THE MARK IS THE ONLY THING THIS OWNS. A liveness record still
            # carries whatever the step actually knows - which volume, which
            # executable - and losing that to a shared writer would trade one
            # defect for a worse one.
            $context = New-HDTLivenessTestContext

            Write-HDTStepLiveness -Context $context -Component 'EnableBitLocker' `
                -Message 'C: is still encrypting (EncryptionInProgress), 4 minute(s) so far.' `
                -Data ([ordered] @{ drive = 'C:'; volumeStatus = 'EncryptionInProgress'; elapsedMinute = 4 })

            $record = @(Get-HDTLivenessRecord -Context $context)[0]

            [string] $record.data.drive | Should -BeExactly 'C:'
            [string] $record.data.volumeStatus | Should -BeExactly 'EncryptionInProgress'
            [int] $record.data.elapsedMinute | Should -Be 4
            [bool] $record.data.heartbeat | Should -BeTrue
        }

        It 'carries no percent, so a sign of life cannot drag the step bar backwards' {
            # THE WHOLE REASON THE TWO KINDS ARE TOLD APART.
            # Get-HDTDeploymentProgress reads `percent` off a step.progress
            # record and only off that; a liveness record that carried percent 0
            # would reset a bar that a real measurement had already moved.
            $context = New-HDTLivenessTestContext

            Write-HDTStepLiveness -Context $context -Component 'Sysprep' -Message 'still going' `
                -Data ([ordered] @{ activity = 'sysprep /generalize' })

            $record = @(Get-HDTLivenessRecord -Context $context)[0]

            $record.data.PSObject.Properties['percent'] | Should -BeNullOrEmpty
        }

        It 'writes the mark even when the caller had no data of its own to add' {
            $context = New-HDTLivenessTestContext

            Write-HDTStepLiveness -Context $context -Component 'CommandLine' -Message 'still running'

            $record = @(Get-HDTLivenessRecord -Context $context)[0]

            [bool] $record.data.heartbeat | Should -BeTrue
        }
    }

    Context 'it tells the window to look' {

        It 'asks the display to re-read the log after the record is written' {
            # A record written to a JSONL that nothing reads back draws nothing -
            # the half that was missing from ApplyDrivers, and the reason the
            # nudge lives here rather than being remembered at each call site.
            $display = New-HDTFakeProgressHost
            $context = New-HDTLivenessTestContext -Progress $display

            Write-HDTStepLiveness -Context $context -Component 'Sysprep' -Message 'generalizing'

            @($display.Operations | Where-Object { $_ -eq 'Update' }).Count | Should -Be 1
        }
    }

    Context 'it never fails a deployment' {

        # THE SAME CONTRACT Update-HDTProgressDisplay AND New-HDTStepHeartbeat
        # CARRY, for the same reason: this runs on a machine part-way through
        # building itself, and a line about how it is getting on does not get to
        # be the thing that stops it.
        It 'says nothing and throws nothing when there is no log to write to' {
            $context = [pscustomobject] @{ Service = [pscustomobject] @{ Progress = $null } }

            { Write-HDTStepLiveness -Context $context -Component 'Sysprep' -Message 'generalizing' } |
                Should -Not -Throw
        }

        It 'survives a context that is not there at all' {
            { Write-HDTStepLiveness -Context $null -Component 'Sysprep' -Message 'generalizing' } |
                Should -Not -Throw
        }

        It 'survives a log whose file system went with the RAM disk' {
            $context = New-HDTLivenessTestContext
            $context.Log.FileSystem = $null

            { Write-HDTStepLiveness -Context $context -Component 'Sysprep' -Message 'generalizing' } |
                Should -Not -Throw
        }
    }
}

}
