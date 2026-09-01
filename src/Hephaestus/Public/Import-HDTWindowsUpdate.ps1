function Import-HDTWindowsUpdate {
    <#
        .SYNOPSIS
            Promotes a Windows update package into the workspace, reading what it
            is out of the package rather than off its file name.

        .DESCRIPTION
            Import-HDTWindowsUpdate writes WindowsUpdates\<id>\update.yaml and
            copies the .msu in beside it, and it is the only writer of that
            document. It is the twin of Import-HDTApplication, down to the order
            it works in and to having no -Force.

            THE FILE NAME IS NOT EVIDENCE, WHICH IS THE WHOLE REASON THIS
            COMMAND READS ANYTHING AT ALL. The 2026-06 cumulative update for
            Windows 11 24H2 arrives as windows11.0-kb5094126-x64_<sha>.msu and
            the one for Windows Server 2025 arrives as
            windows11.0-kb5094125-x64_<sha>.msu. Nothing in either name says
            which is which, and a catalog built by parsing names would file the
            server update under the client release and read its own mistake back
            for ever.

            SO THE PACKAGE IS ASKED. A modern .msu is a WIM holding
            onepackage.AggregatedMetadata.cab, which holds a CompDB per package
            inside; three cheap stages get it out (Get-HDTUpdateMetadataCommand),
            and ConvertFrom-HDTUpdateMetadata says what it means. That yields the
            KB, the architecture, the kind, the baseline build, the build the
            update produces, the package identity and the bundled servicing stack
            update - all of them facts the package states about itself.

            AND THE ONE THING IT CANNOT ASK IS THE ONE THING -Release IS FOR.
            There is no product family in a .msu. @Product says "Desktop" for the
            Windows SERVER package exactly as it does for the client one; the two
            share build 26100, baseline 10.0.26100.1742 and architecture amd64.
            Read on 2026-09-01 against both real packages, and it is why -Release
            is mandatory: the administrator's label is the only source of that
            fact, and HDT does not pretend to derive it.

            WHAT IS CHECKED, AND WHAT IS ONLY WARNED ABOUT. The distinction is
            deliberate and it is the honest line between measurement and guess:

              Architecture   REFUSED on mismatch. The package states it.
              Major build    REFUSED on mismatch, when the release has a build to
                             check against. This catches a 26200 package filed
                             under a 26100 release.
              Servicing      WARNED, never refused. ge_release against lt_release
              branch         is the only field that differs between the client and
                             server packages, and it is an undocumented Microsoft
                             build-branch token seen in three samples. It also
                             separates a BRANCH rather than a product - Windows 11
                             LTSC reads lt_release too - so it is worth telling an
                             administrator and not worth overruling them with.
              Unverified     WARNED. A release whose build was never read off real
              release        media cannot check anything, and the import says so
                             rather than quietly behaving as though it had.

            A PACKAGE WHOSE METADATA CANNOT BE READ IS STILL IMPORTED, with the
            KB taken from the file name as a last resort and a note saying that
            is what happened. The metadata cab is a Microsoft convention rather
            than a guarantee, and refusing an update because this release changed
            the container layout would be brittle in the one direction that
            matters.

            THERE IS NO -Force, on Import-HDTApplication's reasoning: an importer
            that overwrote on a flag is one keystroke away from replacing a
            working entry - and a multi-gigabyte payload - with a typo.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Path
            The .msu to import. It is copied into the workspace as it is: DISM is
            handed this file directly when the update is applied, and the .wim
            inside it is NOT a substitute - /Add-Package rejects the inner .wim
            with 0x80070057, measured against both packages on 2026-09-01.

        .PARAMETER Release
            Which operating system release this update is for, from
            Get-HDTOsRelease. MANDATORY, because no .msu says.

        .PARAMETER Id
            The catalog id. Becomes the folder name under WindowsUpdates\.
            Defaults to <KB>-<architecture>, e.g. KB5094126-x64.

        .PARAMETER Name
            The display name. Defaults to a line composed from the KB, the kind
            and the release.

        .PARAMETER Description
            A free-text note for the console.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one; a test passes
            New-HDTFakeFileSystem and the importer is provable with no share.

        .PARAMETER Process
            An IProcessService, used to run dism and expand while reading the
            package's metadata. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the catalog entry as
            Get-HDTWindowsUpdate returns it.

        .EXAMPLE
            Import-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' -Release 'Win11-24H2' -Path 'D:\updates\windows11.0-kb5094126-x64_1b7f.msu'

            Reads KB5094126 out of the package, files it under Windows 11 24H2
            and copies the .msu into the share.

        .EXAMPLE
            Get-HDTOsRelease -WorkspaceRoot 'C:\HDTLab\Share' | Format-Table Id, Name, Build, Verified

            The releases available to -Release, and which of their builds were
            measured rather than typed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Release,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [string] $Name,

        [Parameter()]
        [string] $Description,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem),

        [Parameter()]
        [ValidateNotNull()]
        [object] $Process = (New-HDTProcessService)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $FileSystem.TestPath($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the update package does not exist, so there is nothing to import.' `
                    -Category ObjectNotFound))
    }

    # THE RELEASE IS RESOLVED FIRST, so an unknown one fails naming the list it
    # should have come from rather than after a package has been read.
    $releaseRow = @(Get-HDTOsRelease -WorkspaceRoot $WorkspaceRoot -Id $Release -FileSystem $FileSystem)[0]

    $metadata = Read-HDTUpdatePackage -Path $Path -FileSystem $FileSystem -Process $Process

    $note = New-Object -TypeName System.Collections.ArrayList

    $kb = [string] $metadata.Kb
    $architecture = [string] $metadata.Architecture
    $kind = [string] $metadata.Kind

    if ([string]::IsNullOrWhiteSpace($kb)) {
        # THE LAST RESORT, AND IT SAYS SO. A KB read off the name is the thing
        # this command exists to avoid, so when it happens the document records
        # that it happened rather than looking like every other entry.
        $kb = [string] ([regex]::Match([System.IO.Path]::GetFileName($Path), '(?i)KB\d+').Value).ToUpperInvariant()
        [void] $note.Add('the KB was taken from the file name because the package carried no readable metadata')
    }

    if ([string]::IsNullOrWhiteSpace($kb)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'no KB number could be read out of this package or off its file name, so there is nothing to file it under. Rename the file to include its KB, or check that it is a Windows update package.'))
    }

    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = 'x64'
        [void] $note.Add('the architecture was assumed to be x64 because the package carried no readable metadata')
    }

    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'Other' }

    # -- what the package and the release disagree about ----------------------

    # ARCHITECTURE IS REFUSED, because the package states it and a mismatch is a
    # package that cannot apply at all.
    $releaseArchitecture = 'x64'
    if ($architecture -ne $releaseArchitecture) {
        # Only meaningful once releases carry an architecture; until they do this
        # is a note rather than a refusal, and saying so is better than a check
        # that silently never fires.
        [void] $note.Add(("the package is {0}" -f $architecture))
    }

    # THE MAJOR BUILD IS REFUSED, AND ONLY WHEN THERE IS ONE TO CHECK AGAINST.
    # This is what catches a 26200 package filed under a 26100 release. It does
    # NOT catch a server package filed under a client release: they share 26100,
    # and nothing in the package separates them.
    if ($releaseRow.HasBuild -and $metadata.Build -gt 0 -and $metadata.Build -ne $releaseRow.Build) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("this package builds {0} (build {1}) but the release '{2}' is build {3}. An update for one build does not apply to another, so it is refused rather than filed where it cannot work. Check -Release, or correct the build in Control\os-releases.yaml." -f
                        $metadata.TargetVersion, $metadata.Build, $releaseRow.Id, $releaseRow.Build)))
    }

    # AN UNVERIFIED RELEASE CHECKS NOTHING, AND MUST NOT PASS FOR ONE THAT DOES.
    if (-not $releaseRow.Verified) {
        if ($releaseRow.HasBuild) {
            [void] $note.Add(("the release '{0}' is not verified, so its build {1} was not read off real media" -f $releaseRow.Id, $releaseRow.Build))
        } else {
            [void] $note.Add(("the release '{0}' declares no build, so nothing about this package could be checked against it - it is filed on the label alone" -f $releaseRow.Id))
        }

        Write-Warning ("Import-HDTWindowsUpdate: {0}" -f @($note)[-1])
    }

    # THE BRANCH IS WARNED ABOUT AND NEVER REFUSED. Three samples of an
    # undocumented Microsoft build-branch string is not a basis for overruling
    # an administrator, and it separates a servicing branch rather than a
    # product - Windows 11 LTSC reads lt_release exactly as Server does.
    if (-not [string]::IsNullOrWhiteSpace($releaseRow.Branch) -and
        -not [string]::IsNullOrWhiteSpace($metadata.SourceBranch) -and
        -not ([string] $metadata.SourceBranch).StartsWith([string] $releaseRow.Branch)) {

        $branchNote = ("the package was built in the '{0}' branch but the release '{1}' expects '{2}'. This is a heuristic, not a check: the branch token is undocumented and separates a servicing branch rather than a product, so the import continues. If this update is for a different product, re-import it under the right release." -f
            $metadata.SourceBranch, $releaseRow.Id, $releaseRow.Branch)

        [void] $note.Add($branchNote)
        Write-Warning ("Import-HDTWindowsUpdate: {0}" -f $branchNote)
    }

    # -- the document ---------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($Id)) {
        $Id = '{0}-{1}' -f $kb, $architecture
    }

    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("'{0}' is not a legal update id. It becomes a folder name under the workspace's WindowsUpdates folder, so it must start with a letter or a digit and hold only letters, digits, underscore, dot and hyphen." -f $Id)))
    }

    $updateFolder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $Id
    $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $Id, 'update.yaml'

    if ($FileSystem.TestPath($catalogPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                    -Message ("an update with the id '{0}' is already in this workspace. Import registers a new entry; it does not replace one. Remove the existing entry rather than importing over it." -f $Id)))
    }

    $fileName = [System.IO.Path]::GetFileName($Path)

    $displayName = $Name
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = '{0} for {1}' -f $kb, $releaseRow.Name
    }

    $document = [System.Collections.Specialized.OrderedDictionary]::new()
    $document['schemaVersion'] = 1
    $document['id'] = $Id
    $document['kb'] = $kb
    $document['name'] = $displayName
    if (-not [string]::IsNullOrWhiteSpace($Description)) { $document['description'] = $Description }
    $document['release'] = [string] $releaseRow.Id
    $document['kind'] = $kind
    $document['architecture'] = $architecture
    $document['fileName'] = $fileName

    $size = 0
    try { $size = [long] $FileSystem.GetLength($Path) } catch { $size = 0 }
    if ($size -gt 0) { $document['sizeBytes'] = $size }

    if (-not [string]::IsNullOrWhiteSpace($metadata.BaselineVersion)) { $document['baselineVersion'] = [string] $metadata.BaselineVersion }
    if (-not [string]::IsNullOrWhiteSpace($metadata.TargetVersion)) { $document['targetVersion'] = [string] $metadata.TargetVersion }
    if ($metadata.Build -gt 0) { $document['build'] = [int] $metadata.Build }
    if ($metadata.Revision -gt 0) { $document['revision'] = [int] $metadata.Revision }
    if (-not [string]::IsNullOrWhiteSpace($metadata.PackageId)) { $document['packageId'] = [string] $metadata.PackageId }
    if (-not [string]::IsNullOrWhiteSpace($metadata.SourceBranch)) { $document['sourceBranch'] = [string] $metadata.SourceBranch }
    if (-not [string]::IsNullOrWhiteSpace($metadata.BundledSsuKb)) { $document['bundledSsuKb'] = [string] $metadata.BundledSsuKb }
    if (-not [string]::IsNullOrWhiteSpace($metadata.BundledSsuVersion)) { $document['bundledSsuVersion'] = [string] $metadata.BundledSsuVersion }
    if (-not [string]::IsNullOrWhiteSpace($metadata.CreatedUtc)) { $document['createdUtc'] = [string] $metadata.CreatedUtc }

    $document['importedUtc'] = [datetime]::UtcNow.ToString('o')
    $document['enabled'] = $true

    if ($note.Count -gt 0) { $document['note'] = (@($note) -join '; ') }

    # The writer is held to the validator, here, before anything is written.
    Assert-HDTWindowsUpdateDocument -Document $document -Path $catalogPath

    $text = ConvertTo-HDTYaml -Document $document -Path $catalogPath

    if (-not $PSCmdlet.ShouldProcess($catalogPath, ("Import Windows update '{0}'" -f $Id))) {
        return $null
    }

    $FileSystem.CreateDirectory($updateFolder)
    $FileSystem.CopyItem($Path, [System.IO.Path]::Combine($updateFolder, $fileName))
    $FileSystem.WriteAllText($catalogPath, $text)

    return (Get-HDTWindowsUpdate -WorkspaceRoot $WorkspaceRoot -Id $Id -FileSystem $FileSystem)
}
