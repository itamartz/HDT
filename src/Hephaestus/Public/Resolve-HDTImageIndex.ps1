function Resolve-HDTImageIndex {
    <#
        .SYNOPSIS
            Chooses the one image to apply, or refuses to choose.

        .DESCRIPTION
            DESIGN 9.2: "Index selectable by number, name, or edition." This is
            that selection, and its refusal: TWO IMAGES MATCHING ONE REQUEST IS A
            REFUSAL, NOT A COIN TOSS. It is the same rule DESIGN 9.1 makes about
            disks, applied to what gets applied to them - and it matters on real
            media, where the staged Server 2025 WIM carries two images whose
            names differ only by "(Desktop Experience)" and two more that share
            the edition id ServerStandard.

            EACH CRITERION IS MATCHED INDEPENDENTLY AND THE RESULTS ARE
            INTERSECTED. That is what makes -Index 2 -Edition ServerStandard
            work: the edition alone is ambiguous, the pair is not. A
            filter-in-sequence implementation would have had to decide which
            criterion narrows first, and would refuse a request that is perfectly
            unambiguous.

            EXACT BEFORE WILDCARD, for -Name. 'Windows Server 2025 Standard' is
            index 1 exactly AND is contained in index 2's name. A
            containment-first implementation refuses a request an administrator
            meant unambiguously. A -Name carrying * or ? is taken as a wildcard
            as written; one without is tried exactly first and as a containment
            match second.

            With nothing asked for: a single-image file resolves to that image, a
            declared -DefaultIndex is used next, and anything else is an
            HDTAmbiguousImageError listing every index and name - which is what an
            administrator needs to see to write the request that would have
            worked.

            HDTAmbiguousImageError is classified Configuration by
            Get-HDTFailureClass, so a refusal ends the run rather than being
            retried three times.

        .PARAMETER Image
            The image rows, as IImageService.GetImageInfo returns them or as
            Get-HDTOperatingSystem reads them back from os.yaml.

        .PARAMETER Index
            The index to apply. Must exist.

        .PARAMETER Name
            The image name, matched case-insensitively: exactly first, then as a
            wildcard.

        .PARAMETER Edition
            The edition id - EnterpriseS, ServerStandard - matched
            case-insensitively and exactly.

        .PARAMETER DefaultIndex
            The index to use when nothing was asked for. Must exist.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the single image row.

        .EXAMPLE
            Resolve-HDTImageIndex -Image $catalog.Images -Edition EnterpriseS

            The Windows 11 Enterprise LTSC index, without depending on the
            marketing name staying the same across media revisions.

        .EXAMPLE
            Resolve-HDTImageIndex -Image $catalog.Images -Name 'Windows Server 2025 Standard (Desktop Experience)'

            The index the Server 2025 media puts at 2, named rather than numbered.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Image,

        [Parameter()]
        [int] $Index,

        [Parameter()]
        [string] $Name,

        [Parameter()]
        [string] $Edition,

        [Parameter()]
        [int] $DefaultIndex
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $row = @($Image)

    if ($row.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                    -Message 'the image file declares no image, so there is no index to apply.'))
    }

    $presentIndex = @($row | ForEach-Object { [int] $_.Index })
    $requested = New-Object -TypeName System.Collections.ArrayList

    # -- each criterion, matched independently --------------------------------

    $candidate = $row

    if ($PSBoundParameters.ContainsKey('Index')) {
        [void] $requested.Add(('index {0}' -f $Index))

        $match = @($row | Where-Object { [int] $_.Index -eq $Index })

        if ($match.Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Index `
                        -Message ("index {0} names no image in this image file. The indices it carries are {1}." -f $Index, ($presentIndex -join ', '))))
        }

        $candidate = @($candidate | Where-Object { [int] $_.Index -eq $Index })
    }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        [void] $requested.Add(("name '{0}'" -f $Name))

        # Exact first. The LTSC / LTSC-N and Standard / Standard (Desktop
        # Experience) pairs on the real staged media are exactly this case.
        $match = @($row | Where-Object { ([string] $_.Name) -eq $Name })

        if ($match.Count -eq 0) {
            $pattern = $Name
            if ($Name -notmatch '[\*\?]') { $pattern = '*{0}*' -f $Name }

            $match = @($row | Where-Object { ([string] $_.Name) -like $pattern })
        }

        if ($match.Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name `
                        -Message ("no image in this image file is named '{0}'. The images it carries are: {1}." -f $Name, (@($row | ForEach-Object { '{0} = {1}' -f $_.Index, $_.Name }) -join '; '))))
        }

        $matchIndex = @($match | ForEach-Object { [int] $_.Index })
        $candidate = @($candidate | Where-Object { $matchIndex -contains [int] $_.Index })
    }

    if (-not [string]::IsNullOrWhiteSpace($Edition)) {
        [void] $requested.Add(("edition '{0}'" -f $Edition))

        $match = @($row | Where-Object { ([string] $_.Edition) -eq $Edition })

        if ($match.Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Edition `
                        -Message ("no image in this image file carries the edition '{0}'. The editions it carries are {1}." -f $Edition, (@($row | ForEach-Object { [string] $_.Edition } | Sort-Object -Unique) -join ', '))))
        }

        $matchIndex = @($match | ForEach-Object { [int] $_.Index })
        $candidate = @($candidate | Where-Object { $matchIndex -contains [int] $_.Index })
    }

    # -- nothing was asked for ------------------------------------------------

    if ($requested.Count -eq 0) {
        if ($row.Count -eq 1) {
            return $row[0]
        }

        if ($PSBoundParameters.ContainsKey('DefaultIndex')) {
            $match = @($row | Where-Object { [int] $_.Index -eq $DefaultIndex })

            if ($match.Count -eq 1) {
                return $match[0]
            }

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $DefaultIndex `
                        -Message ("the default index {0} names no image in this image file. The indices it carries are {1}." -f $DefaultIndex, ($presentIndex -join ', '))))
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTAmbiguousImageError' `
                    -TargetObject ([int[]] $presentIndex) -Category InvalidResult `
                    -Message ("this image file carries {0} images and the step named none of them, so HDT will not guess which to apply. The images are: {1}. Set index:, name: or edition: on the step." -f
                        $row.Count, (@($row | ForEach-Object { '{0} = {1}' -f $_.Index, $_.Name }) -join '; '))))
    }

    # -- the intersection -----------------------------------------------------

    if ($candidate.Count -eq 1) {
        return $candidate[0]
    }

    if ($candidate.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject (@($requested) -join ' and ') `
                    -Message ("no image in this image file matches {0} together. The images it carries are: {1}." -f
                        (@($requested) -join ' and '), (@($row | ForEach-Object { '{0} = {1}' -f $_.Index, $_.Name }) -join '; '))))
    }

    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTAmbiguousImageError' `
                -TargetObject ([int[]] @($candidate | ForEach-Object { [int] $_.Index })) -Category InvalidResult `
                -Message ("{0} images match {1}, and HDT will not guess which to apply: {2}. Name an index, or a name that matches one image." -f
                    $candidate.Count, (@($requested) -join ' and '), (@($candidate | ForEach-Object { '{0} = {1}' -f $_.Index, $_.Name }) -join '; '))))
}
