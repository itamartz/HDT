function Set-HDTMedia {
    <#
        .SYNOPSIS
            Edits one or more keys of a standalone media definition, leaving
            every other line of the document byte-identical.

        .DESCRIPTION
            IT SPLICES. media.yaml is a document an administrator hand-edits and
            comments, and comments die at parse time - a round trip through the
            YAML writer would take every one of them out and hand back a file
            that says the same thing and reads like a machine wrote it. So this
            changes the line it was asked about and copies the rest through
            unchanged, using Set-HDTDocumentHeaderKey, the same flat-header
            splice Set-HDTTaskSequenceProperty and Set-HDTOperatingSystemProperty
            already go through.

            ONLY THE PARAMETERS ACTUALLY BOUND ARE WRITTEN, tested with
            $PSBoundParameters.ContainsKey rather than with a null-or-empty test:
            '' is a legitimate value for -Description and means "take it out",
            which is what the splice does with a blank value.

            THERE IS NO WAY TO CHANGE THE ID, deliberately. The id is the folder
            name under Media\ and the key every other command addresses the item
            by, so renaming one is a folder move and not a document edit -
            Remove-HDTMedia and New-HDTMedia are how it is done, and both of them
            say what they are doing to the disk.

            THE SELECTION PROFILE IS CHECKED AGAINST THE SHARE, exactly as
            New-HDTMedia checks it, and through the injected filesystem - because
            Get-HDTSelectionProfile defaults -FileSystem to the real adapter, and
            a call that omitted it would read the actual disk while every other
            line here read the one it was handed.

            THE SPLICED TEXT IS VALIDATED BEFORE IT IS WRITTEN. An edit that
            produced a document the engine's own validator would refuse has left
            a broken file on the share, and the caller would find out on the next
            read rather than on the write that caused it.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The media id, which is the folder name under Media\.

        .PARAMETER Name
            What an administrator reads in the console's Media node.

        .PARAMETER Description
            Free text - Workbench's Comments box. An empty string removes the
            key.

        .PARAMETER SelectionProfile
            Which of the share's content travels onto the disc.

        .PARAMETER Output
            The ISO the build writes. Share-relative unless it is rooted.

        .PARAMETER Enabled
            The tick. A [bool] rather than a [switch] because -Enabled:$false has
            to be sayable.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .INPUTS
            System.Management.Automation.PSCustomObject with WorkspaceRoot and Id
            - which is what Get-HDTMedia returns, so
            Get-HDTMedia ... | Set-HDTMedia -Enabled $false works.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, as Get-HDTMedia returns
            it.

        .EXAMPLE
            Set-HDTMedia -WorkspaceRoot 'C:\HDTLab\Share' -Id 'WIN11-FIELD' -SelectionProfile 'field-kit'

            Narrows the projection to one profile. The comments in the document
            are still there afterwards.

        .EXAMPLE
            Get-HDTMedia -WorkspaceRoot 'C:\HDTLab\Share' | Set-HDTMedia -Enabled $false

            Turns every media item off before a share is handed over, so nothing
            builds by accident.

        .LINK
            New-HDTMedia

        .LINK
            Get-HDTMedia

        .LINK
            Remove-HDTMedia
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Media is a mass noun here and the singular name of one object - MDT calls the Deployment Workbench node Media and its action Update Media Content, and DESIGN 6.2 names these four commands. The analyzer reads it as the Latin plural of medium. Renaming to MediaItem would make HDT the only toolkit an MDT admin has to translate.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Description,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $SelectionProfile,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Output,

        [Parameter()]
        [bool] $Enabled,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    # ONE OBJECT AT A TIME. -WorkspaceRoot and -Id bind from the pipeline, and a
    # flat body would run once, for the last entry handed over.
    process {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        # THE HEADER OF media.yaml, IN THE ORDER THE DOCUMENT WRITES IT. A key
        # that is not there yet lands after the last of these that is.
        $order = @('schemaVersion', 'id', 'name', 'description', 'selectionProfile', 'output', 'enabled')

        # '(?!)' NEVER MATCHES, which is how "this document has no nested block"
        # is said - media.yaml is flat. Left at the sequence/os default of
        # 'steps|variables' a value line opening with one of those words would
        # end the header early and every key below it would be inserted rather
        # than replaced. An empty string cannot be used: -Block is
        # ValidateNotNullOrEmpty and would be refused at bind time.
        $noBlock = '(?!)'

        $setsName = $PSBoundParameters.ContainsKey('Name')
        $setsDescription = $PSBoundParameters.ContainsKey('Description')
        $setsSelectionProfile = $PSBoundParameters.ContainsKey('SelectionProfile')
        $setsOutput = $PSBoundParameters.ContainsKey('Output')
        $setsEnabled = $PSBoundParameters.ContainsKey('Enabled')

        if (-not ($setsName -or $setsDescription -or $setsSelectionProfile -or $setsOutput -or $setsEnabled)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id -Category InvalidArgument `
                        -Message 'nothing was asked for. Pass -Name, -Description, -SelectionProfile, -Output or -Enabled; an omitted one is left as it is.'))
        }

        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $Id, 'media.yaml'

        if (-not $FileSystem.TestPath($catalogPath)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                        -Message ("no media definition with the id '{0}' is in this workspace. A media definition is a folder under Media\ holding a media.yaml." -f $Id) `
                        -Category ObjectNotFound))
        }

        # -- the refusals, before anything is spliced -------------------------

        if ($setsOutput -and -not $Output.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Output -Category InvalidArgument `
                        -Message ("output '{0}' does not name an .iso. HDT emits exactly one artifact for a media item and it is an ISO." -f $Output)))
        }

        if ($setsSelectionProfile) {
            # -FileSystem PASSED ON. See the description: without it this reads
            # the real disk while everything else reads the injected one.
            $available = @(Get-HDTSelectionProfile -Root $WorkspaceRoot -FileSystem $FileSystem)

            if (@($available | Where-Object { $_.Id -eq $SelectionProfile }).Count -eq 0) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $SelectionProfile `
                            -Message ("no selection profile with the id '{0}' is on this share, so this media item would project content nobody could name. The ids it has are {1}." -f
                                $SelectionProfile, (@($available | ForEach-Object { $_.Id }) -join ', ')) `
                            -Category ObjectNotFound))
            }
        }

        # -- the splice -------------------------------------------------------

        $text = [string] $FileSystem.ReadAllText($catalogPath)

        # THE LINE ENDING IS THE DOCUMENT'S OWN. Splitting on `r?`n and rejoining
        # with [Environment]::NewLine would rewrite every line ending in a file
        # somebody edited on another machine, which is not a byte-identical edit
        # of one key.
        $newLine = "`n"
        if ($text -match "`r`n") { $newLine = "`r`n" }

        $line = [string[]] @($text -split "`r?`n")

        $action = New-Object -TypeName System.Collections.ArrayList

        if ($setsName) {
            $line = [string[]] @(Set-HDTDocumentHeaderKey -Line $line -Key 'name' -Value $Name `
                    -Order $order -Block $noBlock)
            [void] $action.Add(("name to '{0}'" -f $Name))
        }

        if ($setsDescription) {
            $line = [string[]] @(Set-HDTDocumentHeaderKey -Line $line -Key 'description' -Value $Description `
                    -Order $order -Block $noBlock)

            if ([string]::IsNullOrWhiteSpace($Description)) {
                [void] $action.Add('description removed')
            } else {
                [void] $action.Add(("description to '{0}'" -f $Description))
            }
        }

        if ($setsSelectionProfile) {
            $line = [string[]] @(Set-HDTDocumentHeaderKey -Line $line -Key 'selectionProfile' -Value $SelectionProfile `
                    -Order $order -Block $noBlock)
            [void] $action.Add(("selection profile to '{0}'" -f $SelectionProfile))
        }

        if ($setsOutput) {
            $line = [string[]] @(Set-HDTDocumentHeaderKey -Line $line -Key 'output' -Value $Output `
                    -Order $order -Block $noBlock)
            [void] $action.Add(("output to '{0}'" -f $Output))
        }

        if ($setsEnabled) {
            # BARE LOWERCASE true/false. Set-HDTDocumentHeaderKey treats a
            # whitespace value as REMOVE THE KEY, which is what makes
            # -Description '' work and is why this must never reach it empty.
            $line = [string[]] @(Set-HDTDocumentHeaderKey -Line $line -Key 'enabled' `
                    -Value $Enabled.ToString().ToLowerInvariant() -Order $order -Block $noBlock)
            [void] $action.Add(("enabled to {0}" -f $Enabled.ToString().ToLowerInvariant()))
        }

        $written = (@($line) -join $newLine)

        # -- validated before it is written -----------------------------------

        $document = ConvertFrom-HDTYaml -Yaml $written -Path $catalogPath
        Assert-HDTMediaDocument -Document $document -Path $catalogPath -Id $Id

        if (-not $PSCmdlet.ShouldProcess($catalogPath, ('Set the {0}' -f (@($action) -join ', ')))) {
            return (Get-HDTMedia -WorkspaceRoot $WorkspaceRoot -Id $Id -FileSystem $FileSystem)
        }

        $FileSystem.WriteAllText($catalogPath, $written)

        return (Get-HDTMedia -WorkspaceRoot $WorkspaceRoot -Id $Id -FileSystem $FileSystem)
    }
}
