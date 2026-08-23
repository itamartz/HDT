function Test-HDTStepCondition {
    <#
        .SYNOPSIS
            Evaluates a step or group condition against the resolved variables.

        .DESCRIPTION
            The runtime half of the closed grammar ConvertFrom-HDTStepCondition
            defines. It expands %Var% on BOTH operands
            against the live variable dictionary, renders both through
            ConvertTo-HDTComparableString so a boolean is 'True' and an integer is
            its invariant text, and compares CASE-INSENSITIVELY.

              == / -eq        equal
              != / -ne        not equal
              -like           wildcard match
              -notlike        wildcard non-match

            AN ABSENT CONDITION IS TRUE. $null, an empty string and whitespace all
            return $true, so a step with no condition: always runs and a group
            with no condition: imposes nothing on its children.

            AN UNRESOLVED TOKEN IS LEFT LITERAL, which is 02-03's rule and is the
            behaviour that matters most here. A condition naming a variable that
            does not exist evaluates to $false - it does not throw, and the token
            does not silently become the empty string. A condition that collapsed
            to "" == "" is how MDT-era task sequences ran the wrong branch on a
            typo. The token name is appended to -Unresolved so the loop can log
            it, because invisible is the only thing worse than wrong.

            A MALFORMED CONDITION THROWS, but it should never reach here:
            Assert-HDTSequenceDocument parses every condition at import, so
            authoring catches it first.

        .PARAMETER Condition
            The condition text. $null, empty and whitespace are all true.

        .PARAMETER Variable
            The live variable dictionary, name -> value. Looked up
            case-insensitively when it was built that way, which every HDT
            dictionary is.

        .PARAMETER Unresolved
            An ArrayList to append the name of every %Var% that resolved to
            nothing. Optional.

        .PARAMETER Path
            The file the condition came from, for the error message. Optional.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            $context = [pscustomobject] @{ Variable = [ordered] @{ HDTIsUefi = $true } }
            $v = $context.Variable
            Test-HDTStepCondition -Condition '"%_HDTPhase%" == "FullOS"' -Variable $context.Variable

            The phase condition. _HDTPhase is WinPE or FullOS, never "OS".

        .EXAMPLE
            $unresolved = New-Object System.Collections.ArrayList
            Test-HDTStepCondition -Condition '"%HDTSite%" == "HQ"' -Variable $v -Unresolved $unresolved

            Returns $false and leaves 'HDTSite' in $unresolved when nothing set it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Condition,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Unresolved,

        [Parameter()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Condition)) {
        return $true
    }

    $parsed = ConvertFrom-HDTStepCondition -Condition $Condition -Path $Path

    $left = ConvertTo-HDTComparableString -Value (Expand-HDTVariableToken -Value $parsed.Left -Scope $Variable -Unresolved $Unresolved -Path $Path)
    $right = ConvertTo-HDTComparableString -Value (Expand-HDTVariableToken -Value $parsed.Right -Scope $Variable -Unresolved $Unresolved -Path $Path)

    switch ($parsed.Operator) {
        '==' { return ($left -eq $right) }
        '-eq' { return ($left -eq $right) }
        '!=' { return ($left -ne $right) }
        '-ne' { return ($left -ne $right) }
        '-like' { return ($left -like $right) }
        '-notlike' { return ($left -notlike $right) }
    }

    # Unreachable: the operator came from the grammar's own closed set.
    return $false
}
