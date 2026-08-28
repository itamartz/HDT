# Logs on the share WHILE the deployment runs, not after it.
#
# HDTSLShare COPIES AT THE END, which is the wrong half of the problem. A run
# that finishes leaves its logs on the share; a run that dies leaves nothing,
# and a run that dies is the only kind anybody needs the log for. On this lab's
# Latitude the wizard threw before a single step ran, the machine powered off
# five seconds later, and the entire record of why was on an X: drive that no
# longer existed.
#
# SO THE LINES ARE WRITTEN TWICE, AS THEY HAPPEN. MDT calls the second
# destination SLShareDynamicLogging and points CMTrace at it to watch a
# deployment live. This is that: every line Write-HDTLog appends locally is
# appended again under a directory on the share, so the log exists before the
# thing that would have copied it does.
#
# AND THE MIRROR MUST NEVER BE ABLE TO END A DEPLOYMENT. The share can go away
# mid-run - a lease moves, a switch reboots, somebody unplugs it - and a
# deployment that died because its LOGGING failed would be the logging causing
# the outage it was installed to explain. Every mirrored write is guarded, and
# a failure is silent to the caller.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:newContext = {
        param([string] $Dynamic = '')

        $fs = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow ([datetime]::Parse('2026-08-28T09:00:00Z'))

        $argument = @{
            RunId      = 'run-20260828-090000'
            Phase      = 'WinPE'
            LogPath    = 'X:\HDT\Logs'
            FileSystem = $fs
            Clock      = $clock
            ThreadId   = 4820
        }

        if (-not [string]::IsNullOrEmpty($Dynamic)) { $argument['DynamicPath'] = $Dynamic }

        return [pscustomobject] @{
            Context    = (New-HDTLogContext @argument)
            FileSystem = $fs
        }
    }

    $script:share = '\\192.0.2.108\HDTShare\Logs\LT-7FJ45S2'
}

