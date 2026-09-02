function Set-HDTWindowsUpdate {
    <#
        .SYNOPSIS
            Changes the name or description of a Windows update already imported
            into the workspace, leaving every other line of its update.yaml
            byte-identical.

        .DESCRIPTION
            The other half of Import-HDTWindowsUpdate. Import registers an entry
            and refuses to replace one; this changes the two things about an
            entry that are the ADMINISTRATOR'S OWN WORDS rather than the
            package's. Everything else in update.yaml - the kb, the kind, the
            architecture, the builds - was read out of the package's own CompDB
            metadata, and a command that let those be typed over would turn a
            catalog of measured facts into a catalog of guesses.

            IT SPLICES, IT NEVER RE-SERIALISES. update.yaml is a written document
            like every other in a share, and a parse-then-write round trip drops
            every comment in it. Only the key being changed is rewritten, through
            Set-HDTDocumentHeaderKey - the same splice behind
            Set-HDTTaskSequenceProperty and Set-HDTOperatingSystemProperty.

            NAME AND DESCRIPTION ONLY, AND THAT IS SAFE BY CONSTRUCTION rather
            than by care. The ApplyUpdates step selects by RELEASE and by ID -
            see Invoke-HDTApplyUpdatesStep, whose `release` and `updates` read
            those two and nothing else - so neither of the keys this command
            writes is one a deployment ever matches on. They are display labels:
            what the console row reads and what a technician recognises the
            entry by. The ID IS NOT WRITABLE HERE for exactly that reason: a
            sequence may name it, and renaming it would break the sequence
            silently.

            THE ID IS NOT SETTABLE, and that is deliberate. It is the FOLDER NAME
            under WindowsUpdates\ as well as a key in the file, so changing it is
            a move rather than an edit: the directory has to be renamed, the .msu
            beside it carried across, and the document rewritten, with a window
            in between where the two disagree and Get-HDTWindowsUpdate - which
            enumerates by folder - reads an entry whose id is not its own. That
            is a command of its own, when there is a reason for it. Import the
            update under the id you meant.

            AN EMPTY DESCRIPTION REMOVES THE KEY rather than writing an empty
            one, which is what "take the note away" has to mean: `description:`
            with nothing after it is a key whose value is null, and the validator
            would be right to refuse it. THE NAME CANNOT BE CLEARED - the console
            row reads 'KB - name', and an update with none is a blank row.

            EVERY EDIT IS HELD TO Assert-HDTWindowsUpdateDocument BEFORE ANYTHING
            IS WRITTEN, so a refused change leaves the file exactly as it was
            rather than half-edited.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The update id, which is the folder name under WindowsUpdates\.

        .PARAMETER Name
            The display name. Cannot be cleared - it is what the console row and
            the update list read.

        .PARAMETER Description
            A free-text note for the console: why this update is here, or which
            servicing window it is waiting for. An empty string removes it.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one, which is what an
            administrator wants; a test passes New-HDTFakeFileSystem instead.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the changed update, in
            the shape Get-HDTWindowsUpdate returns.

        .EXAMPLE
            Set-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' -Id 'KB5094126-x64' `
                -Name '2026-06 cumulative update, Windows 11 24H2'

            Renames the entry and touches nothing else in the file.

        .EXAMPLE
            Set-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' -Id 'KB5094126-x64' `
                -Description 'Held back until the June servicing window.'

            Adds the note under the name, where update.yaml writes it.

        .EXAMPLE
            Set-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' -Id 'KB5094126-x64' -Description ''

            Takes the note away.

        .LINK
            Import-HDTWindowsUpdate

        .LINK
            Get-HDTWindowsUpdate
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        # FROM THE PIPELINE BY PROPERTY NAME, so Get-HDTWindowsUpdate can feed
        # it: the rows it emits carry both WorkspaceRoot and Id, which is what
        # makes 'Get-HDTWindowsUpdate ... | Set-HDTWindowsUpdate -Description ...'
        # work.
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Description,

        # DEFAULTED, NOT MANDATORY, on New-HDTWorkspace's reasoning: this is a
        # command an administrator types, not one the engine's hot path calls.
        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    # ONE OBJECT AT A TIME. -WorkspaceRoot and -Id bind from the pipeline, and a
    # flat body would run once, for the last entry handed over.
    process {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $setsName = $PSBoundParameters.ContainsKey('Name')
        $setsDescription = $PSBoundParameters.ContainsKey('Description')

        if (-not ($setsName -or $setsDescription)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id -Category InvalidArgument `
                        -Message ("nothing was asked of update '{0}'. Pass -Name or -Description; an omitted one is left as it is. Everything else in update.yaml was read out of the package and is not typed over." -f $Id)))
        }

        if ($setsName -and [string]::IsNullOrWhiteSpace($Name)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id -Category InvalidArgument `
                        -Message 'an update''s name cannot be cleared - the console row reads ''KB - name'', and one with none is a blank row. The id identifies it; Remove-HDTWindowsUpdate deletes it.'))
        }

        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $Id, 'update.yaml'

        if (-not $FileSystem.TestPath($catalogPath)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath -Category ObjectNotFound `
                        -Message ("no Windows update with the id '{0}' is in this workspace. Import-HDTWindowsUpdate registers a new one." -f $Id)))
        }

        $line = [string[]] @($FileSystem.ReadAllText($catalogPath) -split "`r?`n")

        # THE HEADER ORDER update.yaml IS WRITTEN IN, so a document that gains a
        # description gains it under the name - where Import-HDTWindowsUpdate
        # puts one, and where a reader looks for it - rather than at the top or
        # appended after the metadata. update.yaml has no nested block at all, so
        # nothing below can be mistaken for a top-level key.
        $order = @('schemaVersion', 'id', 'kb', 'name', 'description')

        $result = [string[]] @($line)

        if ($setsName) {
            $result = [string[]] @(Set-HDTDocumentHeaderKey -Line $result -Key 'name' -Value $Name -Order $order)
        }

        if ($setsDescription) {
            $result = [string[]] @(Set-HDTDocumentHeaderKey -Line $result -Key 'description' -Value $Description -Order $order)
        }

        $written = ($result -join [System.Environment]::NewLine)

        # HELD TO THE VALIDATOR BEFORE ANYTHING IS WRITTEN, so a refused change
        # leaves the file as it was rather than half-edited.
        $document = ConvertFrom-HDTYaml -Yaml $written -Path $catalogPath
        Assert-HDTWindowsUpdateDocument -Document $document -Path $catalogPath

        $asked = New-Object -TypeName System.Collections.ArrayList
        if ($setsName) { [void] $asked.Add('name') }
        if ($setsDescription) { [void] $asked.Add('description') }

        if (-not $PSCmdlet.ShouldProcess($catalogPath, ("Set {0} on update '{1}'" -f (@($asked) -join ', '), $Id))) {
            return $null
        }

        $FileSystem.WriteAllText($catalogPath, $written)

        return (Get-HDTWindowsUpdate -WorkspaceRoot $WorkspaceRoot -Id $Id -FileSystem $FileSystem)
    }
}
