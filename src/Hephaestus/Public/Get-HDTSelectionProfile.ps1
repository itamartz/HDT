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

    $all = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @(Get-HDTSelectionProfileBuiltIn)) {
        [void] $all.Add([pscustomobject] @{
                Id        = [string] $current.Id
                Name      = [string] $current.Name
                Include   = [string[]] @($current.Include)
                IsBuiltIn = $true
                Path      = ''
            })
    }

    if ($FileSystem.TestPath($documentPath)) {
        $text = $FileSystem.ReadAllText($documentPath)

        $document = ConvertFrom-HDTYaml -Yaml $text -Path $documentPath
        Assert-HDTSelectionProfileDocument -Document $document -Path $documentPath

        # The validator has already refused anything this loop could trip over -
        # a missing key, a duplicate id, an include that escapes the share - so
        # this is a projection and not a second set of rules.
        if (($null -ne $document) -and $document.Contains('profiles') -and ($null -ne $document['profiles'])) {
            foreach ($entry in @($document['profiles'])) {
                $include = @()
                if ($null -ne $entry['include']) { $include = @($entry['include']) }

                [void] $all.Add([pscustomobject] @{
                        Id        = [string] $entry['id']
                        Name      = [string] $entry['name']
                        Include   = [string[]] @($include | ForEach-Object { [string] $_ })
                        IsBuiltIn = $false
                        Path      = [string] $documentPath
                    })
            }
        }
    }

    # IN NAME ORDER, for the reason Get-HDTDriverGroup sorts: a list an
    # administrator scans for a name they half remember has to be somewhere
    # predictable, and the file system's order is not.
    $sorted = [pscustomobject[]] @($all | Sort-Object -Property Name)

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
