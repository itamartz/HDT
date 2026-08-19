function Get-HDTConsoleDetectionForm {
    <#
        .SYNOPSIS
            The detection rule as a form: which type, which boxes, what is in
            them, and whether it can be written.

        .DESCRIPTION
            A DETECTION RULE IS A TYPE AND THE KEYS THAT TYPE TAKES, and which
            keys those are is the type's decision - msiProduct wants a product
            code, registry wants a key and optionally a value and its data.
            Typing that as YAML into a box means knowing the key list and the
            indentation, and getting either wrong is a document the validator
            refuses after the fact.

            SO THE TYPE IS CHOSEN AND THE BOXES FOLLOW FROM IT. This says which
            boxes, what is already in them, and whether what is in them is a
            rule that can be written.

            THE KEY LIST IS Get-HDTApplicationDetectKey'S, which the validator
            and the projector already read. A second list here would be a second
            place for the window and the engine to disagree about what a
            registry rule is - and the window would be the one that was wrong.

            NO RULE IS ONE OF THE CHOICES, not the absence of one. DESIGN 8 says
            an application that declares no detection installs every time, which
            is a decision somebody makes deliberately for a package that has no
            way to be detected.

            CHANGING THE TYPE EMPTIES THE BOXES. A product code is not a
            registry key, and carrying one into the other's box writes a rule
            that parses and detects nothing.

            AN EMPTY OPTIONAL BOX IS LEFT OUT OF THE DOCUMENT. An absent key and
            a blank one are different things: the validator accepts the absence,
            and the engine would compare against the blank.

        .PARAMETER Type
            The type to build the form for. Omitted, the type the rule already
            declares - or none.

        .PARAMETER Detect
            The rule as the document holds it, or nothing.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

              Type      the type the form is showing
              Choice    every type, with the words a technician reads
              Field     one row per box: Key, Label, Value, Required, Hint
              Complete  the boxes hold a rule that can be written
              Message   which box is missing, when one is
              Rule      what to pass to Set-HDTApplication -Detect, or $null
              CommandText  that same rule as it would be TYPED, so the footer
                        shows a line somebody could run rather than a quoted
                        blob - a command that would not run teaches nothing

        .EXAMPLE
            Get-HDTConsoleDetectionForm -Detect $application.Detect

        .EXAMPLE
            Get-HDTConsoleDetectionForm -Type 'registry' -Detect $current

            The form after somebody changed the type in the dropdown.

        .LINK
            Set-HDTApplication

        .LINK
            Test-HDTApplicationDetection
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $Type,

        [Parameter(Position = 1)]
        [AllowNull()]
        [object] $Detect = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $schema = Get-HDTApplicationDetectKey

    # WHAT EACH TYPE AND EACH KEY IS, IN WORDS. The key list is the engine's;
    # this is only what to call it on screen, which is the one thing the engine
    # has no opinion about.
    $said = @{
        msiProduct = 'An MSI product code is registered'
        file       = 'A file is there'
        registry   = 'A registry key is there'
        script     = 'A script says so'
    }

    $label = @{
        productCode = 'Product code'
        path        = 'Path'
        version     = 'Version'
        key         = 'Registry key'
        value       = 'Value name'
        data        = 'Value data'
    }

    $hint = @{
        productCode = "The GUID the .msi registers itself under, braces and all - Get-HDTApplicationDetection reads it off an installed machine, or the .msi's ProductCode property has it."
        path        = 'A path on the deployed machine, not on the share. Environment variables are expanded when it is checked.'
        version     = 'Optional. The file version this counts as installed at or above; omitted, the file merely being there is enough.'
        key         = 'A registry key on the deployed machine, for example HKLM:\SOFTWARE\Contoso\Suite.'
        value       = 'Optional. A value under that key; omitted, the key existing is enough.'
        data        = 'Optional. What that value has to hold; omitted, the value existing is enough.'
    }

    # WHICH TYPE THE FORM IS SHOWING: the one asked for, or the one the document
    # declares, or none.
    $declared = ''
    if ($null -ne $Detect) {
        if ($Detect -is [System.Collections.IDictionary]) {
            if ($Detect.Contains('type')) { $declared = [string] $Detect['type'] }
        } elseif ($null -ne $Detect.PSObject.Properties['Type']) {
            $declared = [string] $Detect.Type
        }
    }

    $showing = $declared
    if ($PSBoundParameters.ContainsKey('Type')) { $showing = $Type }

    $choice = New-Object -TypeName System.Collections.ArrayList

    [void] $choice.Add([pscustomobject] @{
            Type    = ''
            Display = 'No rule - it installs every time the sequence runs'
        })

    foreach ($current in @($schema.Keys)) {
        [void] $choice.Add([pscustomobject] @{
                Type    = [string] $current
                Display = [string] $said[[string] $current]
            })
    }

    $field = New-Object -TypeName System.Collections.ArrayList
    $rule = $null
    $complete = $true
    $message = ''

    if (-not [string]::IsNullOrWhiteSpace($showing)) {

        if (-not $schema.Contains($showing)) {
            # A TYPE THIS BUILD DOES NOT KNOW can only come from a document
            # written against a newer schema, and the window must not silently
            # replace it with one it does understand.
            return [pscustomobject] @{
                Type     = $showing
                Choice   = [pscustomobject[]] @($choice)
                Field    = [pscustomobject[]] @()
                Complete = $false
                Message  = ("'{0}' is not a detection type this build can run. The types are {1}." -f
                    $showing, (@($schema.Keys) -join ', '))
                Rule        = $null
                CommandText = '@{ }'
            }
        }

        # THE VALUES ONLY SURVIVE A TYPE THAT DID NOT CHANGE.
        $keep = ($declared -eq $showing)

        $read = {
            param([string] $Key)

            if (-not $keep -or $null -eq $Detect) { return '' }

            if ($Detect -is [System.Collections.IDictionary]) {
                if ($Detect.Contains($Key)) { return [string] $Detect[$Key] }
                return ''
            }

            if ($null -eq $Detect.PSObject.Properties[$Key]) { return '' }
            return [string] $Detect.$Key
        }

        $rule = [System.Collections.Specialized.OrderedDictionary]::new()
        $rule['type'] = $showing

        $missing = New-Object -TypeName System.Collections.ArrayList

        foreach ($key in @($schema[$showing].Required + $schema[$showing].Optional)) {
            $keyName = [string] $key
            $value = [string] (& $read $keyName)
            $required = ($schema[$showing].Required -contains $keyName)

            [void] $field.Add([pscustomobject] @{
                    Key      = $keyName
                    Label    = [string] $label[$keyName]
                    Value    = $value
                    Required = $required
                    Hint     = [string] $hint[$keyName]
                })

            if ($required -and [string]::IsNullOrWhiteSpace($value)) {
                [void] $missing.Add([string] $label[$keyName])
                continue
            }

            # AN EMPTY OPTIONAL BOX IS NOT A KEY. The validator accepts the
            # absence; the engine would compare against the blank.
            if (-not [string]::IsNullOrWhiteSpace($value)) { $rule[$keyName] = $value }
        }

        if (@($missing).Count -gt 0) {
            $complete = $false
            $rule = $null

            $message = "this rule needs {0} before it can be saved." -f ((@($missing) -join ' and ').ToLowerInvariant())
        }
    }

    # THE RULE AS IT WOULD BE TYPED. @{ } is how the rule is REMOVED - see
    # Set-HDTApplication - so it is the honest text for "no rule" as well as the
    # thing the window passes.
    $commandText = '@{ }'

    if ($null -ne $rule) {
        $pair = @(@($rule.Keys) | ForEach-Object {
                "{0} = '{1}'" -f [string] $_, ([string] $rule[$_] -replace "'", "''")
            })

        $commandText = '@{{ {0} }}' -f ($pair -join '; ')
    }

    return [pscustomobject] @{
        Type        = $showing
        Choice      = [pscustomobject[]] @($choice)
        Field       = [pscustomobject[]] @($field)
        Complete    = $complete
        Message     = $message
        Rule        = $rule
        CommandText = $commandText
    }
}
