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

# THE PAYLOAD'S OWN BLOCK, RUN. Everything above tests New-HDTLogContext and
# Write-HDTLog, which were never the broken half: the mirror worked and nothing
# ever switched it on.
#
# b08bb91 SHIPPED THE SWITCH AND IT THREW ON EVERY RUN. The block that turns
# mirroring on called Expand-HDTVariableToken - a PRIVATE module function - and
# a payload script gets the exported surface only, so the name did not exist
# there. The call threw CommandNotFoundException, the block's own catch
# downgraded it to a Warning because a share that cannot be written to must
# never end a deployment, and live logging was dead for a day with one line on
# the share to say so.
#
# A PARSE TEST WOULD NOT HAVE CAUGHT IT and neither would any test of the log
# context. So this EXECUTES the shipped statements - located in the AST, not
# copied here, because a copy is a second source of truth that agrees with the
# payload exactly until somebody edits one of them - against hand-written fakes,
# and asserts the one observable thing the defect removed: CreateDirectory was
# called on the share and the mirror is on.
#
# AND THE VALUE ARRIVES ALREADY EXPANDED, which is why the call bought nothing
# even in the world where it resolved. Add-HDTResolvedVariable expands as it
# stores, so $resolved.Variable holds the finished string; the second case below
# is Resolve-HDTVariable proving that rather than this file assuming it.

