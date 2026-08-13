function Assert-HDTSequenceDocument {
    <#
        .SYNOPSIS
            Validates a parsed sequence.yaml against the DESIGN 4.1 authoring
            rules.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/sequence.schema.json is a gate for the console, editors and
            CI while this is the gate for a deployment. It mirrors
            Assert-HDTRuleDocument's shape exactly - throw on the first
            violation, return nothing otherwise, every failure a terminating
            HDTConfigurationError naming the file and the offending node.

            The authoring rules, in the order they are checked:

              document  not empty; a mapping; only schemaVersion, id, name,
                        description, variables and steps; schemaVersion present,
                        an integer and not newer than this engine; id matching
                        ^[A-Za-z0-9][A-Za-z0-9_-]*$; a non-empty name; steps
                        present, a list and not empty
              variables every name matching ^HDT[A-Za-z0-9_]*$ and no _HDT* name,
                        which is engine-owned and cannot be assigned (DESIGN 3.2)
              group     a mapping declaring steps; a non-empty group name; no key
                        outside group/condition/runIn/steps; a non-empty steps
                        list; a parseable condition; a runIn in the set
              step      a mapping declaring type; a non-empty name; a type
                        matching ^[A-Za-z][A-Za-z0-9]*$; boolean continueOnError
                        and resumable; a positive timeoutMinutes; a runIn in the
                        set; a retry mapping with count 0-10, delaySeconds >= 0
                        and a known backoff; a parseable condition

            A NODE IS A GROUP WHEN IT DECLARES steps, not when it declares group.
            DESIGN 4.1's own ApplyDrivers step carries `group: "%HDTDriverGroup%"`
            as a type-specific property, so keying off `group` would reject the
            document the design prints. A node declaring BOTH steps and type is
            the error, and it is the one case JSON Schema draft-07 cannot express
            (see tests/contract/SequenceSchema.Contract.Tests.ps1).

            CONDITIONS ARE PARSED HERE. ConvertFrom-HDTStepCondition runs over
            every step and group condition at import, so a malformed one fails
            authoring rather than a deployment at 3 a.m.

            STEP TYPES ARE DELIBERATELY NOT VALIDATED. Types are pluggable and
            discovered at runtime (DESIGN 4.2), so a sequence authored for a
            workspace whose Modules\ carries a third-party step must still import
            on a machine that does not have it. An unknown type fails the STEP,
            at execution, naming the types that are known.

        .PARAMETER Document
            The parsed document, as returned by ConvertFrom-HDTYaml. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTSequenceDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path

        .NOTES
            The locator in a message is the STEP or the GROUP, never a line
            number: the YAML parser does not carry line information onto the
            object graph it returns, so after parsing there is no honest line to
            report. Only ConvertFrom-HDTYaml, which still holds the parser's own
            exception, can name a line.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $supportedSchemaVersion = 1
    $allowedRootKey = @('schemaVersion', 'id', 'name', 'description', 'variables', 'steps')
    $allowedGroupKey = @('group', 'condition', 'runIn', 'steps')
    $allowedRetryKey = @('count', 'delaySeconds', 'backoff')
    $allowedRunIn = @('WinPE', 'FullOS', 'Any')
    $allowedBackoff = @('fixed', 'exponential')

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. A sequence document must declare schemaVersion, id, name and at least one step.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion, id, name and steps keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedRootKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key a sequence document may declare. The allowed keys are {1}." -f $key, ($allowedRootKey -join ', '))))
        }
    }

    if (-not $Document.Contains('schemaVersion')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'schemaVersion is missing. Every HDT document declares one (DESIGN 2.2); this engine understands schemaVersion 1.'))
    }

    $schemaVersion = $Document['schemaVersion']
    if (-not (($schemaVersion -is [int]) -or ($schemaVersion -is [long]))) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion must be an integer, but it is '{0}'." -f $schemaVersion)))
    }

    $supported = $false
    try {
        $supported = Test-HDTSchemaVersion -SchemaVersion ([int] $schemaVersion) -Supported $supportedSchemaVersion
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion {0} is not a valid schema version. It must be 1 or greater." -f $schemaVersion)))
    }

    if (-not $supported) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion {0} is newer than this engine understands (schemaVersion {1}). Upgrade the engine rather than the workspace." -f $schemaVersion, $supportedSchemaVersion)))
    }

    if (-not $Document.Contains('id')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the id key is missing. The id is what state.json records, so a run cannot be attributed without it.'))
    }

    $id = [string] $Document['id']
    if ($id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the id '{0}' is not usable. An id starts with a letter or a digit and continues with letters, digits, hyphens and underscores." -f $id)))
    }

    if (-not $Document.Contains('name')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the name key is missing. The name is what a technician chooses this sequence by.'))
    }

    if ([string]::IsNullOrWhiteSpace([string] $Document['name'])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the name is empty. The name is what a technician chooses this sequence by.'))
    }

    # -- variables ------------------------------------------------------------

    if ($Document.Contains('variables')) {
        $variable = $Document['variables']

        if (-not ($variable -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'variables must be a mapping of variable name to value.'))
        }

        foreach ($key in @($variable.Keys)) {
            $name = [string] $key

            if ($name.StartsWith('_')) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("'{0}' is engine-owned and cannot be assigned. A variable named _HDT* is set by the engine and is read-only (DESIGN 3.2)." -f $name)))
            }

            if ($name -cnotmatch '^HDT[A-Za-z0-9_]*$') {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("'{0}' is not an HDT variable name. Every deployment variable is prefixed HDT (DESIGN 3.2); run Get-HDTVariableMap for the MDT translation." -f $name)))
            }
        }
    }

    # -- steps ----------------------------------------------------------------

    if (-not $Document.Contains('steps')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the steps key is missing. A sequence document declares a steps list, even if it holds a single step.'))
    }

    $rootStep = $Document['steps']
    if (-not ($rootStep -is [System.Collections.IList])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the steps key must be a list of steps and groups.'))
    }

    if (@($rootStep).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the steps list is empty. A sequence document must declare at least one step.'))
    }

    # A depth-first preorder walk with an explicit stack rather than recursion,
    # so every message is raised from this function and carries its own
    # ThrowTerminatingError. Children are pushed in reverse so they pop in
    # document order.
    $stack = New-Object -TypeName System.Collections.Stack
    for ($position = @($rootStep).Count - 1; $position -ge 0; $position--) {
        $stack.Push([pscustomobject] @{ Node = @($rootStep)[$position]; GroupPath = @() })
    }

    $stepIndex = 0

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $node = $frame.Node
        $groupPath = @($frame.GroupPath)

        $where = 'at the root of the sequence'
        if ($groupPath.Count -gt 0) {
            $where = "in group '{0}'" -f ($groupPath -join '/')
        }

        if (-not ($node -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("a node {0} must be a mapping: either a group with a steps list, or a step with a name and a type." -f $where)))
        }

        $isGroup = $node.Contains('steps')
        $isStep = $node.Contains('type')

        # The label a message names the node by: its group name, or its step
        # name, or nothing when it declared neither.
        $label = ''
        if ($node.Contains('group')) {
            $label = [string] $node['group']
        } elseif ($node.Contains('name')) {
            $label = [string] $node['name']
        }

        if ($isGroup -and $isStep) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the node '{0}' {1} declares both steps and type, so it is both a group and a step. A group declares group and steps; a step declares name and type." -f $label, $where)))
        }

        if (-not $isGroup -and -not $isStep) {
            if ($node.Contains('group')) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("group '{0}' declares no steps. A group is a naming and condition device, so an empty one applies its condition to nothing." -f $label)))
            }

            $stepIndex++
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("step {0} ('{1}'): every step declares a type, which names the Invoke-HDT<Type>Step function that runs it (DESIGN 4.2)." -f $stepIndex, $label)))
        }

        # -- a group ----------------------------------------------------------

        if ($isGroup) {
            if (-not $node.Contains('group') -or [string]::IsNullOrWhiteSpace([string] $node['group'])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("a group {0} declares no name. Every group is named, because the name is what a step.skip record reports." -f $where)))
            }

            $groupName = [string] $node['group']
            $locator = "group '{0}'" -f ((@($groupPath) + $groupName) -join '/')

            foreach ($key in @($node.Keys)) {
                if ($allowedGroupKey -notcontains [string] $key) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: '{1}' is not a key a group may declare. The allowed keys are {2}." -f $locator, $key, ($allowedGroupKey -join ', '))))
                }
            }

            $child = $node['steps']
            if (-not ($child -is [System.Collections.IList])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: steps must be a list of steps and groups." -f $locator)))
            }

            if (@($child).Count -eq 0) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: the steps list is empty. A group is a naming and condition device, so an empty one applies its condition to nothing." -f $locator)))
            }

            if ($node.Contains('condition')) {
                try {
                    # No -Path here: the locator below already names the file, and
                    # prefixing twice reads like two separate failures.
                    $null = ConvertFrom-HDTStepCondition -Condition ([string] $node['condition'])
                } catch {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: {1}" -f $locator, $_.Exception.Message)))
                }
            }

            if ($node.Contains('runIn') -and ($allowedRunIn -notcontains [string] $node['runIn'])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: runIn '{1}' is not a phase. It is one of {2}." -f $locator, $node['runIn'], ($allowedRunIn -join ', '))))
            }

            $childPath = @($groupPath) + $groupName
            for ($position = @($child).Count - 1; $position -ge 0; $position--) {
                $stack.Push([pscustomobject] @{ Node = @($child)[$position]; GroupPath = $childPath })
            }

            continue
        }

        # -- a step -----------------------------------------------------------

        $stepIndex++

        if (-not $node.Contains('name') -or [string]::IsNullOrWhiteSpace([string] $node['name'])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("step {0} {1}: every step needs a non-empty name. The name is what the log, the progress display and state.json report." -f $stepIndex, $where)))
        }

        $stepName = [string] $node['name']
        $locator = "step {0} ('{1}')" -f $stepIndex, $stepName

        $type = [string] $node['type']
        if ($type -cnotmatch '^[A-Za-z][A-Za-z0-9]*$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: '{1}' is not a step type. A type is a letter followed by letters and digits, and names the Invoke-HDT<Type>Step function that runs it." -f $locator, $type)))
        }

        foreach ($flag in @('continueOnError', 'resumable')) {
            if ($node.Contains($flag) -and -not ($node[$flag] -is [bool])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: {1} must be true or false, but it is '{2}'." -f $locator, $flag, $node[$flag])))
            }
        }

        if ($node.Contains('timeoutMinutes')) {
            $timeout = $node['timeoutMinutes']
            $isInteger = ($timeout -is [int]) -or ($timeout -is [long])

            if (-not $isInteger -or [int] $timeout -lt 1) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: timeoutMinutes must be a positive whole number of minutes, but it is '{1}'. Omit it entirely for a step that is not time limited - 0 is far more likely to be a mistake than a declaration." -f $locator, $timeout)))
            }
        }

        if ($node.Contains('runIn') -and ($allowedRunIn -notcontains [string] $node['runIn'])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: runIn '{1}' is not a phase. It is one of {2}." -f $locator, $node['runIn'], ($allowedRunIn -join ', '))))
        }

        if ($node.Contains('log') -and [string]::IsNullOrWhiteSpace([string] $node['log'])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: log must be a file name in the log directory (DESIGN 4.4.4)." -f $locator)))
        }

        if ($node.Contains('retry')) {
            $retry = $node['retry']

            if (-not ($retry -is [System.Collections.IDictionary])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: retry must be a mapping of count, delaySeconds and backoff." -f $locator)))
            }

            foreach ($key in @($retry.Keys)) {
                if ($allowedRetryKey -notcontains [string] $key) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: '{1}' is not a key retry may declare. The allowed keys are {2}." -f $locator, $key, ($allowedRetryKey -join ', '))))
                }
            }

            if ($retry.Contains('count')) {
                $count = $retry['count']
                $isInteger = ($count -is [int]) -or ($count -is [long])

                if (-not $isInteger -or [int] $count -lt 0 -or [int] $count -gt 10) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: retry count must be a whole number between 0 and 10, but it is '{1}'. A step that needs more than ten attempts is broken, not flaky." -f $locator, $count)))
                }
            }

            if ($retry.Contains('delaySeconds')) {
                $delay = $retry['delaySeconds']
                $isInteger = ($delay -is [int]) -or ($delay -is [long])

                if (-not $isInteger -or [int] $delay -lt 0) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: retry delaySeconds must be zero or more seconds, but it is '{1}'." -f $locator, $delay)))
                }
            }

            if ($retry.Contains('backoff') -and ($allowedBackoff -notcontains [string] $retry['backoff'])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: retry backoff '{1}' is unknown. It is one of {2}." -f $locator, $retry['backoff'], ($allowedBackoff -join ', '))))
            }
        }

        if ($node.Contains('condition')) {
            try {
                # No -Path here: the locator below already names the file, and
                    # prefixing twice reads like two separate failures.
                    $null = ConvertFrom-HDTStepCondition -Condition ([string] $node['condition'])
            } catch {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: {1}" -f $locator, $_.Exception.Message)))
            }
        }
    }
}
