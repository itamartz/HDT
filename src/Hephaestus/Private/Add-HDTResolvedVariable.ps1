function Add-HDTResolvedVariable {
    <#
        .SYNOPSIS
            Assigns a variable if nothing has resolved it yet, and records where
            the value came from.

        .DESCRIPTION
            The single writer of a resolution result, and the place DESIGN 3.1's
            precedence is actually enforced.

            The precedence is not a comparison anywhere in the engine.
            Resolve-HDTVariable applies the five sources in order and this
            function refuses to overwrite a variable that is already resolved.
            First writer wins, so applying the sources in the DESIGN 3.1 order IS
            the precedence, and a later fallback rule can only fill what nothing
            above it set. One rule, held in one place, rather than a priority
            comparison repeated at five call sites.

            Two values are stored, deliberately:

              the SCOPE receives the RAW value, unexpanded. That is what makes a
              cycle detectable at all - two variables that reference each other
              only look cyclic before expansion - and it is what `when` matching
              and later %Var% expansion read;

              the RESULT receives the EXPANDED value, which is what a step, a
              condition and an unattend.xml will actually use.

            The provenance record carries both, plus the source, the rule and its
            index, the file, and a 1-based Order, so DESIGN 3.1's "every variable
            resolution records which source set it" survives the call rather than
            being a log line that scrolled past.

        .PARAMETER Resolution
            The result object being built: Variable and Provenance as ordered,
            case-insensitive dictionaries and Unresolved as an ArrayList.

        .PARAMETER Scope
            Name -> RAW value, the dictionary %Var% expansion and `when` matching
            read.

        .PARAMETER Name
            The variable to assign. A name starting with an underscore is
            refused: _HDT* is engine-owned. Assert-HDTRuleDocument
            holds that rule for rules.yaml, but the command line, a machine
            override and a setFrom script never pass through that validator, so
            the single writer holds it too.

        .PARAMETER Value
            The raw value. A string is expanded; an array is expanded element by
            element; a boolean, a number and anything else pass through untouched.

        .PARAMETER Source
            Which of the five DESIGN 3.1 sources supplied the value. A closed set:
            CommandLine, MachineOverride, Rule, RuleScript, GatheredFact,
            SequenceDefault. Closed because provenance is machine-readable - the
            console and ConvertTo-HDTReport switch on it.

        .PARAMETER Rule
            The rule name, for a rule or rule-script source.

        .PARAMETER RuleIndex
            The 1-based rule index. 0 where no rule was involved.

        .PARAMETER File
            The file the value came from: rules.yaml, the machine override, or the
            setFrom script. $null for the command line, facts and defaults, which
            have no file.

        .OUTPUTS
            System.Boolean. $true when it assigned, $false when the variable was
            already resolved.

        .EXAMPLE
            Add-HDTResolvedVariable -Resolution $resolution -Scope $scope `
                -Name 'HDTComputerName' -Value 'LT-%HDTSerialNumber%' `
                -Source 'Rule' -Rule 'Latitude naming' -RuleIndex 2 -File $document.Path
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Adds to an in-memory result object; it changes nothing outside the caller.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Resolution,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Scope,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('CommandLine', 'MachineOverride', 'Rule', 'RuleScript', 'GatheredFact', 'SequenceDefault')]
        [string] $Source,

        [Parameter()]
        [string] $Rule,

        [Parameter()]
        [int] $RuleIndex = 0,

        [Parameter()]
        [string] $File
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Name.StartsWith('_')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $File `
                    -Message ("'{0}' is engine-owned and cannot be assigned. A variable named _HDT* is set by the engine and is read-only." -f $Name)))
    }

    # First writer wins. Checked BEFORE expansion, so a value that was never
    # going to be used cannot report an unresolved token it never had to resolve.
    if ($Resolution.Provenance.Contains($Name)) {
        return $false
    }

    $expanded = $Value
    $changed = $false

    if ($Value -is [string]) {
        $expanded = Expand-HDTVariableToken -Value $Value -Scope $Scope `
            -Unresolved $Resolution.Unresolved -Chain @($Name) -Path $File
        $changed = ($expanded -cne $Value)
    } elseif ($Value -is [System.Collections.IList]) {
        $element = New-Object -TypeName System.Collections.ArrayList

        foreach ($item in @($Value)) {
            if ($item -is [string]) {
                $text = Expand-HDTVariableToken -Value $item -Scope $Scope `
                    -Unresolved $Resolution.Unresolved -Chain @($Name) -Path $File

                if ($text -cne $item) {
                    $changed = $true
                }

                [void] $element.Add($text)
            } else {
                [void] $element.Add($item)
            }
        }

        $expanded = @($element)
    }

    # The scope keeps the RAW value; the result keeps the expanded one.
    $Scope[$Name] = $Value
    $Resolution.Variable[$Name] = $expanded

    $Resolution.Provenance[$Name] = [pscustomobject] ([ordered] @{
            Name      = $Name
            Value     = $expanded
            Source    = $Source
            Rule      = $(if ([string]::IsNullOrEmpty($Rule)) { $null } else { $Rule })
            RuleIndex = $RuleIndex
            File      = $(if ([string]::IsNullOrEmpty($File)) { $null } else { $File })
            RawValue  = $Value
            Expanded  = $changed
            Order     = $Resolution.Provenance.Count + 1
        })

    return $true
}
