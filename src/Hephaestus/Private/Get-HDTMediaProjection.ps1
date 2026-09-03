function Get-HDTMediaProjection {
    <#
        .SYNOPSIS
            What travels onto a standalone disc and what is refused, as a list of
            rows. It copies nothing.

        .DESCRIPTION
            THE CORRECTNESS HEART OF MEDIA GENERATION, AND IT IS PURE. DESIGN 6.2:
            "media generation is a content projection plus a provider swap". This
            is the projection half, stated as one row per thing that travels and
            one per thing refused, so the question a wrong disc costs an hour of
            rebuild to answer is answerable in milliseconds against a fake.

            THE SELECTION PROFILE IS THE PROJECTION, AND THERE IS NO SECOND
            ENGINE. Expand-HDTSelectionProfile already answers "what
            Update-HDTBootImage will hand Add-WindowsDriver, and what media will
            copy" - its own header says so - so this calls it rather than walking
            the share. A second walker would be a second place for the answer to
            differ from the boot image's, and the two would disagree the first
            time somebody renamed a folder.

            IT DOES NOT RECURSE, because Expand-HDTSelectionProfile does not: an
            include means "this folder and everything under it", and the
            recursion belongs to the consumer, which does it with
            Copy-HDTContentTree. A missing folder comes back Present = $false
            rather than as nothing, because dropping it silently is how a disc
            ships without one vendor's drivers.

            THE WORKSPACE'S OWN DOCUMENTS ARE NOT CONTENT AND TRAVEL REGARDLESS,
            in this order, which is also the order the build log reads in:

              1  rules.yaml       THE CONTENT MARKER. Resolve-HDTDeployRoot hunts
                                  every ready volume for it, so a disc without it
                                  cannot be found at all. No profile may omit it.
              2  workspace.yaml   Rewritten on the way - deployRoot becomes
                                  \Share and the credential block goes
                                  (Set-HDTMediaWorkspaceLine). It is the ONLY
                                  file media edits.
              3  Control\         selection-profiles.yaml and the per-machine
                                  rules under Control\machines, so a media
                                  deployment resolves rules exactly as a share
                                  deployment does. MINUS share-credential.json.

            THE FOUR REFUSALS, AND EACH OF THEM COST A REBUILD ON 2026-09-03.
            They are a list at the top of the function with a sentence against
            each, rather than four ifs scattered through it, because the list is
            the thing a future reader has to be able to find and the sentences
            are what the log prints:

              bootstrap-rules.yaml           It is INJECTED INTO THE BOOT IMAGE
                                             at X:\HDT\bootstrap-rules.yaml and
                                             read in WinPE before any content is
                                             reached. Its rules choose a SHARE by
                                             gateway or MAC - on a disc that is
                                             rules choosing a share that is not
                                             there.
              Control\share-credential.json  A Local boot image authenticates to
                                             nothing, so the share credential has
                                             no business on a disc that is handed
                                             around. DESIGN 6.3 treats boot media
                                             as a credential in itself.
              Boot\                          The boot wim belongs at
                                             \sources\boot.wim on the media tree.
                                             Carrying Boot\ inside \Share puts
                                             half a gigabyte on the ISO twice.
              Logs\ and Captures\            The only two folders a deployment
                                             writes to (DESIGN 2.1). They hold
                                             other machines' logs and other
                                             machines' images.

            A PROFILE CANNOT NAME ONE OF THEM, AND THIS FUNCTION DOES NOT REPEAT
            THE REFUSAL. Assert-HDTSelectionProfileDocument allows only
            Get-HDTSelectionProfileContentFolder's five as an include's first
            segment, and Get-HDTSelectionProfile validates on READ - so a share
            carrying such a profile is refused by name, quoting the folder,
            before a projection is ever asked for. A second filter here would be
            a branch no test could reach, which is worse than no filter: it would
            read as the guarantee while the real one lived elsewhere.

        .PARAMETER WorkspaceRoot
            The deployment share to project.

        .PARAMETER SelectionProfile
            The profile id that governs the content half - an authored one or a
            built-in.

        .PARAMETER FileSystem
            The IFileSystem to read with. Mandatory: this is private and every
            caller has one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per row, in build order,
            with Kind (Marker, Document, Control, Content, Excluded), Source
            (share-relative), FullPath, Destination (relative to \Share, empty for
            a refusal), Reason, Present and Rewritten.

        .EXAMPLE
            Get-HDTMediaProjection -WorkspaceRoot 'C:\HDTLab\Share' `
                -SelectionProfile 'everything' -FileSystem $fs

        .EXAMPLE
            Get-HDTMediaProjection -WorkspaceRoot $root -SelectionProfile $id -FileSystem $fs |
                Where-Object { -not $_.Present -and $_.Kind -eq 'Content' }

            What the build warns about, by name, before it spends ten minutes
            producing a disc without it.

        .LINK
            Expand-HDTSelectionProfile
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $SelectionProfile,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE REFUSALS, IN ONE PLACE, EACH WITH THE SENTENCE THE LOG PRINTS. See the
    # header for what each one cost. Adding a refusal is adding a row here;
    # deleting one is deleting a row here, and exactly one test goes red.
    $refusal = @(
        [pscustomobject] @{
            Source = 'bootstrap-rules.yaml'
            Reason = 'it is injected into the boot image at X:\HDT\bootstrap-rules.yaml and read in WinPE before any content is reached, and its rules choose a share by gateway - on a disc that is rules choosing a share that is not there.'
        }
        [pscustomobject] @{
            Source = 'Control\share-credential.json'
            Reason = 'a Local boot image authenticates to nothing, so the deployment account has no business on a disc that is handed around.'
        }
        [pscustomobject] @{
            Source = 'Boot'
            Reason = 'the boot wim belongs at \sources\boot.wim on the media tree, and a second copy inside \Share puts half a gigabyte on the ISO twice.'
        }
        [pscustomobject] @{
            Source = 'Logs'
            Reason = 'it is one of the two folders a deployment writes to, and it holds other machines'' logs rather than anything this disc needs.'
        }
        [pscustomobject] @{
            Source = 'Captures'
            Reason = 'it is one of the two folders a deployment writes to, and it holds other machines'' captured images rather than anything this disc needs.'
        }
    )

    # [IO.Path]::Combine and never Join-Path, for Get-HDTWorkspacePath's reason:
    # a share root is routinely a UNC path or a volume this session has not
    # mounted, and Join-Path resolves the drive qualifier and throws
    # DriveNotFound for one. Building a path must not require it to exist.
    $newRow = {
        param(
            [string] $Kind,
            [string] $Source,
            [string] $Reason,
            [bool] $Travels,
            [bool] $Rewritten
        )

        $relative = $Source.TrimStart('\', '/')
        $full = [System.IO.Path]::Combine($WorkspaceRoot, $relative)

        $destination = ''
        if ($Travels) { $destination = [System.IO.Path]::Combine('\Share', $relative) }

        return [pscustomobject] @{
            Kind        = $Kind
            Source      = $Source
            FullPath    = $full
            Destination = $destination
            Reason      = $Reason
            Present     = [bool] $FileSystem.TestPath($full)
            Rewritten   = $Rewritten
        }
    }

    $row = New-Object -TypeName System.Collections.ArrayList

    # -- 1. the marker --------------------------------------------------------

    [void] $row.Add((& $newRow 'Marker' 'rules.yaml' ('it is the content marker Resolve-HDTDeployRoot hunts every ready volume for, so a disc without it cannot be found at all.') $true $false))

    # -- 2. the one file media rewrites ---------------------------------------

    [void] $row.Add((& $newRow 'Document' 'workspace.yaml' ('the disc is a workspace, and this is the file the provider swap edits: deployRoot becomes \Share and the credential block goes.') $true $true))

    # -- 3. Control\, minus the credential ------------------------------------

    [void] $row.Add((& $newRow 'Control' 'Control' ('it carries selection-profiles.yaml and the per-machine rules under Control\machines, so a media deployment resolves rules exactly as a share deployment does.') $true $false))

    # RECORDED AS ITS OWN ROW RATHER THAN LEFT UNSAID. The Control\ row above
    # says the folder travels; without this the log would not say the credential
    # inside it did not.
    $credentialRefusal = @($refusal | Where-Object { $_.Source -eq 'Control\share-credential.json' })[0]
    [void] $row.Add((& $newRow 'Excluded' $credentialRefusal.Source $credentialRefusal.Reason $false $false))

    # -- 4. what the profile governs ------------------------------------------

    # NO FILTER HERE, DELIBERATELY. See the header: an include may only name one
    # of the five content folders, and Get-HDTSelectionProfile refuses the
    # document on read otherwise, so nothing excluded can arrive through this
    # loop.
    foreach ($folder in @(Expand-HDTSelectionProfile -Root $WorkspaceRoot -Id $SelectionProfile -FileSystem $FileSystem)) {
        $path = [string] $folder.Path

        [void] $row.Add([pscustomobject] @{
                Kind        = 'Content'
                Source      = $path
                FullPath    = [string] $folder.FullPath
                Destination = [System.IO.Path]::Combine('\Share', $path.TrimStart('\', '/'))
                Reason      = "the selection profile '$SelectionProfile' names it."
                Present     = [bool] $folder.Present
                Rewritten   = $false
            })
    }

    # -- 5. the refusals ------------------------------------------------------

    foreach ($current in @($refusal | Where-Object { $_.Source -ne 'Control\share-credential.json' })) {
        [void] $row.Add((& $newRow 'Excluded' ([string] $current.Source) ([string] $current.Reason) $false $false))
    }

    return [pscustomobject[]] @($row)
}
