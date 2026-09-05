function Test-HDTUpdateExcluded {
    <#
        .SYNOPSIS
            Does any of the step's exclude patterns rule this update out, and
            which one?

        .DESCRIPTION
            DESIGN 10.1's exclude list is deliberately one array holding two
            kinds of thing:

                exclude: ["*Preview*", "KB5001234"]

            AN ENTRY IS A KB NUMBER IF IT LOOKS LIKE ONE, AND A TITLE WILDCARD
            OTHERWISE. That is the decision this function exists to make, and
            it is made here - tested - rather than inferred at the call site by
            whoever writes the next caller.

              KB5001234    a KB number
              kb5001234    a KB number
              5001234      a KB number
              *Preview*    a title pattern, matched with -like
              Malicious Software Removal Tool
                           a title pattern with no wildcard, so it matches that
                           exact title and nothing else

            WHY A BARE NUMBER IS NOT A TITLE SUBSTRING, WHICH IS THE READING
            THAT LOOKS EQUALLY REASONABLE AND IS DANGEROUS. Titles are full of
            numbers - build numbers, version numbers, years, the '11' in
            'Windows 11'. If '5001234' were matched against the title, an
            administrator excluding one article would silently exclude every
            update whose title happened to contain those digits, and the log
            would say the exclusion worked. Excluding too much is invisible;
            excluding too little is not. So a bare number is read the strict
            way, and somebody who genuinely means a title substring writes
            '*5001234*', which has a wildcard and is unambiguous.

            IT RETURNS WHICH PATTERN MATCHED, NOT JUST THAT ONE DID. "excluded"
            answers nothing an administrator can act on. "excluded by
            *Preview*" names the line of their own sequence.yaml to change,
            which is the difference between a log they can use and a log they
            have to ask about. The first matching pattern wins and is reported;
            there is no value in listing every pattern that would also have
            matched.

            AN EMPTY OR ABSENT LIST EXCLUDES NOTHING. That is the ordinary
            case - most sequences name no exclusions at all - so it is answered
            first and cheaply rather than treated as a special case.

        .PARAMETER Update
            One update row from IUpdateSessionService.SearchUpdate.

        .PARAMETER Exclude
            The step's exclude patterns. Absent, $null and @() all mean
            "exclude nothing".

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Excluded [bool]
            and Pattern [string] - the pattern that matched, or '' when none
            did.

        .EXAMPLE
            (Test-HDTUpdateExcluded -Update $update -Exclude @('*Preview*')).Pattern

            *Preview*, for a preview cumulative update.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Update,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Exclude
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $none = [pscustomobject] @{ Excluded = $false; Pattern = '' }

    if ($null -eq $Exclude -or @($Exclude).Count -eq 0) { return $none }

    $title = ''
    $titleProperty = $Update.PSObject.Properties['Title']
    if ($null -ne $titleProperty -and $null -ne $titleProperty.Value) {
        $title = [string] $titleProperty.Value
    }

    $kb = [string[]] @(Get-HDTUpdateKbNumber -Update $Update)

    foreach ($pattern in @($Exclude)) {
        $text = ([string] $pattern).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text -match '^(?:[Kk][Bb])?\s*(\d+)$') {
            $wanted = 'KB' + $Matches[1]

            foreach ($carried in $kb) {
                if ($carried -ieq $wanted) {
                    return [pscustomobject] @{ Excluded = $true; Pattern = $text }
                }
            }

            continue
        }

        # -like is case-insensitive, which is what an administrator writing
        # '*preview*' by hand expects.
        if ($title -like $text) {
            return [pscustomobject] @{ Excluded = $true; Pattern = $text }
        }
    }

    return $none
}
