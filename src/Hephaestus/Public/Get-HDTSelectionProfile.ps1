function Get-HDTSelectionProfile {
    <#
        .SYNOPSIS
            The selection profiles a deployment share has - the named sets of
            folders a boot image, a driver step and standalone media point at.

        .DESCRIPTION
            THIS IS MDT'S SELECTION PROFILE, KEPT. A driver group was one folder,
            and one folder cannot describe a mixed floor: a share carrying a Dell
            WinPE pack and an HP WinPE pack needs ONE boot image that sees both,
            and 'drivers: <folder>' has no way to say so. MDT answered that with a
            named set of include paths saved once in Control\SelectionProfiles.xml
            and reused everywhere; this is the same idea in the format the rest of
            HDT is authored in, at Control\selection-profiles.yaml.

            IT SPANS THE SHARE, NOT JUST Drivers\, and that is not scope creep.
            DESIGN 13 calls standalone media a content PROJECTION of the share
            rather than a second code path, and a selection profile is exactly
            that projection's filter. One document, three consumers: the boot
            image, the sequence's driver step, and media.

            THE BUILT-INS NEED NO DOCUMENT. All drivers, Everything and Nothing
            are answered from Get-HDTSelectionProfileBuiltIn, so a share nobody
            has authored a profile on still gives the Windows PE window's picker
            something legal, and a hand-made share still builds a boot image.
            Their ids are reserved; the validator refuses an authored profile
            that would shadow one.

            A SHARE WITH NO DOCUMENT ANSWERS WITH THE BUILT-INS rather than
            throwing. A document that IS there and is wrong is a different thing
            entirely, and that fails naming the file - the same split
            Get-HDTApplication draws between a folder with no app.yaml and an
            app.yaml that is broken.

            IT READS THROUGH AN INJECTED IFileSystem - never Get-Content - so the
            whole authoring path is provable under Pester with no share and no
            disk.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Id
            One profile, by id. Omit it for every profile the share has.

        .PARAMETER FileSystem
            The IFileSystem to read with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per profile, in name
            order, with Id, Name, Include, IsBuiltIn and Path.

            Path is the document a profile was read from, and an empty string for
            a built-in - which is what tells the console's editor that Rename and
            Delete do not apply to it.

        .EXAMPLE
            Get-HDTSelectionProfile -Root 'C:\HDTLab\Share'

            Every profile, built in or authored, in the order the picker shows
            them.

        .EXAMPLE
            (Get-HDTSelectionProfile -Root 'C:\HDTLab\Share' -Id 'boot-critical').Include

            The two vendor WinPE packs that one boot image injects.

        .LINK
            Expand-HDTSelectionProfile

        .LINK
            Set-HDTBootImageDriver
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $documentPath = Get-HDTWorkspacePath -Root $Root -Kind Control -ChildPath 'selection-profiles.yaml'

    # ONE PARSER, SHARED WITH THE CONSOLE'S EDITOR. This reads a share and hands
    # the lines over; the profile window holds lines it is splicing and hands
    # those over instead. Two projections would be two answers to "what does this
    # document say", and the one that mattered would be whichever ran last.
    $line = [string[]] @()

    if ($FileSystem.TestPath($documentPath)) {
        $line = [string[]] @(($FileSystem.ReadAllText($documentPath)) -split "`r?`n")
    }

    $sorted = [pscustomobject[]] @(Get-HDTSelectionProfileFromLine -Line $line -Path $documentPath)

    if (-not $PSBoundParameters.ContainsKey('Id')) { return $sorted }

    $match = @($sorted | Where-Object { $_.Id -eq $Id })

    if (@($match).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $documentPath `
                    -Message ("no selection profile with the id '{0}' is on this share. The ids it has are {1}." -f
                        $Id, (@($sorted | ForEach-Object { $_.Id }) -join ', ')) `
                    -Category ObjectNotFound))
    }

    return [pscustomobject[]] @($match)
}
