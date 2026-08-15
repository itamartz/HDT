function Resolve-HDTVariable {
    <#
        .SYNOPSIS
            Resolves the deployment variables from all five sources and records
            where every value came from.

        .DESCRIPTION
            The variable engine: DESIGN 3.1's five sources in precedence order,
            DESIGN 3.3's first-match-wins rule evaluation, %Var% expansion, and
            setFrom: script rules - with a provenance record for every resolved
            variable, which is the whole point (DESIGN 3.1: "the single biggest
            debugging pain in MDT is not knowing why HDTComputerName ended up as
            it did").

            THE SOURCES, IN ORDER. Each is applied in turn and nothing overwrites
            a variable an earlier source already resolved:

              1. -CommandLine      what the technician typed  -> CommandLine
              2. -MachineOverride  Control\machines\<UUID>.yaml -> MachineOverride
              3. -RuleDocument     rules.yaml, top to bottom  -> Rule / RuleScript
              4. -Fact             gathered facts             -> GatheredFact
              5. -SequenceDefault  sequence.yaml defaults     -> SequenceDefault

            Precedence is therefore write order rather than a comparison:
            Add-HDTResolvedVariable refuses to overwrite, so applying the sources
            in this order IS the precedence, and a later fallback rule can only
            fill what nothing above it set.

            THE SCOPE. One dictionary of RAW, unexpanded values, seeded with the
            sequence defaults and then the facts, and updated by every assignment.
            Lookup precedence falls out of write order: an assigned value shadows
            a fact, a fact shadows a default. The scope is what `when` matching
            and %Var% expansion read; the EXPANDED value is what lands in the
            result. Keeping raw values is what makes a cycle detectable, since two
            variables that reference each other only look cyclic before expansion.

            WITHIN A RULE, set: keys are applied in document order and the scope
            updates as each is applied - so a later key may expand a %Var% an
            earlier key set, and a later rule may match on a value an earlier rule
            set. Rules are never short-circuited: every rule is evaluated, because
            it is variables that are first-match-wins, not rules.

            IT TOUCHES NOTHING. No filesystem service, no CIM, no script
            execution: the rule document and the machine override are loaded by
            their own functions and handed in, and a setFrom rule reaches its
            script only through -ScriptInvoker. That is what lets the whole engine
            run under Pester against fakes (DESIGN 12.2.1) and is why phase 03 can
            swap in the real invoker unchanged.

        .PARAMETER CommandLine
            Source 1. Variables the technician supplied.

        .PARAMETER MachineOverride
            Source 2. The Variable member of Get-HDTMachineOverride's result.

        .PARAMETER MachineOverridePath
            The file those overrides came from, recorded as the provenance File.
            Get-HDTMachineOverride returns it as Path.

        .PARAMETER RuleDocument
            Source 3. An Import-HDTRuleDocument result: Path, SchemaVersion and
            Rule.

        .PARAMETER Fact
            Source 4. A Get-HDTMachineFact result.

        .PARAMETER SequenceDefault
            Source 5. The defaults declared by sequence.yaml.

        .PARAMETER ScriptInvoker
            An IScriptInvoker, required only if a matching rule uses setFrom. The
            script receives a COPY of the scope, so a user script cannot mutate
            engine state, and the object it emits becomes variables: a
            [pscustomobject] by its properties, an IDictionary by its keys.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Variable    ordered, case-insensitive: name -> expanded value
              Provenance  ordered, case-insensitive: name -> record of
                          Name, Value, Source, Rule, RuleIndex, File, RawValue,
                          Expanded, Order
              Unresolved  [string[]] the distinct %Var% names nothing supplied,
                          sorted ordinally

            Source is a closed set: CommandLine, MachineOverride, Rule,
            RuleScript, GatheredFact, SequenceDefault.

            Every parameter is optional. Resolving nothing is a valid, empty
            answer rather than an error - the engine calls this before it
            necessarily knows which sources exist.

        .EXAMPLE
            $result = Resolve-HDTVariable -RuleDocument $rules -Fact $fact
            $result.Variable['HDTComputerName']

        .EXAMPLE
            Resolve-HDTVariable -CommandLine @{ HDTTaskSequenceID = 'LAB-CLIENT' } `
                -MachineOverride $override.Variable -MachineOverridePath $override.Path `
                -RuleDocument $rules -Fact $fact `
                -SequenceDefault @{ HDTDiskLayout = 'uefi-standard' } `
                -ScriptInvoker (New-HDTScriptInvoker)

            All five sources at once, the way the engine calls it in WinPE.

        .EXAMPLE
            Get-HDTVariableProvenance -Resolution $result |
                Format-Table Order, Name, Value, Source, Rule

            Why every value is what it is - the second half of the answer.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $CommandLine,

        # WHAT A TECHNICIAN TYPED AT THE WIZARD (DESIGN 11.2). It beats the
        # rules and the per-machine override, and loses only to the command
        # line - which was set before the machine booted, so the wizard could
        # not have known about it while the reverse is not true.
        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Wizard,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $MachineOverride,

        [Parameter()]
        [string] $MachineOverridePath,

        [Parameter()]
        [AllowNull()]
        [object] $RuleDocument,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Fact,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $SequenceDefault,

        [Parameter()]
        [AllowNull()]
        [object] $ScriptInvoker
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $resolution = [pscustomobject] ([ordered] @{
            Variable   = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            Provenance = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            Unresolved = New-Object -TypeName System.Collections.ArrayList
        })

    # -- the scope: RAW values, lowest source first so later writes shadow ------

    $scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($null -ne $SequenceDefault) {
        foreach ($key in @($SequenceDefault.Keys)) {
            $scope[[string] $key] = $SequenceDefault[$key]
        }
    }

    if ($null -ne $Fact) {
        foreach ($key in @($Fact.Keys)) {
            $scope[[string] $key] = $Fact[$key]
        }
    }

    # -- precedence 1: the command line ----------------------------------------

    if ($null -ne $CommandLine) {
        foreach ($key in @($CommandLine.Keys)) {
            $null = Add-HDTResolvedVariable -Resolution $resolution -Scope $scope `
                -Name ([string] $key) -Value $CommandLine[$key] -Source 'CommandLine'
        }
    }

    # -- precedence 1b: what the technician typed at the wizard -----------------
    #
    # AFTER THE COMMAND LINE AND BEFORE EVERYTHING ELSE. A command line was set
    # before this machine booted; the wizard answered a question that was still
    # open after it did, so where both speak the wizard yields - it could not
    # have known about the command line, and the technician who set the command
    # line could not have known what the wizard would ask.
    #
    # AN EMPTY BOX IS NOT AN ANSWER. Collected as '', it would RESOLVE the
    # variable and stop the rule that would have supplied a real one - the same
    # trap Get-HDTWizardSummary refuses to write into a snippet, and the reason
    # a technician who tabbed past a box gets the rule's value rather than
    # nothing at all.
    if ($null -ne $Wizard) {
        foreach ($key in @($Wizard.Keys)) {

            $value = $Wizard[$key]
            if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { continue }
            if ($null -eq $value) { continue }

            $null = Add-HDTResolvedVariable -Resolution $resolution -Scope $scope `
                -Name ([string] $key) -Value $value -Source 'Wizard'
        }
    }

    # -- precedence 2: the per-machine override --------------------------------

    if ($null -ne $MachineOverride) {
        foreach ($key in @($MachineOverride.Keys)) {
            $null = Add-HDTResolvedVariable -Resolution $resolution -Scope $scope `
                -Name ([string] $key) -Value $MachineOverride[$key] -Source 'MachineOverride' -File $MachineOverridePath
        }
    }

    # -- precedence 3: rules.yaml, top to bottom -------------------------------

    if ($null -ne $RuleDocument) {
        foreach ($rule in @($RuleDocument.Rule)) {

            if (-not (Test-HDTRuleMatch -When $rule.When -Scope $scope -Unresolved $resolution.Unresolved)) {
                continue
            }

            $locator = "rule {0} ('{1}')" -f $rule.Index, $rule.Name

            if (-not [string]::IsNullOrWhiteSpace($rule.SetFrom)) {

                if ($null -eq $ScriptInvoker) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $RuleDocument.Path `
                                -Message ("{0}: setFrom names the script '{1}' but no script invoker was supplied, so the rule cannot be applied. Pass -ScriptInvoker." -f $locator, $rule.SetFrom)))
                }

                # A COPY, so a user script cannot mutate engine state.
                $copy = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($key in @($scope.Keys)) {
                    $copy[[string] $key] = $scope[$key]
                }

                $returned = $null
                $failure = $null
                try {
                    $returned = $ScriptInvoker.Invoke($rule.SetFrom, $copy)
                } catch {
                    $failure = $_
                }

                if ($null -ne $failure) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $RuleDocument.Path `
                                -Message ("{0}: the setFrom script '{1}' failed. {2}" -f $locator, $rule.SetFrom, $failure.Exception.Message) `
                                -InnerException $failure.Exception))
                }

                # A script that emits nothing sets nothing, and that is not an error.
                if ($null -eq $returned) {
                    continue
                }

                $emitted = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

                if ($returned -is [System.Collections.IDictionary]) {
                    foreach ($key in @($returned.Keys)) {
                        $emitted[[string] $key] = $returned[$key]
                    }
                } else {
                    foreach ($property in @($returned.PSObject.Properties)) {
                        $emitted[[string] $property.Name] = $property.Value
                    }
                }

                foreach ($key in @($emitted.Keys)) {
                    $name = [string] $key

                    if ($name.StartsWith('_')) {
                        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $RuleDocument.Path `
                                    -Message ("{0}: the setFrom script '{1}' returned '{2}', which is engine-owned and cannot be assigned. A variable named _HDT* is set by the engine and is read-only (DESIGN 3.2)." -f $locator, $rule.SetFrom, $name)))
                    }

                    $null = Add-HDTResolvedVariable -Resolution $resolution -Scope $scope `
                        -Name $name -Value $emitted[$key] -Source 'RuleScript' `
                        -Rule $rule.Name -RuleIndex $rule.Index -File $rule.SetFrom
                }

                continue
            }

            foreach ($key in @($rule.Set.Keys)) {
                $null = Add-HDTResolvedVariable -Resolution $resolution -Scope $scope `
                    -Name ([string] $key) -Value $rule.Set[$key] -Source 'Rule' `
                    -Rule $rule.Name -RuleIndex $rule.Index -File $RuleDocument.Path
            }
        }
    }

    # -- precedence 4: the gathered facts --------------------------------------

    if ($null -ne $Fact) {
        foreach ($key in @($Fact.Keys)) {
            $null = Add-HDTResolvedVariable -Resolution $resolution -Scope $scope `
                -Name ([string] $key) -Value $Fact[$key] -Source 'GatheredFact'
        }
    }

    # -- precedence 5: the sequence defaults -----------------------------------

    if ($null -ne $SequenceDefault) {
        foreach ($key in @($SequenceDefault.Keys)) {
            $null = Add-HDTResolvedVariable -Resolution $resolution -Scope $scope `
                -Name ([string] $key) -Value $SequenceDefault[$key] -Source 'SequenceDefault'
        }
    }

    # Ordinal, not Sort-Object: a culture-sensitive sort would order the report
    # differently on a machine with different regional settings.
    $unresolved = [string[]] @($resolution.Unresolved)
    [array]::Sort($unresolved, [System.StringComparer]::Ordinal)
    $resolution.Unresolved = $unresolved

    return $resolution
}
