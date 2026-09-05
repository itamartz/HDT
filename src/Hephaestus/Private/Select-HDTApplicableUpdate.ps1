function Select-HDTApplicableUpdate {
    <#
        .SYNOPSIS
            Decides, with a reason, which of a search's results the step should
            install.

        .DESCRIPTION
            IUpdateSessionService.SearchUpdate is flat and unfiltered on
            purpose (08-01-02): the adapter cannot be unit tested, so nothing
            that is a decision is allowed to live in it. This is that decision,
            as pure logic - values in, values out, no service, no context and
            no log.

            IT NEVER SILENTLY DROPS ANYTHING. One row per input update, in the
            order the search returned them, each carrying why it was kept or
            dropped:

              Update       the row as the agent reported it
              Applicable   [bool]
              Reason       'no category filter'
                           'category SecurityUpdates'
                           'excluded by *Preview*'
                           'no category matched'

            That is not decoration. The question an administrator asks a
            deployment log a week later is "why did this machine not get that
            patch", and a step that logged "0 updates applicable" answers none
            of it - the patch could have been excluded by their own pattern, be
            in a category they did not name, or genuinely not apply to the
            machine, and those are three different problems with three
            different fixes.

            EXCLUSION IS DECIDED BEFORE CATEGORY, because an exclusion is an
            administrator's explicit instruction about a named update and a
            category is a broad scope. An update that is both excluded and out
            of scope is reported as excluded: that is the more specific fact
            and the one that names something in their own sequence.yaml.

            A CATEGORY IS MATCHED WITH THE SPACES REMOVED. WUA reports
            'Security Updates'; DESIGN 10.1's YAML writes 'SecurityUpdates';
            MDT's own documentation writes both, in the same table. Neither
            spelling is wrong and a step that accepted only one would fail in
            the way that looks like the update simply did not exist. The
            comparison renders both sides through
            ConvertTo-HDTComparableString - the engine's one loose rendering,
            invariant-culture and boolean-aware - and then strips whitespace
            and hyphens, which is the only normalisation this comparison needs
            on top of it.

            THE REASON NAMES THE CATEGORY THE AUTHOR WROTE, not the one the
            agent reported. An administrator reading 'category SecurityUpdates'
            can find that string in their sequence; 'category Security Updates'
            sends them looking for a line they never wrote.

        .PARAMETER Update
            The rows SearchUpdate returned. An empty set is legal and produces
            no rows.

        .PARAMETER Category
            The step's categories. Absent means every category is in scope.

        .PARAMETER Exclude
            The step's exclude patterns, read by Test-HDTUpdateExcluded.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - one per input
            update: Update, Applicable, Reason.

        .EXAMPLE
            $decided = Select-HDTApplicableUpdate -Update $found -Category @('SecurityUpdates') -Exclude @('*Preview*')
            @($decided | Where-Object { -not $_.Applicable } | ForEach-Object { $_.Reason })

            Why each update the search returned is not going to be installed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Update,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Category,

        [Parameter(Position = 2)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Exclude
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $decided = New-Object -TypeName System.Collections.ArrayList

    if ($null -eq $Update) { return [pscustomobject[]] @() }

    # The author's spellings, kept alongside their normalised forms, so the
    # reason can quote what they wrote while the comparison ignores how it was
    # spaced.
    $wanted = New-Object -TypeName System.Collections.ArrayList
    foreach ($name in @($Category)) {
        $text = ([string] $name).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        [void] $wanted.Add([pscustomobject] @{
                Written    = $text
                Normalised = ((ConvertTo-HDTComparableString -Value $text) -replace '[\s\-]', '')
            })
    }

    foreach ($current in @($Update)) {
        if ($null -eq $current) { continue }

        $exclusion = Test-HDTUpdateExcluded -Update $current -Exclude $Exclude

        if ($exclusion.Excluded) {
            [void] $decided.Add([pscustomobject] @{
                    Update     = $current
                    Applicable = $false
                    Reason     = 'excluded by {0}' -f $exclusion.Pattern
                })

            continue
        }

        if ($wanted.Count -eq 0) {
            [void] $decided.Add([pscustomobject] @{
                    Update     = $current
                    Applicable = $true
                    Reason     = 'no category filter'
                })

            continue
        }

        $carried = @()
        $categoryProperty = $current.PSObject.Properties['Category']
        if ($null -ne $categoryProperty -and $null -ne $categoryProperty.Value) {
            $carried = @($categoryProperty.Value)
        }

        $matched = $null
        foreach ($name in $carried) {
            $normalised = (ConvertTo-HDTComparableString -Value ([string] $name)) -replace '[\s\-]', ''

            foreach ($candidate in $wanted) {
                if ($normalised -ieq $candidate.Normalised) {
                    $matched = $candidate.Written
                    break
                }
            }

            if ($null -ne $matched) { break }
        }

        if ($null -ne $matched) {
            [void] $decided.Add([pscustomobject] @{
                    Update     = $current
                    Applicable = $true
                    Reason     = 'category {0}' -f $matched
                })

            continue
        }

        # NOT A FAILURE, AND NOT SILENCE EITHER. An update outside the step's
        # categories is simply out of scope, and the row saying so is what
        # tells an administrator their categories list is the reason rather
        # than the update being unavailable.
        [void] $decided.Add([pscustomobject] @{
                Update     = $current
                Applicable = $false
                Reason     = 'no category matched'
            })
    }

    return [pscustomobject[]] @($decided)
}
