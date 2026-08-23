function Get-HDTConsoleConditionOption {
    <#
        .SYNOPSIS
            What the editor's Options tab offers instead of a blank condition box.

        .DESCRIPTION
            THE CONDITION GRAMMAR IS CLOSED AND TINY: a %Var% token, one of four
            operators, and a value. That makes the set of legal conditions
            enumerable - and a free-text box the worst possible way to enter one.
            A box accepts

                %HDTIsUEFI% = true

            which is not the grammar. Assert-HDTSequenceDocument refuses the
            document at import, so the mistake surfaces at the far end of the
            share, to somebody who did not make it. A picker cannot spell it
            wrong.

            THE VARIABLES COME FROM Get-HDTVariableMap AND NOT FROM A LIST HERE.
            A picker with its own idea of what exists is a picker that goes stale
            the first time a variable is added - and the map is already the one
            place that knows the MDT equivalents and which names the engine sets.

            THE TOKEN CARRIES ITS PERCENT SIGNS. A condition holding the bare
            word HDTIsUEFI compares the literal text to 'True' and is quietly
            always false: legal, parseable, and never once true. Handing the
            window the finished token is what stops that being possible.

            THE SUGGESTED VALUES ARE THIS FILE'S OWN, and they are the one
            judgement in it. The variable map records what a variable MEANS, not
            what it may hold; a boolean fact compared against a typed 'yes' is a
            step that never runs and nothing says so. Only the closed sets are
            listed - a computer name has no menu, and an empty list is what tells
            the window to leave that box free.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Variable, Operator
            and Format.

        .EXAMPLE
            $option = Get-HDTConsoleConditionOption
            $option.Format -f '%HDTIsUEFI%', '==', 'True'

            %HDTIsUEFI% == True

        .EXAMPLE
            (Get-HDTConsoleConditionOption).Variable |
                Where-Object { @($_.Suggested).Count -gt 0 } |
                Format-Table Name, Suggested

            The variables a picker can offer a menu for.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE CLOSED SETS, AND ONLY THOSE. Anything not named here gets a free box,
    # which is the honest answer for a computer name or a model string.
    $suggested = @{}

    foreach ($name in @('HDTIsUEFI', 'HDTIsVM', 'HDTIsLaptop', 'HDTIsDesktop', 'HDTIsServer',
            'HDTSecureBootEnabled')) {

        # 'True' and 'False' with those exact spellings: the runtime renders a
        # boolean through ConvertTo-HDTComparableString, which produces 'True',
        # and compares case-insensitively - so this matches what it will see.
        $suggested[$name] = [string[]] @('True', 'False')
    }

    $suggested['HDTBootMode'] = [string[]] @('PXE', 'Media')
    $suggested['HDTArchitecture'] = [string[]] @('x64', 'x86', 'arm64')

    $variable = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @(Get-HDTVariableMap)) {
        $name = [string] $current.HDTName

        $values = [string[]] @()
        if ($suggested.ContainsKey($name)) { $values = [string[]] $suggested[$name] }

        [void] $variable.Add([pscustomobject] @{
                Name        = $name
                Token       = '%{0}%' -f $name
                Description = [string] $current.Description
                Origin      = [string] $current.Origin
                Writable    = [bool] $current.Writable
                Suggested   = $values
            })
    }

    # THE FOUR Test-HDTStepCondition IMPLEMENTS, in the order an administrator
    # reaches for them. Offering '=' or '-contains' would produce a document the
    # importer refuses, which is the failure this list exists to prevent.
    $operator = @(
        [pscustomobject] @{ Token = '=='; Display = 'is' }
        [pscustomobject] @{ Token = '!='; Display = 'is not' }
        [pscustomobject] @{ Token = '-like'; Display = 'matches (wildcards)' }
        [pscustomobject] @{ Token = '-notlike'; Display = 'does not match (wildcards)' }
    )

    return [pscustomobject] @{
        Variable = [pscustomobject[]] @($variable | Sort-Object -Property Name)
        Operator = [pscustomobject[]] @($operator)

        # THE WHOLE COMPOSITION, so the window joins nothing itself. Three
        # controls and one -f is the entire contribution an adapter should make.
        Format   = '{0} {1} {2}'
    }
}
