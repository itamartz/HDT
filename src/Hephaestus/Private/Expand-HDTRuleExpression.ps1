function Expand-HDTRuleExpression {
    <#
        .SYNOPSIS
            Evaluates the #Function(...)# expressions in a rules value.

        .DESCRIPTION
            A RULES VALUE MAY CALL A FUNCTION BETWEEN HASHES, and this replaces
            the call with its result:

                HDTComputerName: '#Left(PC-%HDTSerialNumber%, 15)#'

            Building a computer name from a serial number is the case it exists
            for, because Windows Setup SILENTLY IGNORES a ComputerName over
            fifteen characters and names the machine itself. HDT refuses such a
            name loudly, which is better - but refusing without offering a way
            to shorten one left an administrator writing a PowerShell file to
            take a substring. The hashes and the function names are
            CustomSettings.ini's, so a rule carried over from an existing
            deployment still reads the same.

            A CLOSED SET OF FUNCTIONS, NOT AN EVALUATOR. Nothing here runs a
            language. A rules file is a document an administrator is HANDED - by
            a colleague, by a vendor, in a support ticket - and one that can run
            arbitrary code is one that can do anything the deployment account
            can. Real logic already has a home: setFrom names a script, and the
            engine runs it through IScriptInvoker, so it is testable and visible.

            IT RUNS AFTER %Var%, so what a function receives is the expanded
            text and '#Left(PC-%HDTSerialNumber%, 15)#' is what somebody types.

            A HASH IS A COMMON CHARACTER - '#3' in a bay number, a colour in a
            template. A value is an expression only where a hash is followed by
            a function name and a bracket, which is the rule %Var% already
            follows for a batch file's %1.

            AND IT NEVER EMPTIES A VALUE IT DID NOT UNDERSTAND. An unknown
            function, the wrong number of arguments, a length that is not a
            number: each is a terminating HDTConfigurationError naming what was
            written and what is available. Silently producing '' is how a
            machine ends up named 'PC-'.

        .PARAMETER Value
            The text to evaluate, normally after %Var% expansion.

        .PARAMETER Path
            The document the value came from, for the error message.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the value with every expression replaced.

        .EXAMPLE
            Expand-HDTRuleExpression -Value '#Left(PC-5784-6600, 8)#'

            PC-5784
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Value,

        [Parameter()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrEmpty($Value)) {
        return $Value
    }

    # VBScript's names, because these are the ones already written in every
    # CustomSettings.ini an administrator will paste in here. The number is the
    # arity and it is checked - Left(x) is a typo, not a defaulted argument.
    $known = [ordered] @{
        'Left'  = 2
        'Right' = 2
        'Mid'   = 3
        'UCase' = 1
        'LCase' = 1
        'Trim'  = 1
    }

    # Nothing that could be a call, nothing to do - and a value with a bare '#'
    # in it never reaches the matcher below.
    if ($Value -notmatch '#[A-Za-z]') {
        return $Value
    }

    $builder = New-Object -TypeName System.Text.StringBuilder
    $position = 0

    # Up to the FIRST closing bracket, so two expressions in one value are two
    # matches rather than one that swallows the text between them.
    foreach ($match in [regex]::Matches($Value, '#([A-Za-z]+)\(([^)]*)\)#')) {

        [void] $builder.Append($Value.Substring($position, $match.Index - $position))
        $position = $match.Index + $match.Length

        $name = $match.Groups[1].Value
        $argumentText = $match.Groups[2].Value

        $matched = ''
        foreach ($candidate in @($known.Keys)) {
            if ([string]::Equals([string] $candidate, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = [string] $candidate
            }
        }

        if ([string]::IsNullOrEmpty($matched)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a function a rule may call. MDT evaluates VBScript between hashes; HDT evaluates only {1}, because a rules file is a document somebody is handed and one that can run arbitrary code can do anything the deployment account can. For real logic, point the rule at a script with setFrom." -f
                            $name, (@($known.Keys) -join ', '))))
        }

        # SPLIT ON COMMAS, TRIMMED, AND A QUOTED ONE UNQUOTED - somebody pasting
        # MDT's own line writes Left("PC-", 4) and should not be told it is wrong.
        $argument = @()
        if (-not [string]::IsNullOrEmpty($argumentText)) {
            $argument = @($argumentText -split ',' | ForEach-Object {
                    ([string] $_).Trim().Trim('"')
                })
        }

        $wanted = [int] $known[$matched]

        if (@($argument).Count -ne $wanted) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} takes {1} argument(s) and was given {2} in '{3}'." -f
                            $matched, $wanted, @($argument).Count, $match.Value)))
        }

        $text = [string] $argument[0]

        # A COUNT THAT IS NOT A NUMBER IS AN AUTHORING MISTAKE, and what it would
        # otherwise produce is an empty string.
        $number = @()
        for ($i = 1; $i -lt @($argument).Count; $i++) {
            $parsed = 0

            if (-not [int]::TryParse([string] $argument[$i], [ref] $parsed)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0} takes a whole number, but '{1}' was written in '{2}'." -f
                                $matched, $argument[$i], $match.Value)))
            }

            if ($parsed -lt 0) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0} takes a length of zero or more, but {1} was written in '{2}'." -f
                                $matched, $parsed, $match.Value)))
            }

            $number += $parsed
        }

        $result = ''

        switch ($matched) {
            'Left' {
                $take = [System.Math]::Min([int] $number[0], $text.Length)
                $result = $text.Substring(0, $take)
            }
            'Right' {
                $take = [System.Math]::Min([int] $number[0], $text.Length)
                $result = $text.Substring($text.Length - $take, $take)
            }
            'Mid' {
                # ONE-BASED, as VBScript's Mid is and as an MDT line assumes.
                $start = [System.Math]::Max(1, [int] $number[0])

                if ($start -gt $text.Length) {
                    $result = ''
                } else {
                    $take = [System.Math]::Min([int] $number[1], $text.Length - ($start - 1))
                    $result = $text.Substring($start - 1, $take)
                }
            }
            'UCase' { $result = $text.ToUpperInvariant() }
            'LCase' { $result = $text.ToLowerInvariant() }
            'Trim' { $result = $text.Trim() }
        }

        [void] $builder.Append($result)
    }

    [void] $builder.Append($Value.Substring($position))

    return $builder.ToString()
}
