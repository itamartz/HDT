function Get-HDTConsoleMediaEdit {
    <#
        .SYNOPSIS
            Turns what was typed into one of the console's media rows into the
            Set-HDTMedia argument that writes it.

        .DESCRIPTION
            THE PANE WRITES THROUGH Set-HDTMedia, AND ONE ROW OUT OF FOUR IS NOT
            A STRING. description, selectionProfile and output are typed and
            passed straight on - the capital-letter rule already names their
            parameter, the same rule Get-HDTConsoleApplicationEdit falls back to
            for the rows an application has that are plain strings too. Enabled
            is the one that is not: the row shows 'yes' or
            'no - Update Media Content refuses it while it is off', and
            Set-HDTMedia takes it as [bool]. The explanation stays out of what
            gets typed back - it lives in the row's -Hint instead - so the box
            holds only the word a technician actually types.

            AN UNRECOGNISED WORD IS REFUSED, NOT GUESSED AT. 'maybe', 'y', or a
            stray space-only box are not silently false; Set-HDTMedia would
            accept whatever [bool] cast PowerShell gave it, which is true for
            any non-empty string - so guessing here is how a box holding 'nope'
            would enable a disc nobody meant to turn on.

        .PARAMETER Property
            The document key the row writes: 'description', 'selectionProfile',
            'output' or 'enabled'.

        .PARAMETER Text
            What was typed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Parameter, the
            Set-HDTMedia parameter name; Value, what to pass it; and Text, that
            value written the way it would be typed, for the command the
            console's footer echoes.

        .EXAMPLE
            Get-HDTConsoleMediaEdit -Property 'description' -Text 'The bench disc.'

        .EXAMPLE
            Get-HDTConsoleMediaEdit -Property 'enabled' -Text 'no'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Property,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Text
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $quote = {
        param([string] $Value)
        return ("'" + ($Value -replace "'", "''") + "'")
    }

    if ($Property -eq 'enabled') {
        $trimmed = $Text.Trim()

        $truthy = @('yes', 'true', '1')
        $falsy = @('no', 'false', '0')

        if ($truthy -contains $trimmed.ToLowerInvariant()) {
            return [pscustomobject] @{ Parameter = 'Enabled'; Value = $true; Text = '$true' }
        }

        if ($falsy -contains $trimmed.ToLowerInvariant()) {
            return [pscustomobject] @{ Parameter = 'Enabled'; Value = $false; Text = '$false' }
        }

        throw (New-Object System.ArgumentException (
                "Enabled: '{0}' is not yes or no. Type yes to let Update Media Content build this disc, or no to hold it back." -f $Text))
    }

    return [pscustomobject] @{
        Parameter = $Property.Substring(0, 1).ToUpperInvariant() + $Property.Substring(1)
        Value     = $Text
        Text      = (& $quote $Text)
    }
}
