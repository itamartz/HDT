function Get-HDTConsoleDetectionText {
    <#
        .SYNOPSIS
            One line saying how an application is detected, for a console row.

        .DESCRIPTION
            THE DOCUMENT'S detect BLOCK IS TWO TO FOUR LINES OF YAML, and a row
            in a properties pane has room for a sentence. This is that sentence:
            what kind of rule it is and the one value that identifies it, which
            is what somebody scanning a list needs to tell two entries apart.

            NO RULE IS NOT NOTHING. DESIGN 8 says an application that declares no
            detection installs every time, and that is a decision somebody made -
            a blank field would read as a detail nobody filled in. It is said in
            words instead.

            Get-HDTApplicationDetectText, next door, is the other half of this
            pair: it writes the rule back out as YAML for the editor. This one
            only ever describes.

        .PARAMETER Detect
            The rule, or $null for an application that declares none.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleDetectionText -Detect $application.Detect
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Detect
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Detect) {
        return 'No rule, so it installs every time this sequence runs.'
    }

    $read = {
        param([string] $Key)

        if ($Detect -is [System.Collections.IDictionary]) {
            if ($Detect.Contains($Key)) { return [string] $Detect[$Key] }
            return ''
        }

        if ($null -eq $Detect.PSObject.Properties[$Key]) { return '' }
        return [string] $Detect.$Key
    }

    $type = & $read 'type'

    # THE ONE VALUE THAT IDENTIFIES THE RULE, per type - the same key each type
    # requires, so there is always one to show.
    $subject = @{
        msiProduct = 'productCode'
        file       = 'path'
        registry   = 'key'
        script     = 'path'
    }

    $said = @{
        msiProduct = 'Installed if the MSI product {0} is registered.'
        file       = 'Installed if the file {0} is there.'
        registry   = 'Installed if the registry key {0} is there.'
        script     = 'Installed if {0} says so.'
    }

    if (-not $subject.ContainsKey($type)) {
        # A TYPE THIS BUILD DOES NOT KNOW is a document the validator would have
        # refused, so it can only arrive from a newer schema. Saying the type is
        # better than saying nothing.
        return ('Detected by a {0} rule.' -f (Get-HDTConsoleDisplayText -Text $type -Fallback 'unrecognised'))
    }

    $value = & $read ([string] $subject[$type])

    return ([string] $said[$type] -f (Get-HDTConsoleDisplayText -Text $value -Fallback '(not recorded)'))
}
