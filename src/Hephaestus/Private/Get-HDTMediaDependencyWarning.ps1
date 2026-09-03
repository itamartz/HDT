function Get-HDTMediaDependencyWarning {
    <#
        .SYNOPSIS
            The sentence naming both applications when a disc carries one whose
            dependency it does not.

        .DESCRIPTION
            OBSERVED FOR REAL ON 2026-09-03, AND IT COST A REBUILD: a hand-built
            disc carried TightVNC without the Acrobat package its app.yaml
            dependencies: names, and the deployment reached step 11 of 15 before
            refusing. MDT would copy the profile and let the machine find out on
            the bench. HDT says so while the ISO is being built, which is hours
            earlier and in front of the person who can fix it.

            IT WARNS AND IT DOES NOT FIX. DESIGN 6.2: the selection profile is
            the administrator's statement of intent. A build that quietly added
            an application nobody selected would produce a disc whose contents no
            document on the share describes, and the next person to read the
            profile would be reading a lie.

            THE CLOSURE IS Resolve-HDTApplicationOrder'S, NOT A SECOND ONE.
            That command already computes the transitive closure of a selection,
            deterministically, and already refuses a cycle naming every member.
            Anything in the plan it returns that the projection does NOT carry is
            a missing dependency.

            IT FAILS SOFT, AND THAT IS THE ONE PLACE IT DIFFERS FROM ITS CALLER.
            Resolve-HDTApplicationOrder throws for a cycle and for a dependency
            that is not in the catalog, correctly - it is the install planner and
            a plan it cannot order is a deployment that must not start. Here both
            become a sentence, because a build that refuses to make a disc over an
            authoring problem in an application nobody selected is a build that
            helps nobody. The disc still gets made; the administrator still gets
            told.

        .PARAMETER Application
            The catalog, as Get-HDTApplication returns it.

        .PARAMETER CarriedId
            The application ids the projection actually carries onto the disc.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - one sentence per missing dependency, naming the
            application that is on the disc and the one that is not. Nothing at
            all when the disc is complete.

        .EXAMPLE
            Get-HDTMediaDependencyWarning -Application $catalog -CarriedId @('TightVNC')

            "TightVNC is on this disc and 'Acrobat', which it depends on, is not."

        .LINK
            Resolve-HDTApplicationOrder
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Application,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $CarriedId
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $carried = [string[]] @($CarriedId | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })

    if (@($carried).Count -eq 0) { return [string[]] @() }

    $sentence = New-Object -TypeName System.Collections.ArrayList

    $plan = $null

    try {
        $plan = @(Resolve-HDTApplicationOrder -Application ([object[]] @($Application)) -Id $carried)
    } catch {
        # A CYCLE, OR A DEPENDENCY NAMING SOMETHING THE CATALOG HAS NOT GOT.
        # Resolve- names both in its message, so the message IS the sentence -
        # rewording it here would lose the ids it took a graph walk to find.
        [void] $sentence.Add(('the applications on this disc could not be ordered, so their dependencies were not checked: {0}' -f
                [string] $_.Exception.Message))

        return [string[]] @($sentence)
    }

    # WHO NEEDS WHAT, so the sentence can name the application that is ON the
    # disc rather than only the one that is missing. The missing id alone reads
    # as an unexplained absence; the pair reads as a decision to correct.
    $requiredBy = @{}

    foreach ($entry in @($Application)) {
        if ($null -eq $entry) { continue }

        $id = [string] $entry.Id

        foreach ($dependency in @($entry.Dependencies)) {
            $name = [string] $dependency
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            if (-not $requiredBy.ContainsKey($name)) { $requiredBy[$name] = New-Object -TypeName System.Collections.ArrayList }
            [void] $requiredBy[$name].Add($id)
        }
    }

    # A DEPENDENCY SHARED BY TWO CARRIED APPLICATIONS IS REPORTED ONCE, because
    # the plan holds each application once and this walks the plan.
    foreach ($entry in @($plan)) {
        $id = [string] $entry.Id

        if ($carried -contains $id) { continue }

        $requester = @()
        if ($requiredBy.ContainsKey($id)) {
            $requester = @($requiredBy[$id] | Where-Object { $carried -contains [string] $_ } | Sort-Object -Unique)
        }

        # A dependency two deep is needed by something that is itself missing,
        # so no carried application names it directly. Say so rather than
        # dropping the row: it still has to be on the disc.
        if (@($requester).Count -eq 0) {
            [void] $sentence.Add(("'{0}' is not on this disc and something on it needs it, through the dependency chain {1}. Add it to the selection profile, or remove the dependency." -f
                    $id, (@($carried) -join ', ')))

            continue
        }

        [void] $sentence.Add(("{0} is on this disc and '{1}', which it depends on, is not. Add '{1}' to the selection profile, or remove the dependency from its app.yaml." -f
                (@($requester) -join ' and '), $id))
    }

    return [string[]] @($sentence)
}
