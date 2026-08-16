function Import-HDTSequenceDocument {
    <#
        .SYNOPSIS
            Reads, parses, validates and flattens a sequence.yaml into execution
            order.

        .DESCRIPTION
            The public front door to sequence.yaml. It reads the
            file through an injected IFileSystem - never Get-Content - so the
            whole authoring path is provable under Pester with no share, no media
            and no disk.

            Four steps, and a failure at any of them is a terminating
            HDTConfigurationError naming the file:

              1. read through IFileSystem;
              2. parse with ConvertFrom-HDTYaml, which turns a parser exception
                 into an error naming the file and the LINE;
              3. validate with Assert-HDTSequenceDocument, which names the file
                 and the STEP or GROUP;
              4. flatten into execution order.

            FLATTENING IS THE DESIGN DECISION HERE. A group is not an execution
            unit; it is a naming and condition device. Flattening nested groups
            into one linear, 1-based list means DESIGN 4.3's "skips completed
            steps by index" works unchanged with nesting, and a group whose
            condition is false produces one step.skip record per contained step
            naming the group - which is what a technician reading a log needs,
            rather than a single line that hides six steps.

            Each flattened step carries:

              Index            1-based position in execution order
              Name, Type       from the document
              GroupPath        [string[]], outermost first, @() at the root
              Condition        the step's own condition, or $null
              GroupCondition   [object[]] of Group/Condition, outermost first,
                               only for ancestors that declare one
              ContinueOnError  [bool], default $false
              Disabled         [bool], default $false - the step is skipped
                               without being removed. A step inside a disabled
                               group is disabled whatever it says about itself
              TimeoutMinutes   [int], 0 = unbounded, default 0
              RunIn            WinPE | FullOS | Any; a step with none inherits its
                               nearest ancestor group's runIn, default Any
              Retry            Count / DelaySecond / Backoff, default 0/0/fixed
              Resumable        [bool], default $false - DESIGN 4.3's "re-runs the
                               interrupted step only if it declares resumable"
              Log              a per-step log file name, or $null
              Property         ordered, case-insensitive: every key that is NOT a
                               common property, i.e. the step type's own arguments

            A NODE IS A GROUP WHEN IT DECLARES steps. DESIGN 4.1's ApplyDrivers
            step carries `group: "%HDTDriverGroup%"` as a type-specific property,
            so `group` cannot be the discriminator - it stays in Property.

            STEP TYPES ARE NOT RESOLVED HERE. A sequence referencing a type this
            engine does not implement still imports, because a workspace's
            Modules\ may carry it and the authoring machine may not.

        .PARAMETER Path
            The sequence.yaml to read. Interpreted by the filesystem service, so
            it may be a share path, a media path or a fake's in-memory path.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Path, SchemaVersion, Id, Name, Description
              Variable  ordered, case-insensitive: the sequence defaults
              Step      [object[]] flattened into execution order
              Group     [object[]] one per group node: Path, Condition, RunIn

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'X:\Deploy\Sequences\STD-CLIENT\sequence.yaml' -FileSystem (New-HDTFileSystem)
            $sequence.Step | Format-Table Index, Name, Type, RunIn

        .EXAMPLE
            $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = $text }
            Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fs

            The same call in a test, with no file on disk anywhere.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $FileSystem.TestPath($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the sequence file does not exist. Every sequence is a sequence.yaml under the workspace Sequences directory (DESIGN 2.1).' `
                    -Category ObjectNotFound))
    }

    $text = $FileSystem.ReadAllText($Path)

    $document = ConvertFrom-HDTYaml -Yaml $text -Path $Path
    Assert-HDTSequenceDocument -Document $document -Path $Path

    # The common properties. Everything else on a step node is that step type's
    # own argument and goes into Property untouched.
    $commonKey = @('name', 'type', 'condition', 'continueOnError', 'disabled', 'timeoutMinutes', 'runIn', 'retry', 'resumable', 'log')

    $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($document.Contains('variables')) {
        foreach ($key in @($document['variables'].Keys)) {
            $variable[[string] $key] = $document['variables'][$key]
        }
    }

    $description = $null
    if ($document.Contains('description')) {
        $description = [string] $document['description']
    }

    $step = New-Object -TypeName System.Collections.ArrayList
    $group = New-Object -TypeName System.Collections.ArrayList

    # A depth-first preorder walk with an explicit stack. Children are pushed in
    # reverse so they pop in document order, which is what makes Index the
    # execution order rather than an arbitrary traversal order.
    $stack = New-Object -TypeName System.Collections.Stack
    $rootNode = @($document['steps'])
    for ($position = $rootNode.Count - 1; $position -ge 0; $position--) {
        $stack.Push([pscustomobject] @{
                Node           = $rootNode[$position]
                GroupPath      = [string[]] @()
                GroupCondition = [object[]] @()
                RunIn          = 'Any'
                Disabled       = $false
            })
    }

    $index = 0

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $node = $frame.Node

        if ($node.Contains('steps')) {
            $groupName = [string] $node['group']
            $groupPath = [string[]] (@($frame.GroupPath) + $groupName)

            $groupCondition = $null
            if ($node.Contains('condition')) {
                $groupCondition = [string] $node['condition']
            }

            $inheritedCondition = [object[]] @($frame.GroupCondition)
            if (-not [string]::IsNullOrWhiteSpace($groupCondition)) {
                $inheritedCondition = [object[]] (@($frame.GroupCondition) + [pscustomobject] @{
                        Group     = $groupName
                        Condition = $groupCondition
                    })
            }

            $groupRunIn = [string] $frame.RunIn
            if ($node.Contains('runIn')) {
                $groupRunIn = [string] $node['runIn']
            }

            # A DISABLED GROUP DISABLES EVERYTHING UNDER IT, and a group inside a
            # disabled group cannot switch itself back on. Turning off a group of
            # six is one edit, and re-enabling one step inside it by hand would be
            # a document that says two contradictory things.
            $groupDisabled = [bool] $frame.Disabled
            if (-not $groupDisabled -and $node.Contains('disabled')) {
                $groupDisabled = [bool] $node['disabled']
            }

            [void] $group.Add([pscustomobject] @{
                    Path      = $groupPath
                    Condition = $groupCondition
                    RunIn     = $groupRunIn
                    Disabled  = $groupDisabled
                })

            $childNode = @($node['steps'])
            for ($position = $childNode.Count - 1; $position -ge 0; $position--) {
                $stack.Push([pscustomobject] @{
                        Node           = $childNode[$position]
                        GroupPath      = $groupPath
                        GroupCondition = $inheritedCondition
                        RunIn          = $groupRunIn
                        Disabled       = $groupDisabled
                    })
            }

            continue
        }

        $index++

        $condition = $null
        if ($node.Contains('condition')) {
            $condition = [string] $node['condition']
        }

        $continueOnError = $false
        if ($node.Contains('continueOnError')) {
            $continueOnError = [bool] $node['continueOnError']
        }

        # ABSENT MEANS ENABLED, and a step inside a disabled group is disabled
        # whatever it says about itself. Every sequence written before this key
        # existed has no 'disabled' anywhere in it, and all of their steps must
        # still run.
        $disabled = [bool] $frame.Disabled
        if (-not $disabled -and $node.Contains('disabled')) {
            $disabled = [bool] $node['disabled']
        }

        $resumable = $false
        if ($node.Contains('resumable')) {
            $resumable = [bool] $node['resumable']
        }

        $timeoutMinutes = 0
        if ($node.Contains('timeoutMinutes')) {
            $timeoutMinutes = [int] $node['timeoutMinutes']
        }

        # A step with no runIn inherits its nearest ancestor group's, which the
        # frame already carries; declaring one overrides that inheritance.
        $runIn = [string] $frame.RunIn
        if ($node.Contains('runIn')) {
            $runIn = [string] $node['runIn']
        }

        $log = $null
        if ($node.Contains('log')) {
            $log = [string] $node['log']
        }

        # A pscustomobject rather than a hashtable: on a hashtable, .Count is
        # ICollection.Count - the number of keys - and would silently shadow the
        # retry count the loop reads.
        $retryCount = 0
        $retryDelay = 0
        $retryBackoff = 'fixed'
        if ($node.Contains('retry')) {
            $retry = $node['retry']
            if ($retry.Contains('count')) { $retryCount = [int] $retry['count'] }
            if ($retry.Contains('delaySeconds')) { $retryDelay = [int] $retry['delaySeconds'] }
            if ($retry.Contains('backoff')) { $retryBackoff = [string] $retry['backoff'] }
        }

        $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($node.Keys)) {
            if ($commonKey -notcontains [string] $key) {
                $property[[string] $key] = $node[$key]
            }
        }

        [void] $step.Add([pscustomobject] @{
                Index           = $index
                Name            = [string] $node['name']
                Type            = [string] $node['type']
                GroupPath       = [string[]] @($frame.GroupPath)
                Condition       = $condition
                GroupCondition  = [object[]] @($frame.GroupCondition)
                ContinueOnError = $continueOnError
                Disabled        = $disabled
                TimeoutMinutes  = $timeoutMinutes
                RunIn           = $runIn
                Retry           = [pscustomobject] @{
                    Count       = $retryCount
                    DelaySecond = $retryDelay
                    Backoff     = $retryBackoff
                }
                Resumable       = $resumable
                Log             = $log
                Property        = $property
            })
    }

    return [pscustomobject] @{
        Path          = $Path
        SchemaVersion = [int] $document['schemaVersion']
        Id            = [string] $document['id']
        Name          = [string] $document['name']
        Description   = $description
        Variable      = $variable
        Step          = [object[]] @($step)
        Group         = [object[]] @($group)
    }
}
