function Get-HDTStepProperty {
    <#
        .SYNOPSIS
            Reads one property off a flattened step, expanded and coerced.

        .DESCRIPTION
            DESIGN 4.2's step contract says a step is "a name, a type and a
            property bag". This is the one reader every HDT step type uses to
            get a value out of that bag, so "what does an absent property mean"
            has one answer rather than one per step type.

            Four things happen, in this order:

              1. the value is read by name, case-insensitively;
              2. absent, null or whitespace-only becomes -Default, UNCOERCED -
                 a default is what the author of the step type wrote, and it is
                 already the type they meant;
              3. -Expand runs Expand-HDTVariableToken against $Context.Variable,
                 because every property in the sample sequences is written
                 "%HDTOSImage%";
              4. -As coerces to String, Int, Long or Bool.

            AN UNRESOLVED TOKEN IS LEFT LITERAL (02-03's rule). A token that
            silently became '' is how a machine ends up named 'PC-'; a step that
            sees a literal '%HDTOSImage%' can say so by name.

            A VALUE THAT WILL NOT CONVERT IS A CONFIGURATION ERROR THAT NAMES
            THE STEP AND THE PROPERTY. An authoring mistake must read

              step 'Apply OS': index 'abc' is not a whole number.

            rather than 'Cannot convert value "abc" to type "System.Int32"'. The
            first sentence names the thing to edit; the second names a type
            system. It is thrown as HDTConfigurationError, which
            Get-HDTFailureClass classes as Configuration, so bad authoring is
            never retried.

            -As Bool PARSES RATHER THAN CASTS, and that is not pedantry:
            [bool] 'false' is $true in PowerShell, because every non-empty
            string is. A reader that cast would make 'setBootOrder: false' mean
            true, on a property whose whole purpose is to turn something off.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. A step whose
            Property bag is $null is read as a step with no properties.

        .PARAMETER Name
            The property name, matched case-insensitively.

        .PARAMETER Default
            What an absent, null or whitespace-only property means. Returned as
            it is, without expansion or coercion.

        .PARAMETER Context
            A New-HDTExecutionContext context. Required by -Expand, which reads
            its Variable dictionary.

        .PARAMETER Expand
            Expand %Var% tokens in a string value.

        .PARAMETER As
            Coerce to String, Int, Long or Bool.

        .OUTPUTS
            System.Object - the value, expanded and coerced.

        .EXAMPLE
            Get-HDTStepProperty -Step $Step -Name 'os' -Context $Context -Expand

        .EXAMPLE
            Get-HDTStepProperty -Step $Step -Name 'minDiskGB' -Default 60 -As Long
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [object] $Default = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Context,

        [Parameter()]
        [switch] $Expand,

        [Parameter()]
        [ValidateSet('String', 'Int', 'Long', 'Bool')]
        [string] $As
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property

    $raw = $null
    if ($null -ne $property) {
        # The bag Import-HDTSequenceDocument builds is case-insensitive already,
        # but a hand-built one - a third party's flattener, or a test - may not
        # be, so the walk is done here rather than assumed of the dictionary.
        foreach ($key in @($property.Keys)) {
            if ([string] $key -eq $Name) {
                $raw = $property[$key]
                break
            }
        }
    }

    if ($null -eq $raw) {
        return $Default
    }

    if (($raw -is [string]) -and [string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    $value = $raw

    if ($Expand -and ($raw -is [string]) -and $null -ne $Context) {
        $value = Expand-HDTVariableToken -Value ([string] $raw) -Scope $Context.Variable
    }

    if ([string]::IsNullOrEmpty($As)) {
        return $value
    }

    $text = ([string] $value).Trim()

    if ($As -eq 'String') {
        return [string] $value
    }

    if ($As -eq 'Bool') {
        if ($value -is [bool]) {
            return [bool] $value
        }

        if (@('true', '1', 'yes') -contains $text.ToLowerInvariant()) {
            return $true
        }

        if (@('false', '0', 'no') -contains $text.ToLowerInvariant()) {
            return $false
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $raw -Category InvalidData `
                    -Message ("step '{0}': {1} '{2}' is not true or false. A yes/no property takes true or false." -f
                        $Step.Name, $Name, $value)))
    }

    if ($As -eq 'Int') {
        $parsed = 0
        if ([int]::TryParse($text, [ref] $parsed)) {
            return [int] $parsed
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $raw -Category InvalidData `
                    -Message ("step '{0}': {1} '{2}' is not a whole number." -f $Step.Name, $Name, $value)))
    }

    $parsedLong = [long] 0
    if ([long]::TryParse($text, [ref] $parsedLong)) {
        return [long] $parsedLong
    }

    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $raw -Category InvalidData `
                -Message ("step '{0}': {1} '{2}' is not a whole number." -f $Step.Name, $Name, $value)))
}