Describe 'The dynamic logging block in the WinPE payload' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'

        $parseError = $null
        $token = $null
        $script:payloadAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:payloadPath, [ref] $token, [ref] $parseError)

        $script:ifContaining = {
            param([string] $Needle)

            # The SMALLEST if-statement whose extent mentions it, so a nested
            # block is preferred over every ancestor that also contains it.
            $wanted = $Needle

            return @($script:payloadAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.IfStatementAst] -and
                        $node.Extent.Text.Contains($wanted)
                    }, $true) | Sort-Object { $_.Extent.Text.Length })[0]
        }

        # Two statements: the one that READS HDTSLShareDynamicLogging out of the
        # resolution, and the guarded one that PREPARES the directory and turns
        # the mirror on.
        $script:readStatement = & $script:ifContaining "Contains('HDTSLShareDynamicLogging')"
        $script:switchStatement = & $script:ifContaining 'SetDynamicPath'

        $script:blockText = ''
        if (($null -ne $script:readStatement) -and ($null -ne $script:switchStatement)) {
            $script:blockText = "`$dynamicLogPath = ''`n{0}`n{1}" -f
                $script:readStatement.Extent.Text, $script:switchStatement.Extent.Text
        }

        # The share an administrator would write into rules.yaml: a UNC root plus
        # the computer name as a token, which is the shape that made a second
        # expansion look necessary. Single-quoted so YAML takes the backslashes
        # literally, and TEST-NET-1 rather than this lab's address, which is one
        # machine's wiring and does not belong in a test.
        $script:rulesPath = 'C:\HDTLab\does-not-exist\ws\rules.yaml'
        $script:rules = Import-HDTRuleDocument -Path $script:rulesPath -FileSystem (New-HDTFakeFileSystem -File @{
                $script:rulesPath = @'
schemaVersion: 1
rules:
  - name: Fallback
    set:
      HDTComputerName: 'LT-%HDTSerialNumber%'
      HDTSLShareDynamicLogging: '\\192.0.2.108\HDTShare\Logs\%HDTComputerName%'
'@
            })

        $script:expectedPath = '\\192.0.2.108\HDTShare\Logs\LT-7FJ45S2'

        $script:newLogContext = {
            param([object] $FileSystem)

            return New-HDTLogContext -RunId 'run-20260828-090000' -Phase 'WinPE' `
                -LogPath 'X:\HDT\Logs' -FileSystem $FileSystem `
                -Clock (New-HDTFakeClock -UtcNow ([datetime]::Parse('2026-08-28T09:00:00Z'))) `
                -ThreadId 4820
        }

        $script:runBlock = {
            # Everything the extracted statements close over, and nothing else.
            $resolved = Resolve-HDTVariable -RuleDocument $script:rules `
                -Fact @{ HDTSerialNumber = '7FJ45S2' }

            $fileSystem = New-HDTFakeFileSystem
            $log = & $script:newLogContext $fileSystem

            $spoken = New-Object -TypeName System.Collections.ArrayList
            $say = {
                param([string] $Message, [string] $Severity = 'Info')
                [void] $spoken.Add([pscustomobject] @{ Message = $Message; Severity = $Severity })
            }

            # READ BY NAME INSIDE THE CREATED BLOCK, which PSScriptAnalyzer
            # cannot see through - it reports every one of them unused without
            # this line, and a suppression would hide a genuinely dead variable
            # the next time one appears here.
            [void] @($resolved, $fileSystem, $log, $say)

            # THE SHIPPED STATEMENTS, not a paraphrase of them.
            #
            # DOT-SOURCED, NOT CALLED. The payload runs these two statements in
            # ONE scope: the first sets $dynamicLogPath and the second reads it,
            # and the value is still there afterwards. '&' would run them in a
            # CHILD scope, where the assignment dies with the block - so $run.Path
            # below read a variable that had never been set, which under
            # StrictMode is a RuntimeException and without it is a silent $null.
            . ([scriptblock]::Create($script:blockText))

            return [pscustomobject] @{
                Resolved   = $resolved
                FileSystem = $fileSystem
                Log        = $log
                Spoken     = @($spoken)
                Path       = $dynamicLogPath
            }
        }

        $script:directoryArgument = {
            param([object] $FileSystem)

            return @($FileSystem.Operations |
                    Where-Object { $_.Operation -eq 'CreateDirectory' } |
                    ForEach-Object { [string] $_.Arguments[0] })
        }
    }

    It 'finds the two statements it executes' {
        # Non-vacuity: a rename or a restructure that lost either statement
        # would otherwise leave every case below running an empty string.
        $script:readStatement | Should -Not -BeNullOrEmpty
        $script:switchStatement | Should -Not -BeNullOrEmpty
        $script:blockText | Should -Match 'SetDynamicPath'
    }

    It 'is handed a value the resolution already expanded' {
        # Add-HDTResolvedVariable expands as it stores. Nothing in the payload
        # has to expand it a second time, which is what the defect was.
        $resolved = Resolve-HDTVariable -RuleDocument $script:rules `
            -Fact @{ HDTSerialNumber = '7FJ45S2' }

        [string] $resolved.Variable['HDTSLShareDynamicLogging'] |
            Should -BeExactly $script:expectedPath
        [string] $resolved.Variable['HDTSLShareDynamicLogging'] | Should -Not -Match '%'
    }

    It 'creates the log directory on the share' {
        # THE ASSERTION THE DEFECT FAILED. CreateDirectory was never reached,
        # so the folder never appeared and CMTrace had nothing to open.
        #
        # Asserted on the ARGUMENT, never on the operation name: building the
        # log context creates X:\HDT\Logs, so a CreateDirectory is already in
        # the journal before the block runs and the name alone proves nothing.
        $run = & $script:runBlock

        & $script:directoryArgument $run.FileSystem | Should -Contain $script:expectedPath

        # AND THE VARIABLE THE STATEMENTS LEFT BEHIND, because a property no
        # test reads is how the scope defect above stayed invisible: run them in
        # a child scope and this is $null while every other assertion here still
        # passes.
        [string] $run.Path | Should -BeExactly $script:expectedPath
    }

    It 'turns the mirror on for the log context' {
        $run = & $script:runBlock

        [string] $run.Log.DynamicMasterLogPath | Should -BeExactly ('{0}\HDT.log' -f $script:expectedPath)
        [string] $run.Log.DynamicJsonlPath | Should -BeExactly ('{0}\HDT.jsonl' -f $script:expectedPath)
    }

    It 'says so without a warning' {
        # The catch is the whole reason this went unnoticed for a day: it turns
        # anything thrown in here into a Warning and carries on deploying. A
        # Warning out of this block on a writable share means the block threw,
        # whatever it threw.
        $run = & $script:runBlock

        @($run.Spoken | Where-Object { $_.Severity -eq 'Warning' }) |
            Should -BeNullOrEmpty -Because (
            'the block reported: {0}' -f (@($run.Spoken | ForEach-Object { $_.Message }) -join ' | '))

        @($run.Spoken | Where-Object { $_.Message -like '*logging live to*' }) | Should -Not -BeNullOrEmpty
    }

    It 'still refuses to be fatal when the share cannot be reached' {
        # NEVER FATAL stays never fatal. A deployment that died because its
        # LOGGING failed would be the logging causing the outage it was
        # installed to explain.
        #
        # The refusing filesystem is written here rather than seeded on
        # New-HDTFakeFileSystem: that fake's CreateDirectory cannot be made to
        # fail, and widening it is a change to a surface every other suite
        # shares. This one is used for a single call.
        $resolved = Resolve-HDTVariable -RuleDocument $script:rules `
            -Fact @{ HDTSerialNumber = '7FJ45S2' }

        $log = & $script:newLogContext (New-HDTFakeFileSystem)

        $fileSystem = [pscustomobject] @{}
        $fileSystem | Add-Member -MemberType ScriptMethod -Name 'CreateDirectory' -Value {
            param([string] $Path)
            throw [System.IO.IOException]::new(("The network path '{0}' was not found." -f $Path))
        }

        $spoken = New-Object -TypeName System.Collections.ArrayList
        $say = {
            param([string] $Message, [string] $Severity = 'Info')
            [void] $spoken.Add([pscustomobject] @{ Message = $Message; Severity = $Severity })
        }

        # As above: read by name inside the created block.
        [void] @($resolved, $fileSystem, $log, $say)

        { & ([scriptblock]::Create($script:blockText)) } | Should -Not -Throw

        @($spoken | Where-Object { $_.Severity -eq 'Warning' }) | Should -Not -BeNullOrEmpty
        [string] $log.DynamicMasterLogPath | Should -BeNullOrEmpty
    }
}
