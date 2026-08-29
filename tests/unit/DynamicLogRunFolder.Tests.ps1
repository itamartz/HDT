# One live log file per RUN, not one per machine forever.
#
# HDTSLShareDynamicLogging resolves to a per-MACHINE folder - the shipped rule
# is Logs\%HDTComputerName% - and every mirrored line went through
# AppendAllText with nothing rolling, truncating or separating it. So one file
# accumulated every deployment that machine had ever had.
#
# THE REAL FILE IS THE PROOF. Logs\LT-7FJ45S2\HDT.log on this lab's share held
# 206 CRLF and 253 bare LF, because it carried a run from before the CRLF fix
# beside a run from after it. CMTrace splits entries on CRLF, so the LF-only
# stretch is one unparseable blob - and the reason two runs were in one file at
# all is that nothing ever started a new one.
#
# ROLL, NEVER TRUNCATE. Truncating destroys the previous run's evidence at
# exactly the moment somebody re-runs BECAUSE the last one failed. Size-based
# capping - CCM's .lo_ - is worse still: it splits one deployment across two
# files, and a deployment is the unit anybody reads.
#
# AND A RUN SPANS THE REBOOT, WHICH IS THE HARD HALF. WinPE and the full OS are
# two processes, two log roots and two log contexts, and they are ONE run. The
# folder is keyed on the run id, which survives the restart in state.json, so
# both legs compose the same path from the same id and land in the same file.
# A fix that gave leg 2 a folder of its own would have produced two half-logs
# and looked like it worked.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # The share root exactly as rules.yaml resolves it: a UNC, TEST-NET-1, with
    # the computer name already expanded. Nothing below ever writes into this
    # folder itself - everything goes a level deeper, under the run.
    $script:share = '\\192.0.2.108\HDTShare\Logs\LT-7FJ45S2'

    # ONE LEG OF ONE RUN. Log root and phase differ across the reboot; the run
    # id does not, which is the whole mechanism under test.
    $script:newLeg = {
        param(
            [string] $RunId,
            [string] $Phase = 'WinPE',
            [string] $LogPath = 'X:\HDT\Logs',
            [object] $FileSystem = $null
        )

        if ($null -eq $FileSystem) { $FileSystem = New-HDTFakeFileSystem }

        $context = New-HDTLogContext -RunId $RunId -Phase $Phase -LogPath $LogPath `
            -FileSystem $FileSystem `
            -Clock (New-HDTFakeClock -UtcNow ([datetime]::Parse('2026-08-29T15:18:48Z'))) `
            -ThreadId 4820

        return [pscustomobject] @{
            Context    = $context
            FileSystem = $FileSystem
        }
    }

    # Every path the mirror actually appended to, in order, deduplicated. The
    # SET of writes rather than one path somebody remembered to assert.
    $script:mirrorWrites = {
        param([object] $FileSystem)

        return @($FileSystem.Operations |
                Where-Object { $_.Operation -eq 'AppendAllText' -and ([string] $_.Arguments[0]).StartsWith('\\') } |
                ForEach-Object { [string] $_.Arguments[0] } |
                Select-Object -Unique)
    }
}

Describe 'The live log mirror rolls per run' {

    Context 'two runs on one machine' {

        It 'writes each run into a folder of its own' {
            $first = & $script:newLeg 'run-20260829-151848'
            $first.Context.SetDynamicPath($script:share)

            $second = & $script:newLeg 'run-20260829-232010'
            $second.Context.SetDynamicPath($script:share)

            [string] $first.Context.DynamicMasterLogPath |
                Should -BeExactly ('{0}\run-20260829-151848\HDT.log' -f $script:share)
            [string] $second.Context.DynamicMasterLogPath |
                Should -BeExactly ('{0}\run-20260829-232010\HDT.log' -f $script:share)
        }

        It 'never appends the second run to the first run file' {
            # THE DEFECT, STATED. Both runs used to resolve to the same
            # HDT.log and the second simply carried on where the first
            # stopped - which is how one file came to hold a pre-CRLF-fix run
            # and a post-fix one, and why CMTrace could not read half of it.
            $shared = New-HDTFakeFileSystem

            $first = & $script:newLeg 'run-20260829-151848' 'WinPE' 'X:\HDT\Logs' $shared
            $first.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $first.Context -Message 'the first run partitioned disk 0'

            $second = & $script:newLeg 'run-20260829-232010' 'WinPE' 'X:\HDT\Logs' $shared
            $second.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $second.Context -Message 'the second run partitioned disk 0'

            $firstFile = [string] $shared.ReadAllText(('{0}\run-20260829-151848\HDT.log' -f $script:share))
            $secondFile = [string] $shared.ReadAllText(('{0}\run-20260829-232010\HDT.log' -f $script:share))

            $firstFile | Should -Match 'the first run partitioned disk 0'
            $firstFile | Should -Not -Match 'the second run partitioned disk 0'
            $secondFile | Should -Match 'the second run partitioned disk 0'
            $secondFile | Should -Not -Match 'the first run partitioned disk 0'
        }

        It 'leaves the earlier run file exactly as it found it' {
            # ROLL, NOT TRUNCATE. Somebody re-runs a deployment BECAUSE the last
            # one failed, and the previous run's log is the thing they are about
            # to read. A new run may not shorten it, empty it or remove it.
            $shared = New-HDTFakeFileSystem
            $earlier = ('{0}\run-20260829-151848\HDT.log' -f $script:share)

            $first = & $script:newLeg 'run-20260829-151848' 'WinPE' 'X:\HDT\Logs' $shared
            $first.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $first.Context -Message 'the run that failed'

            $before = [string] $shared.ReadAllText($earlier)

            $second = & $script:newLeg 'run-20260829-232010' 'WinPE' 'X:\HDT\Logs' $shared
            $second.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $second.Context -Message 'the run somebody started to find out why'

            $shared.TestPath($earlier) | Should -BeTrue
            [string] $shared.ReadAllText($earlier) | Should -BeExactly $before
        }

        It 'never rewrites or removes a mirrored file' {
            # Asserted on the OPERATION JOURNAL rather than on content, because
            # a truncation that happened and was appended over again would leave
            # the content looking plausible. Nothing under the share may be
            # written by anything but an append.
            $shared = New-HDTFakeFileSystem

            foreach ($runId in @('run-20260829-151848', 'run-20260829-232010')) {
                $leg = & $script:newLeg $runId 'WinPE' 'X:\HDT\Logs' $shared
                $leg.Context.SetDynamicPath($script:share)
                Write-HDTLog -Context $leg.Context -Message ('a line from {0}' -f $runId)
            }

            $destructive = @($shared.Operations |
                    Where-Object {
                        $_.Operation -in @('WriteAllText', 'RemoveItem') -and
                        ([string] $_.Arguments[0]).StartsWith('\\')
                    })

            $destructive.Count | Should -Be 0
        }
    }

    Context 'one run across the reboot' {

        # THE CASE THIS HAS TO GET RIGHT. Leg 1 is WinPE on X:, leg 2 is the
        # full OS on C:, in a different process, after a restart. They share a
        # run id - leg 1 mints it, state.json carries it over, leg 2 reads it
        # back - and nothing else about them is the same.

        It 'writes both legs of one run into one file' {
            $shared = New-HDTFakeFileSystem
            $runId = 'run-20260829-151848'

            $winPe = & $script:newLeg $runId 'WinPE' 'X:\HDT\Logs' $shared
            $winPe.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $winPe.Context -Message 'WinPE applied the image'

            # -- the reboot. A new process, a new log root, a new context, the
            # same run id out of state.json.
            $fullOs = & $script:newLeg $runId 'FullOS' 'C:\HDT\Logs' $shared
            $fullOs.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $fullOs.Context -Message 'the full OS installed the applications'

            [string] $fullOs.Context.DynamicMasterLogPath |
                Should -BeExactly ([string] $winPe.Context.DynamicMasterLogPath)

            $mirrored = [string] $shared.ReadAllText(('{0}\{1}\HDT.log' -f $script:share, $runId))

            $mirrored | Should -Match 'WinPE applied the image'
            $mirrored | Should -Match 'the full OS installed the applications'
        }

        It 'puts the full OS leg in no folder of its own' {
            # A fix that keyed the folder on anything the reboot changes - the
            # phase, the log root, the clock - would produce two half-logs and
            # pass every other assertion in this file.
            $shared = New-HDTFakeFileSystem
            $runId = 'run-20260829-151848'

            foreach ($leg in @(@('WinPE', 'X:\HDT\Logs'), @('FullOS', 'C:\HDT\Logs'))) {
                $made = & $script:newLeg $runId $leg[0] $leg[1] $shared
                $made.Context.SetDynamicPath($script:share)
                Write-HDTLog -Context $made.Context -Message ('a line from the {0} leg' -f $leg[0])
            }

            $folder = @(& $script:mirrorWrites $shared |
                    ForEach-Object { Split-Path -Path $_ -Parent } |
                    Select-Object -Unique)

            $folder.Count | Should -Be 1
            $folder[0] | Should -BeExactly ('{0}\{1}' -f $script:share, $runId)
        }

        It 'keeps the local log of each leg where that leg put it' {
            # The mirror converging is the point; the machine's own logs must
            # not. WinPE writes to the RAM disk and the full OS to C:, and
            # neither may be redirected by any of this.
            $shared = New-HDTFakeFileSystem
            $runId = 'run-20260829-151848'

            $winPe = & $script:newLeg $runId 'WinPE' 'X:\HDT\Logs' $shared
            $winPe.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $winPe.Context -Message 'WinPE applied the image'

            $fullOs = & $script:newLeg $runId 'FullOS' 'C:\HDT\Logs' $shared
            $fullOs.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $fullOs.Context -Message 'the full OS installed the applications'

            [string] $shared.ReadAllText('X:\HDT\Logs\HDT.log') | Should -Match 'WinPE applied the image'
            [string] $shared.ReadAllText('C:\HDT\Logs\HDT.log') | Should -Match 'the full OS installed the applications'
        }
    }

    Context 'every path the mirror touches' {

        It 'keys every mirrored write on the run' {
            # THE GENERAL FORM, driven off the SET of writes rather than the
            # three paths this file happens to name. A future mirrored surface
            # - a fourth file, a second step log, whatever it is - either
            # carries the run id or fails here.
            $shared = New-HDTFakeFileSystem
            $runId = 'run-20260829-151848'
            $segment = '\{0}\' -f $runId

            $winPe = & $script:newLeg $runId 'WinPE' 'X:\HDT\Logs' $shared
            $winPe.Context.SetDynamicPath($script:share)
            $winPe.Context.SetStep(3, 'Format and Partition Disk (UEFI)', 'DiskPartition', 'X:\HDT\Logs\Steps\003-Format.log')
            Write-HDTLog -Context $winPe.Context -Message 'disk 0 will be cleared'
            $winPe.Context.ClearStep()
            Write-HDTLog -Context $winPe.Context -Message 'the image is on'

            $fullOs = & $script:newLeg $runId 'FullOS' 'C:\HDT\Logs' $shared
            $fullOs.Context.SetDynamicPath($script:share)
            $fullOs.Context.SetStep(11, 'Install Applications', 'InstallApplication', 'C:\HDT\Logs\Steps\011-Apps.log')
            Write-HDTLog -Context $fullOs.Context -Message 'installing 7-Zip'

            $written = @(& $script:mirrorWrites $shared)

            $written.Count | Should -BeGreaterThan 2 -Because 'a mirror that wrote nowhere would satisfy the assertion below vacuously'

            $unkeyed = @($written | Where-Object { -not $_.Contains($segment) })

            ($unkeyed -join '; ') | Should -BeExactly ''
        }

        It 'keys the step log on the run as well' {
            # The step log is mirrored under the same leaf, so it inherits the
            # run folder or it does not - and it is the one that gets forgotten,
            # because SetStep recomputes it separately from SetDynamicPath.
            $made = & $script:newLeg 'run-20260829-151848'
            $made.Context.SetDynamicPath($script:share)
            $made.Context.SetStep(3, 'Format and Partition Disk (UEFI)', 'DiskPartition', 'X:\HDT\Logs\Steps\003-Format.log')

            [string] $made.Context.DynamicStepLogPath |
                Should -BeExactly ('{0}\run-20260829-151848\Steps\003-Format.log' -f $script:share)
        }

        It 'keys it the same way whichever order the two calls arrive in' {
            # SetStep before SetDynamicPath is the real order in WinPE - the
            # share is not known until rules.yaml has resolved - and
            # SetDynamicPath recomputes the step path for exactly that reason.
            # Two code paths to one answer is how they come to disagree.
            $first = & $script:newLeg 'run-20260829-151848'
            $first.Context.SetDynamicPath($script:share)
            $first.Context.SetStep(3, 'Format and Partition Disk (UEFI)', 'DiskPartition', 'X:\HDT\Logs\Steps\003-Format.log')

            $second = & $script:newLeg 'run-20260829-151848'
            $second.Context.SetStep(3, 'Format and Partition Disk (UEFI)', 'DiskPartition', 'X:\HDT\Logs\Steps\003-Format.log')
            $second.Context.SetDynamicPath($script:share)

            [string] $second.Context.DynamicStepLogPath |
                Should -BeExactly ([string] $first.Context.DynamicStepLogPath)
        }

        It 'keys the constructor parameter on the run too' {
            # -DynamicPath and SetDynamicPath are two doors into one setting,
            # and a share seeded through the constructor that skipped the run
            # folder would be a second source of truth that agreed until
            # somebody used the other door.
            $made = New-HDTLogContext -RunId 'run-20260829-151848' -Phase 'WinPE' `
                -LogPath 'X:\HDT\Logs' -FileSystem (New-HDTFakeFileSystem) `
                -Clock (New-HDTFakeClock -UtcNow ([datetime]::Parse('2026-08-29T15:18:48Z'))) `
                -DynamicPath $script:share

            [string] $made.DynamicMasterLogPath |
                Should -BeExactly ('{0}\run-20260829-151848\HDT.log' -f $script:share)
            [string] $made.DynamicJsonlPath |
                Should -BeExactly ('{0}\run-20260829-151848\HDT.jsonl' -f $script:share)
        }

        It 'adds the run folder once when it is already there' {
            # A caller that reads back the composed path and hands it in again -
            # which the payload does, because it creates the directory it was
            # given - must not end up two runs deep.
            $made = & $script:newLeg 'run-20260829-151848'
            $made.Context.SetDynamicPath($script:share)
            $made.Context.SetDynamicPath([string] $made.Context.DynamicPath)

            [string] $made.Context.DynamicPath |
                Should -BeExactly ('{0}\run-20260829-151848' -f $script:share)
        }

        It 'still turns the mirror off when it is given nothing' {
            $made = & $script:newLeg 'run-20260829-151848'
            $made.Context.SetDynamicPath($script:share)
            $made.Context.SetDynamicPath('')

            [string] $made.Context.DynamicPath | Should -BeNullOrEmpty
            [string] $made.Context.DynamicMasterLogPath | Should -BeNullOrEmpty
            [string] $made.Context.DynamicStepLogPath | Should -BeNullOrEmpty
        }
    }

    Context 'a mirror that cannot be created' {

        It 'does not fail the deployment when the run folder cannot be written' {
            # A SHARE THAT HAS GONE IS THE CASE THIS FEATURE IS MOST USEFUL IN,
            # and a deployment that ended because its LOGGING failed would be
            # the logging causing the outage it was installed to explain. One
            # more folder in the path is one more thing that can fail.
            $shared = New-HDTFakeFileSystem
            $runId = 'run-20260829-151848'
            $folder = '{0}\{1}' -f $script:share, $runId

            $shared.SeedWriteFailure(('{0}\HDT.log' -f $folder), 'The network path was not found.')
            $shared.SeedWriteFailure(('{0}\HDT.jsonl' -f $folder), 'The network path was not found.')

            $made = & $script:newLeg $runId 'WinPE' 'X:\HDT\Logs' $shared
            $made.Context.SetDynamicPath($script:share)

            { Write-HDTLog -Context $made.Context -Message 'applying image' } | Should -Not -Throw

            [string] $shared.ReadAllText('X:\HDT\Logs\HDT.log') | Should -Match 'applying image'
        }
    }
}