Describe 'Dynamic logging to the share' {

    Context 'the context it produces' {

        It 'carries a mirrored jsonl and master log when a dynamic path is given' {
            $made = & $script:newContext $script:share

            $made.Context.DynamicJsonlPath | Should -BeExactly ('{0}\HDT.jsonl' -f $script:share)
            $made.Context.DynamicMasterLogPath | Should -BeExactly ('{0}\HDT.log' -f $script:share)
        }

        It 'carries nothing when no dynamic path is given' {
            # EVERY DEPLOYMENT BEFORE THIS EXISTED MUST BE UNCHANGED. An empty
            # dynamic path is the default and writes exactly one copy.
            $made = & $script:newContext

            $made.Context.DynamicJsonlPath | Should -BeNullOrEmpty
            $made.Context.DynamicMasterLogPath | Should -BeNullOrEmpty
        }

        It 'tolerates a trailing separator the way the local path does' {
            $made = & $script:newContext ($script:share + '\')

            $made.Context.DynamicJsonlPath | Should -BeExactly ('{0}\HDT.jsonl' -f $script:share)
        }
    }

    Context 'set after the context was built' {

        # THE ANSWER ARRIVES AFTER THE CONTEXT DOES. The payload builds its log
        # context in the first seconds of a run - before the share is reachable
        # and long before rules.yaml has resolved HDTSLShareDynamicLogging - so
        # the destination has to be settable on the context that already exists.
        # Rebuilding it would throw away the sequence counter and every record
        # written so far.

        It 'starts mirroring from the moment it is set' {
            $made = & $script:newContext

            Write-HDTLog -Context $made.Context -Message 'before the share was known'
            $made.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $made.Context -Message 'after the share was known'

            $mirrored = [string] $made.FileSystem.ReadAllText(('{0}\HDT.log' -f $script:share))

            $mirrored | Should -Match 'after the share was known'
            $mirrored | Should -Not -Match 'before the share was known' -Because 'a mirror cannot carry what was written before it existed'
        }

        It 'keeps the local log whole across the change' {
            # THE MACHINE'S OWN LOG IS THE ONE THAT MATTERS, and it must carry
            # both halves whatever the share does.
            $made = & $script:newContext

            Write-HDTLog -Context $made.Context -Message 'before the share was known'
            $made.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $made.Context -Message 'after the share was known'

            $local = [string] $made.FileSystem.ReadAllText('X:\HDT\Logs\HDT.log')

            $local | Should -Match 'before the share was known'
            $local | Should -Match 'after the share was known'
        }

        It 'turns the mirror off again when given nothing' {
            $made = & $script:newContext $script:share
            $made.Context.SetDynamicPath('')

            $made.Context.DynamicPath | Should -BeNullOrEmpty
            $made.Context.DynamicJsonlPath | Should -BeNullOrEmpty
        }

        It 'recomputes the step log against the new root' {
            $made = & $script:newContext
            $made.Context.SetStep(3, 'Format and Partition Disk (UEFI)', 'DiskPartition', 'X:\HDT\Logs\Steps\003-Format.log')
            $made.Context.SetDynamicPath($script:share)

            [string] $made.Context.DynamicStepLogPath |
                Should -BeExactly ('{0}\Steps\003-Format.log' -f $script:share)
        }
    }

    Context 'what it writes' {

        It 'appends the jsonl record to the share as well as locally' {
            $made = & $script:newContext $script:share

            Write-HDTLog -Context $made.Context -Message 'partitioning disk 0' -Event 'step.start'

            [string] $made.FileSystem.ReadAllText('X:\HDT\Logs\HDT.jsonl') | Should -Match 'partitioning disk 0'
            [string] $made.FileSystem.ReadAllText(('{0}\HDT.jsonl' -f $script:share)) | Should -Match 'partitioning disk 0'
        }

        It 'appends the CMTrace line to the share as well as locally' {
            $made = & $script:newContext $script:share

            Write-HDTLog -Context $made.Context -Message 'partitioning disk 0'

            [string] $made.FileSystem.ReadAllText(('{0}\HDT.log' -f $script:share)) | Should -Match 'partitioning disk 0'
        }

        It 'writes the same line to both, not a different one' {
            # A MIRROR THAT DISAGREES IS WORSE THAN NO MIRROR. Somebody reading
            # the share is reading it to avoid walking to the machine.
            $made = & $script:newContext $script:share

            Write-HDTLog -Context $made.Context -Message 'applying image'

            [string] $made.FileSystem.ReadAllText('X:\HDT\Logs\HDT.log') |
                Should -BeExactly ([string] $made.FileSystem.ReadAllText(('{0}\HDT.log' -f $script:share)))
        }

        It 'mirrors the step log too' {
            $made = & $script:newContext $script:share
            $made.Context.SetStep(3, 'Format and Partition Disk (UEFI)', 'DiskPartition', 'X:\HDT\Logs\Steps\003-Format.log')

            Write-HDTLog -Context $made.Context -Message 'disk 0 will be cleared'

            [string] $made.FileSystem.ReadAllText(('{0}\Steps\003-Format.log' -f $script:share)) |
                Should -Match 'disk 0 will be cleared'
        }

        It 'writes only locally when no dynamic path is given' {
            # THROUGH .Operations, WHICH IS THE PROPERTY THE FAKE ACTUALLY HAS.
            # This assertion first read a .Written that does not exist: it
            # answered $null, an empty array, a count of zero, and passed while
            # proving nothing - the same shape as the redaction tests that were
            # thrown away earlier in this repository's life.
            $made = & $script:newContext

            Write-HDTLog -Context $made.Context -Message 'partitioning disk 0'

            $unc = @($made.FileSystem.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and ([string] $_.Arguments[0]) -like '\\*' })

            $unc.Count | Should -Be 0
        }

        It 'does write to a UNC when a dynamic path IS given' {
            # THE POSITIVE CONTROL FOR THE TEST ABOVE. Without it, a mirror that
            # silently never wrote anywhere would satisfy both of them.
            $made = & $script:newContext $script:share

            Write-HDTLog -Context $made.Context -Message 'partitioning disk 0'

            $unc = @($made.FileSystem.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and ([string] $_.Arguments[0]) -like '\\*' })

            $unc.Count | Should -BeGreaterThan 0
        }
    }

    Context 'what it must never do' {

        It 'does not fail the caller when the share has gone away' {
            # THE DEPLOYMENT OUTLIVES ITS LOGGING. A lease moves, a switch
            # reboots, somebody unplugs it - and none of those is a reason to
            # end a deployment that is otherwise working.
            $made = & $script:newContext $script:share
            $made.FileSystem.SeedWriteFailure((('{0}\HDT.log' -f $script:share)), 'The network path was not found.')
            $made.FileSystem.SeedWriteFailure((('{0}\HDT.jsonl' -f $script:share)), 'The network path was not found.')

            { Write-HDTLog -Context $made.Context -Message 'applying image' } | Should -Not -Throw
        }

        It 'still writes the local log when the share has gone away' {
            # AND THIS IS THE HALF THAT MATTERS. The mirror failing must not
            # cost the copy that would otherwise have been taken at the end.
            $made = & $script:newContext $script:share
            $made.FileSystem.SeedWriteFailure((('{0}\HDT.log' -f $script:share)), 'The network path was not found.')
            $made.FileSystem.SeedWriteFailure((('{0}\HDT.jsonl' -f $script:share)), 'The network path was not found.')

            Write-HDTLog -Context $made.Context -Message 'applying image'

            [string] $made.FileSystem.ReadAllText('X:\HDT\Logs\HDT.log') | Should -Match 'applying image'
        }
    }

    Context 'the variable an administrator sets' {

        It 'is in the variable map under its own MDT name' {
            $entry = @(Get-HDTVariableMap | Where-Object { $_.HDTName -eq 'HDTSLShareDynamicLogging' })

            $entry.Count | Should -Be 1
            $entry[0].MdtName | Should -BeExactly 'SLShareDynamicLogging'
        }

        It 'is not the same variable as the copy-at-the-end one' {
            # SLShare COPIES WHEN THE RUN ENDS; SLShareDynamicLogging WRITES
            # WHILE IT RUNS. A share that set one and got the other would be
            # told the wrong thing about when its logs appear.
            $dynamic = @(Get-HDTVariableMap | Where-Object { $_.HDTName -eq 'HDTSLShareDynamicLogging' })[0]
            $atEnd = @(Get-HDTVariableMap | Where-Object { $_.HDTName -eq 'HDTSLShare' })[0]

            $dynamic.MdtName | Should -Not -BeExactly $atEnd.MdtName
        }
    }
}
