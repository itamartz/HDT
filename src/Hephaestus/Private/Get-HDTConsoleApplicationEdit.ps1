function Get-HDTConsoleApplicationEdit {
    <#
        .SYNOPSIS
            Turns what was typed into one of the console's application rows into
            the Set-HDTApplication argument that writes it.

        .DESCRIPTION
            THE PANE WRITES THROUGH Set-HDTApplication, AND NOT EVERY ROW IS A
            STRING. A name, a publisher and a command line are typed and passed
            straight on; successCodes and rebootCodes are int[], dependencies is
            string[], and detect is a whole block. Something has to stand between
            the box and the cmdlet, and putting it here rather than in the window
            is what makes it testable without a window.

            THE PARAMETER IS NOT THE KEY, AND THAT IS NOT A DETAIL. app.yaml says
            successCodes and dependencies; the cmdlet takes -SuccessCode and
            -Dependency, singular, because that is the rule for a PowerShell
            parameter. The window used to capitalise the key and splat it, which
            works for exactly the rows that happen to agree - and would call a
            parameter that does not exist for the four that do not.

            AN EMPTY BOX IS AN ANSWER, NOT A BLANK. Set-HDTApplication removes a
            key given an empty list or an empty hashtable, and removing is what
            an administrator means when they clear the box: no dependencies, no
            detection rule, and for the exit codes the defaults DESIGN 8 states -
            0 and 3010 for success, 3010 for reboot. It does not mean "no code
            succeeds", which is why the row shows the inherited pair rather than
            an empty box in the first place.

            THE DETECTION RULE IS PARSED AS YAML, BY THE PARSER THAT READS
            app.yaml. A second dialect - key=value, or JSON in a box - would be a
            second thing to learn and a second thing to get wrong, and the block
            in the box is the block in the document.

        .PARAMETER Property
            The document key the row writes: 'install', 'successCodes',
            'dependencies', 'detect' and so on.

        .PARAMETER Text
            What was typed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Parameter, the
            Set-HDTApplication parameter name; Value, what to pass it; and Text,
            that value written the way it would be typed, for the command the
            console's footer echoes. DESIGN 12: every edit names the command that
            would repeat it, and a list echoed as a string teaches a line that
            would not run.

        .EXAMPLE
            Get-HDTConsoleApplicationEdit -Property 'successCodes' -Text '0, 3010'

        .EXAMPLE
            Get-HDTConsoleApplicationEdit -Property 'detect' -Text "type: msiProduct`nproductCode: '{23170F69}'"
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

    # THE LABEL, SO A REFUSAL NAMES THE ROW THE TECHNICIAN IS LOOKING AT. '0, ok
    # is not a number' is a puzzle; 'Success codes: ok is not a number' is an
    # instruction.
    $label = @{
        successCodes = 'Success codes'
        rebootCodes  = 'Reboot codes'
        dependencies = 'Depends on'
        detect       = 'Detection'
    }

    $split = {
        param([string] $Value)

        return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }

    # SINGLE QUOTES AND A DOUBLED ONE INSIDE, which is PowerShell's own rule and
    # the only one that survives an apostrophe in a display name.
    $quote = {
        param([string] $Value)

        return ("'" + ($Value -replace "'", "''") + "'")
    }

    if (($Property -eq 'successCodes') -or ($Property -eq 'rebootCodes')) {
        $parameter = 'SuccessCode'
        if ($Property -eq 'rebootCodes') { $parameter = 'RebootCode' }

        $number = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in (& $split $Text)) {
            $parsed = 0
            if (-not [int]::TryParse($current, [ref] $parsed)) {
                throw (New-Object System.ArgumentException (
                        "{0}: '{1}' is not a number. An exit code list is whole numbers separated by commas - 0, 3010." -f $label[$Property], $current))
            }

            [void] $number.Add($parsed)
        }

        return [pscustomobject] @{
            Parameter = $parameter
            Value     = [int[]] @($number)
            Text      = ('@({0})' -f (@($number) -join ', '))
        }
    }

    if ($Property -eq 'dependencies') {
        $id = @(& $split $Text)

        return [pscustomobject] @{
            Parameter = 'Dependency'
            Value     = [string[]] $id
            Text      = ('@({0})' -f ((@($id) | ForEach-Object { & $quote $_ }) -join ', '))
        }
    }

    if ($Property -eq 'detect') {
        if ([string]::IsNullOrWhiteSpace($Text)) {
            return [pscustomobject] @{ Parameter = 'Detect'; Value = @{}; Text = '@{ }' }
        }

        $parsed = $null

        try {
            $parsed = ConvertFrom-HDTYaml -Yaml $Text -Path 'the detection rule'
        } catch {
            throw (New-Object System.ArgumentException (
                    "Detection: the detection rule could not be read. {0}" -f $_.Exception.Message))
        }

        if (-not ($parsed -is [System.Collections.IDictionary])) {
            throw (New-Object System.ArgumentException (
                    "Detection: the detection rule is a block of keys, one per line - 'type: msiProduct' and then the keys that type takes. What was typed is not one."))
        }

        $pair = @($parsed.Keys | ForEach-Object {
                '{0} = {1}' -f $_, (& $quote ([string] $parsed[$_]))
            })

        return [pscustomobject] @{
            Parameter = 'Detect'
            Value     = $parsed
            Text      = ('@{{ {0} }}' -f ($pair -join '; '))
        }
    }

    # EVERY OTHER ROW IS A STRING WHOSE KEY IS THE PARAMETER, one capital apart:
    # name, description, publisher, version, folder, install, uninstall, runIn.
    return [pscustomobject] @{
        Parameter = $Property.Substring(0, 1).ToUpperInvariant() + $Property.Substring(1)
        Value     = $Text
        Text      = (& $quote $Text)
    }
}
