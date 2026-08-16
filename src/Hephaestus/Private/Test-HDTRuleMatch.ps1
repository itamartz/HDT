function Test-HDTRuleMatch {
    <#
        .SYNOPSIS
            Tests whether a rule's when conditions all match the current scope.

        .DESCRIPTION
            Rules are walked top to bottom; a rule applies if every
            when key matches". This is that test, and the four decisions it
            encodes are deliberate:

            NO CONDITION MATCHES. A rule with no when, or an empty when, applies
            to every machine. That is the Fallback rule.

            AN ABSENT OR NULL VALUE NEVER MATCHES. A rule keyed on a fact this
            machine does not have must not fire, including against an empty
            pattern. A machine with no TPM has HDTTPMVersion = $null, and a rule
            keyed on it is simply not for that machine.

            A LIST MATCHES ON ANY ELEMENT. HDTDefaultGateway is a list on a
            multi-NIC machine and MDT's DefaultGateway behaves the same way, so
            `when: { HDTDefaultGateway: "10.20.30.1" }` fires on a machine whose
            second adapter carries that gateway.

            THE OPERATOR IS CHOSEN PER PATTERN. -like when the expanded pattern
            contains * or ?, -eq otherwise. Both are case-insensitive. Always
            using -like would read the '[' in a model name as a character class,
            so a machine called 'Model[1]' would never match itself.

            Comparison is on ConvertTo-HDTComparableString output, which is why
            `HDTIsLaptop: true` in YAML matches the [bool] fact from CIM. The
            pattern is %Var%-expanded first, so a condition may reference another
            variable; a pattern whose token could not be resolved does not match,
            because comparing against a literal '%HDTFoo%' would be an accident
            rather than an answer.

        .PARAMETER When
            The rule's when mapping, as Import-HDTRuleDocument normalised it.
            $null or empty means "always".

        .PARAMETER Scope
            Name -> RAW value, the same dictionary %Var% expansion reads.

        .PARAMETER Unresolved
            An optional ArrayList that collects the names of tokens a pattern
            referenced but the scope could not supply.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTRuleMatch -When $rule.When -Scope $scope

            Returns $true when every condition of the rule matches.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [System.Collections.IDictionary] $When,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Scope,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Unresolved
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $When) {
        return $true
    }

    # An unresolved token in a pattern has to be observable even when the caller
    # did not ask for the list, because it is what turns the condition off.
    $tracker = $Unresolved
    if ($null -eq $tracker) {
        $tracker = New-Object -TypeName System.Collections.ArrayList
    }

    foreach ($key in @($When.Keys)) {
        $name = [string] $key

        if (-not $Scope.Contains($name)) {
            return $false
        }

        $actual = $Scope[$name]
        if ($null -eq $actual) {
            return $false
        }

        $before = $tracker.Count
        $pattern = Expand-HDTVariableToken -Value (ConvertTo-HDTComparableString -Value $When[$key]) `
            -Scope $Scope -Unresolved $tracker -Chain @($name)

        if ($tracker.Count -gt $before) {
            return $false
        }

        $isWildcard = ($pattern -match '[*?]')

        # @() over a scalar yields one candidate and over a list yields its
        # elements, which is exactly the "any element matches" rule. An empty
        # list therefore yields no candidate and does not match.
        $candidate = @($actual)

        $matched = $false
        foreach ($item in $candidate) {
            $text = ConvertTo-HDTComparableString -Value $item
            if ($null -eq $text) {
                continue
            }

            if ($isWildcard) {
                if ($text -like $pattern) {
                    $matched = $true
                }
            } else {
                if ($text -eq $pattern) {
                    $matched = $true
                }
            }
        }

        if (-not $matched) {
            return $false
        }
    }

    return $true
}
