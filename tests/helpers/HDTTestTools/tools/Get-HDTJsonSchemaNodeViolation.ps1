function Get-HDTJsonSchemaNodeViolation {
    <#
        .SYNOPSIS
            Validates one JSON value against one JSON Schema subschema.

        .DESCRIPTION
            The recursion behind Get-HDTJsonSchemaViolation. It implements the
            draft-07 subset listed in Get-HDTJsonSchemaVocabulary, and NOTHING
            ELSE: the vocabulary walk runs first, in Get-HDTJsonSchemaViolation,
            so anything this does not handle has already thrown by the time
            execution reaches here.

            IT COLLECTS RATHER THAN SHORT-CIRCUITS. A fixture with three wrong
            fields should name three fields; stopping at the first turns a schema
            contract into a guessing game.

            EVERY KEYWORD APPLIES TO ITS OWN TYPE ONLY, which is draft-07's rule
            and is easy to get wrong in the strict direction: `minLength: 3` says
            nothing about the number 7, and a schema that used `pattern` on a
            union type would start rejecting the non-string half.

            A $ref REPLACES ITS SIBLINGS. draft-07 says a schema object
            containing $ref ignores every other keyword in it, and no schema in
            schemas/ relies on the other reading.

        .PARAMETER Instance
            The value being validated.

        .PARAMETER Node
            The subschema: an object, or the boolean true/false.

        .PARAMETER Root
            The whole schema document, so a $ref can be resolved.

        .PARAMETER Location
            A JSON pointer to Instance within the document, for the report.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Location, Keyword
            and Message. Nothing at all when the value validates.

        .EXAMPLE
            Get-HDTJsonSchemaNodeViolation -Instance 1 -Node ([pscustomobject] @{ type = 'string' }) -Root $root -Location '#'

            Reports one violation: expected string, found integer.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Instance,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Node,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $Root,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Location
    )

    $violation = New-Object -TypeName System.Collections.ArrayList

    function Add-HDTJsonSchemaViolationRecord {
        param([string] $Keyword, [string] $Message)

        [void] $violation.Add([pscustomobject] @{
                Location = $Location
                Keyword  = $Keyword
                Message  = $Message
            })
    }

    # draft-07 allows a bare boolean as a whole schema: true accepts everything,
    # false accepts nothing. `additionalProperties: false` is the form that
    # reaches this in practice.
    if ($Node -is [bool]) {
        if (-not $Node) {
            Add-HDTJsonSchemaViolationRecord -Keyword 'false' -Message 'the schema at this point accepts no value at all'
        }
        return @($violation)
    }

    if ($null -eq $Node) { return @($violation) }

    # A $ref replaces the schema object it appears in.
    if ($null -ne $Node.PSObject.Properties['$ref']) {
        $target = Resolve-HDTJsonSchemaReference -Root $Root -Reference ([string] $Node.PSObject.Properties['$ref'].Value) -Location $Location
        return @(Get-HDTJsonSchemaNodeViolation -Instance $Instance -Node $target -Root $Root -Location $Location)
    }

    $instanceType = Get-HDTJsonSchemaInstanceType -Instance $Instance

    # ---- type -------------------------------------------------------------
    if ($null -ne $Node.PSObject.Properties['type']) {
        $accepted = @($Node.PSObject.Properties['type'].Value)

        $matched = $false
        foreach ($name in $accepted) {
            if ($name -eq $instanceType) { $matched = $true }
            # Every integer is a number; the reverse is not true.
            if ($name -eq 'number' -and $instanceType -eq 'integer') { $matched = $true }
        }

        if (-not $matched) {
            Add-HDTJsonSchemaViolationRecord -Keyword 'type' -Message (
                "expected {0}, found {1}" -f (($accepted | ForEach-Object { "'$_'" }) -join ' or '), $instanceType)
        }
    }

    # ---- enum and const ---------------------------------------------------
    if ($null -ne $Node.PSObject.Properties['enum']) {
        $canonical = ConvertTo-HDTCanonicalJson -Value $Instance
        $allowed = @(@($Node.PSObject.Properties['enum'].Value) | ForEach-Object { ConvertTo-HDTCanonicalJson -Value $_ })

        # -cnotcontains, not -notcontains: PowerShell's -contains is case
        # INSENSITIVE and JSON is not, so 'info' would satisfy an enum of
        # 'Info' and every enum in schemas/ would be half a rule.
        if ($allowed -cnotcontains $canonical) {
            Add-HDTJsonSchemaViolationRecord -Keyword 'enum' -Message (
                "{0} is not one of {1}" -f $canonical, ($allowed -join ', '))
        }
    }

    if ($null -ne $Node.PSObject.Properties['const']) {
        $canonical = ConvertTo-HDTCanonicalJson -Value $Instance
        $expected = ConvertTo-HDTCanonicalJson -Value $Node.PSObject.Properties['const'].Value

        if ($canonical -cne $expected) {
            Add-HDTJsonSchemaViolationRecord -Keyword 'const' -Message ("expected {0}, found {1}" -f $expected, $canonical)
        }
    }

    # ---- strings ----------------------------------------------------------
    if ($instanceType -eq 'string') {
        if ($null -ne $Node.PSObject.Properties['minLength']) {
            $minimum = [int] $Node.PSObject.Properties['minLength'].Value
            if ($Instance.Length -lt $minimum) {
                Add-HDTJsonSchemaViolationRecord -Keyword 'minLength' -Message (
                    "'{0}' is {1} characters, and at least {2} are required" -f $Instance, $Instance.Length, $minimum)
            }
        }

        if ($null -ne $Node.PSObject.Properties['pattern']) {
            $pattern = [string] $Node.PSObject.Properties['pattern'].Value
            if (-not [regex]::IsMatch($Instance, $pattern)) {
                Add-HDTJsonSchemaViolationRecord -Keyword 'pattern' -Message (
                    "'{0}' does not match {1}" -f $Instance, $pattern)
            }
        }
    }

    # ---- numbers ----------------------------------------------------------
    if ($instanceType -eq 'integer' -or $instanceType -eq 'number') {
        $value = [double] $Instance

        if ($null -ne $Node.PSObject.Properties['minimum']) {
            $minimum = [double] $Node.PSObject.Properties['minimum'].Value
            if ($value -lt $minimum) {
                Add-HDTJsonSchemaViolationRecord -Keyword 'minimum' -Message ("{0} is below the minimum {1}" -f $value, $minimum)
            }
        }

        if ($null -ne $Node.PSObject.Properties['maximum']) {
            $maximum = [double] $Node.PSObject.Properties['maximum'].Value
            if ($value -gt $maximum) {
                Add-HDTJsonSchemaViolationRecord -Keyword 'maximum' -Message ("{0} is above the maximum {1}" -f $value, $maximum)
            }
        }
    }

    # ---- arrays -----------------------------------------------------------
    if ($instanceType -eq 'array') {
        $element = @($Instance)

        if ($null -ne $Node.PSObject.Properties['minItems']) {
            $minimum = [int] $Node.PSObject.Properties['minItems'].Value
            if ($element.Count -lt $minimum) {
                Add-HDTJsonSchemaViolationRecord -Keyword 'minItems' -Message (
                    "the array holds {0} items, and at least {1} are required" -f $element.Count, $minimum)
            }
        }

        if ($null -ne $Node.PSObject.Properties['uniqueItems'] -and [bool] $Node.PSObject.Properties['uniqueItems'].Value) {
            # HashSet[string] and not @{}: a PowerShell hashtable compares keys
            # case insensitively, so ['a','A'] would read as a duplicate pair.
            $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
            foreach ($item in $element) {
                $canonical = ConvertTo-HDTCanonicalJson -Value $item
                if (-not $seen.Add($canonical)) {
                    Add-HDTJsonSchemaViolationRecord -Keyword 'uniqueItems' -Message ("{0} appears more than once" -f $canonical)
                }
            }
        }

        if ($null -ne $Node.PSObject.Properties['items']) {
            $itemSchema = $Node.PSObject.Properties['items'].Value
            $index = 0
            foreach ($item in $element) {
                foreach ($record in @(Get-HDTJsonSchemaNodeViolation -Instance $item -Node $itemSchema -Root $Root `
                            -Location ('{0}/{1}' -f $Location, $index))) {
                    [void] $violation.Add($record)
                }
                $index = $index + 1
            }
        }
    }

    # ---- objects ----------------------------------------------------------
    if ($instanceType -eq 'object') {
        $member = @($Instance.PSObject.Properties)
        $name = @($member | ForEach-Object { $_.Name })

        if ($null -ne $Node.PSObject.Properties['required']) {
            foreach ($required in @($Node.PSObject.Properties['required'].Value)) {
                if ($name -cnotcontains $required) {
                    Add-HDTJsonSchemaViolationRecord -Keyword 'required' -Message ("'{0}' is required and is not present" -f $required)
                }
            }
        }

        if ($null -ne $Node.PSObject.Properties['minProperties']) {
            $minimum = [int] $Node.PSObject.Properties['minProperties'].Value
            if ($member.Count -lt $minimum) {
                Add-HDTJsonSchemaViolationRecord -Keyword 'minProperties' -Message (
                    "the object has {0} properties, and at least {1} are required" -f $member.Count, $minimum)
            }
        }

        if ($null -ne $Node.PSObject.Properties['propertyNames']) {
            $nameSchema = $Node.PSObject.Properties['propertyNames'].Value
            foreach ($item in $member) {
                foreach ($record in @(Get-HDTJsonSchemaNodeViolation -Instance $item.Name -Node $nameSchema -Root $Root `
                            -Location ('{0}/{1}' -f $Location, $item.Name))) {
                    [void] $violation.Add([pscustomobject] @{
                            Location = $record.Location
                            Keyword  = 'propertyNames'
                            Message  = ("the property NAME '{0}' is refused: {1}" -f $item.Name, $record.Message)
                        })
                }
            }
        }

        $declared = @()
        if ($null -ne $Node.PSObject.Properties['properties']) {
            $properties = $Node.PSObject.Properties['properties'].Value
            $declared = @($properties.PSObject.Properties | ForEach-Object { $_.Name })

            foreach ($item in $member) {
                # Matched with -ceq rather than through the PSObject indexer,
                # which is case insensitive: JSON member names are not, and a
                # document carrying 'Id' where the schema declares 'id' must
                # reach additionalProperties rather than this branch.
                $declaration = @($properties.PSObject.Properties | Where-Object { $_.Name -ceq $item.Name })
                if ($declaration.Count -eq 0) { continue }

                foreach ($record in @(Get-HDTJsonSchemaNodeViolation -Instance $item.Value `
                            -Node $declaration[0].Value -Root $Root `
                            -Location ('{0}/{1}' -f $Location, $item.Name))) {
                    [void] $violation.Add($record)
                }
            }
        }

        if ($null -ne $Node.PSObject.Properties['additionalProperties']) {
            $additional = $Node.PSObject.Properties['additionalProperties'].Value

            foreach ($item in $member) {
                if ($declared -ccontains $item.Name) { continue }

                if ($additional -is [bool]) {
                    if (-not $additional) {
                        Add-HDTJsonSchemaViolationRecord -Keyword 'additionalProperties' -Message (
                            "'{0}' is not one of the properties this object may carry ({1})" -f $item.Name, (($declared | Sort-Object) -join ', '))
                    }
                    continue
                }

                foreach ($record in @(Get-HDTJsonSchemaNodeViolation -Instance $item.Value -Node $additional -Root $Root `
                            -Location ('{0}/{1}' -f $Location, $item.Name))) {
                    [void] $violation.Add($record)
                }
            }
        }
    }

    # ---- oneOf and not ----------------------------------------------------
    if ($null -ne $Node.PSObject.Properties['oneOf']) {
        $branch = @($Node.PSObject.Properties['oneOf'].Value)

        $passed = 0
        foreach ($item in $branch) {
            if (@(Get-HDTJsonSchemaNodeViolation -Instance $Instance -Node $item -Root $Root -Location $Location).Count -eq 0) {
                $passed = $passed + 1
            }
        }

        if ($passed -ne 1) {
            # Zero and two are different defects and the message says which:
            # zero is a document the schema refuses, two is a schema whose
            # branches overlap.
            Add-HDTJsonSchemaViolationRecord -Keyword 'oneOf' -Message (
                "{0} of the {1} branches matched, and exactly one must" -f $passed, $branch.Count)
        }
    }

    if ($null -ne $Node.PSObject.Properties['not']) {
        if (@(Get-HDTJsonSchemaNodeViolation -Instance $Instance -Node $Node.PSObject.Properties['not'].Value -Root $Root -Location $Location).Count -eq 0) {
            Add-HDTJsonSchemaViolationRecord -Keyword 'not' -Message 'the value matches a schema it is required not to match'
        }
    }

    return @($violation)
}
