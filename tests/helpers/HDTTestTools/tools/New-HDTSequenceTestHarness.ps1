function New-HDTSequenceTestHarness {
    <#
        .SYNOPSIS
            Assembles everything Invoke-HDTTaskSequence needs to run against
            fakes, wired together in one order.

        .DESCRIPTION
            Running the execution loop takes eleven objects: a shared journal,
            seven service doubles, a service catalog, a log context, a run state
            and an execution context. Seven test files each building that by hand
            is seven chances for them to drift, and a drifting harness turns "the
            loop changed" into "one file's BeforeEach was different".

            THE JOURNAL IS ATTACHED LAST, on purpose. The harness itself reads
            the sequence back out of the fake filesystem to import it, and
            seeding is not an operation the code under test performed
            (tests/helpers/README.md section 4). So the fakes are built without a
            journal, the setup runs, and only then is the shared journal attached
            - which makes the first journal entry the first thing the LOOP did.

            The clock is frozen unless -TickMillisecond says otherwise, and the
            log path is X:\HDT\Logs, so state.json and status.json land at
            X:\HDT\Logs\state.json and X:\HDT\Logs\status.json - the same
            defaults Invoke-HDTTaskSequence takes.

        .PARAMETER Yaml
            The sequence document. Seeded into the fake filesystem at
            -SequencePath and imported through Import-HDTSequenceDocument, so a
            harness only ever holds a sequence the real importer accepted.

        .PARAMETER SequencePath
            Where the fake filesystem holds the sequence.

        .PARAMETER Phase
            WinPE or FullOS. Defaults to WinPE, which is where a run starts.

        .PARAMETER RunId
            The deployment run id.

        .PARAMETER LogPath
            The log directory.

        .PARAMETER WorkspaceRoot
            The resolved workspace root, also _HDTDeployRoot.

        .PARAMETER Variable
            Extra variables, applied after the sequence's own defaults so a test
            can override one.

        .PARAMETER State
            An existing run state, which is what a resume is. Without one a fresh
            state is built from the imported sequence.

        .PARAMETER Seq
            The last JSONL seq already written, so a second leg continues the
            numbering rather than restarting it.

        .PARAMETER Level
            The log verbosity floor. Defaults to Debug, so a test can assert on a
            record the engine writes at Debug.

        .PARAMETER UtcNow
            The instant the fake clock starts at.

        .PARAMETER TickMillisecond
            How far the fake clock advances per GetUtcNow. 0 freezes it.

        .PARAMETER ProcessResult
            Seeds the fake process service, keyed by command line.

        .PARAMETER ScriptResult
            Seeds the fake script invoker, keyed by script path.

        .PARAMETER RegistryValue
            Seeds the fake registry.

        .PARAMETER Secret
            Seeds the fake LSA service.

        .OUTPUTS
            System.Management.Automation.PSCustomObject carrying Journal,
            FileSystem, Clock, Registry, Lsa, Power, Process, ScriptInvoker, Cim,
            Environment, Catalog, Log, State, Context, Sequence, LogPath,
            SequencePath, StatePath and StatusPath.

        .EXAMPLE
            $harness = New-HDTSequenceTestHarness -Yaml $yaml
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

        .EXAMPLE
            $second = New-HDTSequenceTestHarness -Yaml $yaml -Phase FullOS -State $first.State -Seq $first.State.seq

            The second leg of a rebooted run: same state, new phase, continued
            log numbering.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds in-memory test doubles; it changes no state and touches no real machine.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Yaml,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $SequencePath = 'X:\Deploy\Sequences\TEST\sequence.yaml',

        [Parameter()]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Phase = 'WinPE',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $RunId = 'run-0001',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $LogPath = 'X:\HDT\Logs',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot = 'X:\Deploy',

        [Parameter()]
        [AllowNull()]
        [hashtable] $Variable,

        [Parameter()]
        [AllowNull()]
        [object] $State,

        [Parameter()]
        [long] $Seq = 0,

        [Parameter()]
        [ValidateSet('Error', 'Warning', 'Info', 'Debug')]
        [string] $Level = 'Debug',

        [Parameter()]
        [datetime] $UtcNow = [datetime]'2026-08-13T00:00:00Z',

        [Parameter()]
        [int] $TickMillisecond = 0,

        [Parameter()]
        [AllowNull()]
        [hashtable] $ProcessResult,

        [Parameter()]
        [AllowNull()]
        [hashtable] $ScriptResult,

        [Parameter()]
        [AllowNull()]
        [hashtable] $RegistryValue,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Secret
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $journal = [System.Collections.ArrayList]::new()

    # No -Journal anywhere below: it is attached at the end, so the harness's own
    # reads never appear in it.
    $fileSystem = New-HDTFakeFileSystem -File @{ $SequencePath = $Yaml }
    $clock = New-HDTFakeClock -UtcNow $UtcNow -TickMillisecond $TickMillisecond

    $registryArgument = @{}
    if ($PSBoundParameters.ContainsKey('RegistryValue') -and $null -ne $RegistryValue) {
        $registryArgument['Value'] = $RegistryValue
    }
    $registry = New-HDTFakeRegistryService @registryArgument

    $lsaArgument = @{}
    if ($PSBoundParameters.ContainsKey('Secret') -and $null -ne $Secret) {
        $lsaArgument['Secret'] = $Secret
    }
    $lsa = New-HDTFakeLsaService @lsaArgument

    $processArgument = @{}
    if ($PSBoundParameters.ContainsKey('ProcessResult') -and $null -ne $ProcessResult) {
        $processArgument['Result'] = $ProcessResult
    }
    $process = New-HDTFakeProcessService @processArgument

    $invokerArgument = @{}
    if ($PSBoundParameters.ContainsKey('ScriptResult') -and $null -ne $ScriptResult) {
        $invokerArgument['Result'] = $ScriptResult
    }
    $scriptInvoker = New-HDTFakeScriptInvoker @invokerArgument

    $power = New-HDTFakePowerService
    $cim = New-HDTFakeCimProvider
    $environment = New-HDTFakeEnvironmentProvider -Variable @{ ComSpec = 'cmd.exe' }

    $sequence = Import-HDTSequenceDocument -Path $SequencePath -FileSystem $fileSystem

    # DESIGN 3.1 source 5: the sequence's own defaults, then whatever the test
    # says on top of them.
    $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($sequence.Variable.Keys)) {
        $live[[string] $name] = $sequence.Variable[$name]
    }
    if ($PSBoundParameters.ContainsKey('Variable') -and $null -ne $Variable) {
        foreach ($name in @($Variable.Keys)) {
            $live[[string] $name] = $Variable[$name]
        }
    }

    $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Registry $registry `
        -Lsa $lsa -Process $process -Power $power -ScriptInvoker $scriptInvoker -Cim $cim -Environment $environment

    $log = New-HDTLogContext -RunId $RunId -Phase $Phase -LogPath $LogPath `
        -FileSystem $fileSystem -Clock $clock -Level $Level -Seq $Seq -ThreadId 1

    $runState = $State
    if ($null -eq $runState) {
        $runState = New-HDTRunState -SequenceId $sequence.Id -RunId $RunId -Phase $Phase `
            -Clock $clock -Variable $live -Step $sequence.Step
    }

    $context = New-HDTExecutionContext -RunId $RunId -Phase $Phase -WorkspaceRoot $WorkspaceRoot `
        -Variable $live -Service $catalog -Log $log -State $runState

    # The journal goes on LAST. Everything above is seeding.
    foreach ($fake in @($fileSystem, $clock, $registry, $lsa, $process, $power, $scriptInvoker, $cim, $environment)) {
        $fake.Journal = $journal
    }

    $trimmed = $LogPath.TrimEnd('\', '/')

    return [pscustomobject] ([ordered] @{
            Journal       = $journal
            FileSystem    = $fileSystem
            Clock         = $clock
            Registry      = $registry
            Lsa           = $lsa
            Power         = $power
            Process       = $process
            ScriptInvoker = $scriptInvoker
            Cim           = $cim
            Environment   = $environment
            Catalog       = $catalog
            Log           = $log
            State         = $runState
            Context       = $context
            Sequence      = $sequence
            Variable      = $live
            LogPath       = $trimmed
            SequencePath  = $SequencePath
            StatePath     = ('{0}\state.json' -f $trimmed)
            StatusPath    = ('{0}\status.json' -f $trimmed)
        })
}
