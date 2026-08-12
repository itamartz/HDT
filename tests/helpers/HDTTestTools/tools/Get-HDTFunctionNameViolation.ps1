function Get-HDTFunctionNameViolation {
    <#
        .SYNOPSIS
            Returns one object per function name that breaks the DESIGN 15.1 naming
            rule.

        .DESCRIPTION
            Every PowerShell command in HDT is named Verb-HDTNoun with an uppercase
            HDT prefix and an approved verb - public cmdlets, private helpers,
            adapters, test helpers and build functions alike.

            The enforced pattern is:

                ^([A-Z][a-zA-Z]*)-HDT[A-Z][A-Za-z0-9]*$   matched case-sensitively

            The verb segment allows interior capitals because approved two-word verbs
            (ConvertTo, ConvertFrom, WaitFor) contain one, and DESIGN 15.1 blesses
            ConvertTo-HDTReport by name. The real constraint on the verb is not the
            character class but membership of Get-Verb, checked with exact case.

            Valid names produce no output, so an empty result means "everything is
            fine". Input order is preserved to keep failure messages readable.

        .PARAMETER Name
            One or more function names to validate.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Name and Reason.

        .EXAMPLE
            Get-HDTFunctionNameViolation -Name 'Get-HDTWorkspace', 'Get-Thing'

            Returns a single violation for Get-Thing.

        .EXAMPLE
            Get-HDTSourceFunction -Path ./build.ps1 | ForEach-Object { $_.Name } | Get-HDTFunctionNameViolation

            Validates every function build.ps1 defines.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]] $Name
    )

    begin {
        $pattern = '^([A-Z][a-zA-Z]*)-HDT[A-Z][A-Za-z0-9]*$'

        # Resolved once per invocation rather than once per name: Get-Verb is not
        # free, and the naming contract calls this with every function in the repo.
        $approvedVerb = @(Get-Verb | ForEach-Object { $_.Verb })

        $violation = New-Object -TypeName System.Collections.ArrayList
    }

    process {
        if ($null -eq $Name) {
            return
        }

        foreach ($item in $Name) {
            $candidate = $item
            if ($null -eq $candidate) {
                $candidate = ''
            }

            if ([string]::IsNullOrWhiteSpace($candidate)) {
                [void] $violation.Add([pscustomobject] @{
                        Name   = $candidate
                        Reason = 'is empty; every function must be named Verb-HDTNoun (DESIGN 15.1)'
                    })
                continue
            }

            if ($candidate -cmatch $pattern) {
                $verb = $Matches[1]
                if ($approvedVerb -ccontains $verb) {
                    continue
                }

                [void] $violation.Add([pscustomobject] @{
                        Name   = $candidate
                        Reason = ("'{0}' is not an approved verb (Get-Verb)" -f $verb)
                    })
                continue
            }

            [void] $violation.Add([pscustomobject] @{
                    Name   = $candidate
                    Reason = 'does not match ^Verb-HDTNoun (uppercase HDT required, approved verb, noun starting with a capital)'
                })
        }
    }

    end {
        return $violation.ToArray()
    }
}
