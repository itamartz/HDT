function Assert-HDTRuleDocument {
    <#
        .SYNOPSIS
            Validates a parsed rules.yaml against the DESIGN 3.3 authoring rules.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/rules.schema.json is a gate for the console, editors and CI
            while this is the gate for a deployment.

            It throws on the first violation and returns nothing otherwise. Every
            failure is a terminating error built by New-HDTErrorRecord, so it
            names the file, carries the file as its TargetObject and reports
            HDTConfigurationError - DESIGN 12.1's "fail fast and point at the
            file".

            The authoring rules, in the order they are checked:

              document   not empty; a mapping; only schemaVersion and rules;
                         schemaVersion present, an integer, and not newer than
                         this engine (delegated to Test-HDTSchemaVersion);
                         rules present, a list, and not empty
              rule       a mapping; a non-empty name; a name no other rule uses;
                         no key outside name/when/set/setFrom; exactly one of
                         set and setFrom
              when       at least one condition; every value a scalar - a nested
                         mapping is not a condition language, and HDT
                         deliberately does not have one
              set        at least one variable; every name matching
                         ^HDT[A-Za-z0-9_]*$; no _HDT* name, which is engine-owned
                         and cannot be assigned; every value a
                         scalar or a list
              setFrom    a non-empty script path

            Two of those deserve their reason stated. Duplicate rule NAMES are
            rejected because provenance records which rule set a variable,
and two rules called Fallback make that answer
            ambiguous. An unknown key is rejected rather than ignored because the
            INI dialect HDT replaces let 'Priority' and friends look meaningful
            while doing nothing - a typo that silently does nothing is worse than
            a refusal.

        .PARAMETER Document
            The parsed document, as returned by ConvertFrom-HDTYaml. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTRuleDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path

        .NOTES
            The locator in a message is the RULE, not a line number:
            "rule 2 ('Latitude naming'): ...". The YAML parser does not carry
            line information onto the object graph it returns, so after parsing
            there is no honest line to report. Only ConvertFrom-HDTYaml, which
            still holds the parser's own exception, can name a line.
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
    $allowedRuleKey = @('name', 'when', 'set', 'setFrom')

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. A rules document must declare schemaVersion and at least one rule.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion and rules keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if (@('schemaVersion', 'rules') -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key a rules document may declare. The allowed keys are schemaVersion and rules." -f $key)))
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

    if (-not $Document.Contains('rules')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the rules key is missing. A rules document declares a rules list, even if it holds a single fallback.'))
    }

    $rule = $Document['rules']
    if (-not ($rule -is [System.Collections.IList])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the rules key must be a list of rules.'))
    }

    if (@($rule).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the rules list is empty. A rules document must declare at least one rule.'))
    }

    # -- each rule ------------------------------------------------------------

    $seenName = New-Object -TypeName System.Collections.ArrayList
    $index = 0

    foreach ($current in @($rule)) {
        $index++
        $locator = 'rule {0}' -f $index

        if (-not ($current -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: a rule must be a mapping with a name and either set or setFrom." -f $locator)))
        }

        $name = ''
        if ($current.Contains('name')) {
            $name = [string] $current['name']
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: every rule needs a non-empty name. The name is what provenance reports when this rule sets a variable." -f $locator)))
        }

        $locator = "rule {0} ('{1}')" -f $index, $name

        if ($seenName -contains $name) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: two rules share this name, which makes provenance ambiguous. Rule names must be unique." -f $locator)))
        }
        [void] $seenName.Add($name)

        foreach ($key in @($current.Keys)) {
            if ($allowedRuleKey -notcontains [string] $key) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: '{1}' is not a key a rule may declare. The allowed keys are {2}." -f $locator, $key, ($allowedRuleKey -join ', '))))
            }
        }

        $hasSet = $current.Contains('set')
        $hasSetFrom = $current.Contains('setFrom')

        if (-not $hasSet -and -not $hasSetFrom) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: a rule must declare either set or setFrom. A rule that assigns nothing has no effect." -f $locator)))
        }

        if ($hasSet -and $hasSetFrom) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: a rule declares either set or setFrom, never both." -f $locator)))
        }

        # -- when -------------------------------------------------------------

        if ($current.Contains('when')) {
            $when = $current['when']

            if (-not ($when -is [System.Collections.IDictionary])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: when must be a mapping of variable name to expected value." -f $locator)))
            }

            if (@($when.Keys).Count -eq 0) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: when must hold at least one condition. Omit it entirely for a rule that always applies." -f $locator)))
            }

            foreach ($key in @($when.Keys)) {
                $value = $when[$key]
                $isScalar = ($value -is [string]) -or ($value -is [bool]) -or ($value -is [int]) -or ($value -is [long]) -or ($value -is [double]) -or ($value -is [decimal])

                if (-not $isScalar) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: the condition '{1}' must be a string, a boolean or a number. A rule condition is a comparison, not an expression - use setFrom for real logic." -f $locator, $key)))
                }
            }
        }

        # -- set --------------------------------------------------------------

        if ($hasSet) {
            $set = $current['set']

            if (-not ($set -is [System.Collections.IDictionary])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: set must be a mapping of variable name to value." -f $locator)))
            }

            if (@($set.Keys).Count -eq 0) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: set must assign at least one variable." -f $locator)))
            }

            foreach ($key in @($set.Keys)) {
                $variable = [string] $key

                if ($variable.StartsWith('_')) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: '{1}' is engine-owned and cannot be assigned. A variable named _HDT* is set by the engine and is read-only (DESIGN 3.2)." -f $locator, $variable)))
                }

                if ($variable -cnotmatch '^HDT[A-Za-z0-9_]*$') {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: '{1}' is not an HDT variable name. Every deployment variable is prefixed HDT (DESIGN 3.2); run Get-HDTVariableMap for the MDT translation." -f $locator, $variable)))
                }

                $value = $set[$key]
                $isScalar = ($value -is [string]) -or ($value -is [bool]) -or ($value -is [int]) -or ($value -is [long]) -or ($value -is [double]) -or ($value -is [decimal])

                if (-not $isScalar -and -not ($value -is [System.Collections.IList])) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("{0}: the value of '{1}' must be a string, a boolean, a number or a list." -f $locator, $variable)))
                }
            }
        }

        # -- setFrom ----------------------------------------------------------

        if ($hasSetFrom) {
            $setFrom = $current['setFrom']

            if (-not ($setFrom -is [string]) -or [string]::IsNullOrWhiteSpace([string] $setFrom)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: setFrom must be the path of a script, relative to the workspace root." -f $locator)))
            }
        }
    }
}