Describe 'Both deployment legs prepare the run folder they mirror into' {

    # AGAINST THE SET OF LEGS, not against the one that was edited.
    #
    # The payload prepares the mirror directory before arming it, and that
    # CreateDirectory is also the reachability probe: a share that cannot be
    # written to throws here, the catch downgrades it to a warning, and the run
    # carries on logging locally. It has to prepare the folder the mirror
    # actually writes into - the composed one on the context - and not the raw
    # rule value, or the probe tests a folder nothing uses.
    #
    # b08bb91 IS WHY THIS IS A TEST. That commit armed the mirror through a
    # PRIVATE helper a payload session does not have, the catch ate the
    # CommandNotFoundException, and live logging was dead for a day looking
    # entirely normal.

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        $script:legPayload = @(
            'Start-HDTDeployment.ps1'
            'Start-HDTResume.ps1'
        )
    }

    It 'creates the composed run folder rather than the raw rule value' {
        $missing = @()

        foreach ($leaf in $script:legPayload) {
            $path = [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'Payload', $leaf)

            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $missing += ('{0} (not found)' -f $leaf)
                continue
            }

            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)
            [void] $ast

            # The comment-free stream, so the prose describing a call cannot
            # pass for the call.
            $codeOnly = (@($token |
                        Where-Object { $_.Kind -ne 'Comment' } |
                        ForEach-Object { [string] $_.Text }) -join ' ')

            # Whitespace-insensitive: the shipped line is written across one
            # line here and may be wrapped later.
            $squashed = $codeOnly -replace '\s+', ''

            if (-not $squashed.Contains('CreateDirectory($log.DynamicPath)')) {
                $missing += ('{0} (does not create the composed run folder)' -f $leaf)
            }

            if ($squashed.Contains('CreateDirectory($dynamicLogPath)')) {
                $missing += ('{0} (still creates the raw per-machine folder)' -f $leaf)
            }
        }

        ($missing -join '; ') | Should -BeExactly ''
    }
}
