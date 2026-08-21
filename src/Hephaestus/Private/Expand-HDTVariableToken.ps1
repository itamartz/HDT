function Expand-HDTVariableToken {
    <#
        .SYNOPSIS
            Expands %Var% tokens in a value against the resolution scope.

        .DESCRIPTION
            The rule "%Var% expands against already-resolved variables",
            with the three behaviours that make it safe to hand to an
            administrator:

            RECURSIVE. A token names a variable whose RAW value may itself hold a
            token, so expansion recurses rather than running a single pass.
            `HDTComputerName: LT-%HDTSitePrefix%` works when HDTSitePrefix is
            itself `%HDTRegion%-01`.

            CYCLE-SAFE. Recursion is bounded by the CHAIN of variable names
            currently being expanded, not by a depth counter. A token already on
            the chain is a cycle and raises a terminating HDTConfigurationError
            whose message names the whole cycle - the "cyclic %Var%
            expansion detected and reported, not hang". A depth counter would
            report "too deep" for both a cycle and a legitimately long chain, and
            would name neither.

            HONEST ABOUT WHAT IT COULD NOT RESOLVE. A token naming nothing in the
            scope, or naming a $null, is left LITERALLY in the output and its name
            is added to -Unresolved. MDT leaves such a token alone; emptying it
            silently would turn an authoring mistake into a machine named 'PC-'.
            -Unresolved is what makes it visible without making it fatal.

            The token grammar is %Name% where Name matches [A-Za-z_][A-Za-z0-9_]*,
            and %% is a literal %. Requiring a letter or underscore first means a
            batch file's %1 and a '50% done' message pass through untouched.

        .PARAMETER Value
            The text to expand. An empty string is returned unchanged.

        .PARAMETER Scope
            Name -> RAW value. Raw, not expanded: that is what makes a cycle
            detectable at all, because two variables that reference each other
            only look cyclic before expansion.

        .PARAMETER Unresolved
            An ArrayList to append the name of every token that resolved to
            nothing. Names are added once each. Optional - omit it where the
            caller does not report unresolved tokens.

        .PARAMETER Chain
            The variable names already being expanded, outermost first. Callers
            seed it with the name of the variable whose value this is; the
            function appends to it as it recurses. A token already on the chain
            is the cycle.

        .PARAMETER Path
            The file this value came from, for the error message. Optional.

        .OUTPUTS
            System.String

        .EXAMPLE
            Expand-HDTVariableToken -Value 'LT-%HDTSerialNumber%' -Scope $scope

            Returns 'LT-FIXTURE-SERIAL-0001' when the scope holds that serial.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Value,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Scope,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Unresolved,

        [Parameter()]
        [AllowNull()]
        [string[]] $Chain,

        [Parameter()]
        [string] $Path,

        # THIS FUNCTION CALLING ITSELF, and nothing else ever passes it.
        #
        # MDT's #Left(...)# is evaluated once, on the way out of the OUTERMOST
        # call - running it at every level would hand a function its own output.
        # "Outermost" was first inferred from -Chain not being passed, and that
        # was wrong in the one place that matters: Add-HDTResolvedVariable seeds
        # the chain with the variable's own name on EVERY rule value, so a rules
        # file never had its expressions evaluated at all. A machine stopped at
        # Apply Windows Settings with a 47-character name that still read
        # '#Left(PC-...', while this function's own tests passed - they call it
        # directly, and a direct caller does not pass a chain.
        #
        # A marker the recursion sets cannot be got wrong by a caller that has
        # its own reason to pass a chain.
        [Parameter()]
        [switch] $Nested
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrEmpty($Value)) {
        return $Value
    }

    $chainName = @()
    if ($null -ne $Chain) {
        $chainName = @($Chain)
    }

    $builder = New-Object -TypeName System.Text.StringBuilder
    $position = 0

    foreach ($match in [regex]::Matches($Value, '%%|%([A-Za-z_][A-Za-z0-9_]*)%')) {

        [void] $builder.Append($Value.Substring($position, $match.Index - $position))
        $position = $match.Index + $match.Length

        # %% is a literal per cent, and never a token.
        if ($match.Value -eq '%%') {
            [void] $builder.Append('%')
            continue
        }

        $name = $match.Groups[1].Value

        # -contains on a string array is case-insensitive, which is what the
        # scope's own lookup is, so HDTa and HDTA are one variable and one cycle.
        if ($chainName -contains $name) {
            $cycle = @($chainName) + $name
            $rendered = @($cycle | ForEach-Object { '%{0}%' -f $_ }) -join ' -> '

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the value of {0} cannot be expanded: {1} is cyclic. A variable cannot reference itself, directly or through another variable." -f $cycle[0], $rendered)))
        }

        $raw = $null
        if ($Scope.Contains($name)) {
            $raw = $Scope[$name]
        }

        # Absent, or present and $null: left literally in the output and reported.
        if ($null -eq $raw) {
            [void] $builder.Append($match.Value)

            if ($null -ne $Unresolved -and -not ($Unresolved -contains $name)) {
                [void] $Unresolved.Add($name)
            }

            continue
        }

        if (($raw -is [System.Collections.IList]) -and -not ($raw -is [string])) {
            $text = @(@($raw) | ForEach-Object { ConvertTo-HDTComparableString -Value $_ }) -join ','
        } else {
            $text = ConvertTo-HDTComparableString -Value $raw
        }

        [void] $builder.Append((Expand-HDTVariableToken -Value $text -Scope $Scope `
                    -Unresolved $Unresolved -Chain (@($chainName) + $name) -Path $Path -Nested))
    }

    [void] $builder.Append($Value.Substring($position))

    # -- and then MDT's #Left(...)# ------------------------------------------
    #
    # ONLY AT THE TOP, NEVER INSIDE THE RECURSION. The recursion marks itself
    # with -Nested; a caller never passes it. Evaluating at every level would
    # run a function over its own output - and inferring it from a missing
    # -Chain got it wrong everywhere a rule was resolved.
    #
    # AFTER THE TOKENS, WHICH IS THE WHOLE POINT: what Left() receives is the
    # expanded text, so '#Left(PC-%HDTSerialNumber%, 15)#' does what an
    # administrator moving from CustomSettings.ini expects it to.
    if (-not $Nested) {
        return (Expand-HDTRuleExpression -Value $builder.ToString() -Path $Path)
    }

    return $builder.ToString()
}
