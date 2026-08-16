function ConvertFrom-HDTStepCondition {
    <#
        .SYNOPSIS
            Parses a step condition into Left, Operator and Right.

        .DESCRIPTION
            HDT deliberately has no condition language, and an authored
            sequence uses exactly one shape - '"%_HDTPhase%" == "FullOS"' - so
            the grammar is CLOSED and tiny:

              <condition> := <operand> <operator> <operand>
              <operand>   := '"' anything-but-a-double-quote '"'
                           |  a token with no whitespace and no double quote
              <operator>  := == | != | -eq | -ne | -like | -notlike

            Surrounding double quotes are stripped from each operand, so the
            evaluator compares values rather than quoting. The raw text is kept on
            the result for the message a failure prints.

            IT IS CALLED AT IMPORT TIME. Assert-HDTSequenceDocument runs it over
            every condition in the document, so a malformed one fails authoring
            rather than a deployment at 3 a.m. Nothing about a condition is
            deferred to the moment it matters.

            The refusals are deliberate, not accidental. A boolean expression
            ('%A% == "1" -and %B% == "2"') has no match in this grammar and is
            rejected: a half-working condition language is worse than none,
            because it runs the wrong branch silently. So is an unterminated
            quote, which is why an unquoted operand may not contain a double
            quote at all - otherwise '"%A% == "1"' would parse as the two
            operands '"%A%' and '1' and mean something nobody wrote.

            YAML NOTE. Because a condition carries double quotes as part of its
            own grammar, the whole condition must be a SINGLE-quoted YAML scalar:

              condition: '"%_HDTPhase%" == "FullOS"'

            The unquoted form is not parseable YAML at all.

        .PARAMETER Condition
            The condition text, exactly as the document carried it.

        .PARAMETER Path
            The file the condition came from, for the error message. Optional.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Left, Operator,
            Right and Text. Left and Right have their surrounding quotes removed;
            Text is the raw input.

        .EXAMPLE
            ConvertFrom-HDTStepCondition -Condition '"%_HDTPhase%" == "FullOS"'

            Returns Left = '%_HDTPhase%', Operator = '==', Right = 'FullOS'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Condition,

        [Parameter()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $grammar = 'A condition is <operand> <operator> <operand>, where an operand is a double-quoted string or a token with no whitespace, and an operator is one of == != -eq -ne -like -notlike. HDT has no condition language.'

    if ([string]::IsNullOrWhiteSpace($Condition)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the condition is empty. {0}" -f $grammar)))
    }

    # An unquoted operand may not contain a double quote: that is what turns an
    # unterminated quote into a refusal instead of a silent misparse.
    $pattern = '^\s*(?<left>"[^"]*"|[^\s"]+)\s+(?<operator>==|!=|-eq|-ne|-like|-notlike)\s+(?<right>"[^"]*"|[^\s"]+)\s*$'

    $match = [regex]::Match($Condition, $pattern)

    if (-not $match.Success) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the condition '{0}' cannot be parsed. {1}" -f $Condition, $grammar)))
    }

    return [pscustomobject] @{
        Left     = $match.Groups['left'].Value -replace '^"(.*)"$', '$1'
        Operator = $match.Groups['operator'].Value
        Right    = $match.Groups['right'].Value -replace '^"(.*)"$', '$1'
        Text     = $Condition
    }
}
