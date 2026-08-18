function Set-HDTTaskSequenceProperty {
    <#
        .SYNOPSIS
            Renames a task sequence, or rewrites its description.

        .DESCRIPTION
            THE TWO LINES AT THE TOP OF sequence.yaml, and until this existed
            nothing could edit them. Set-HDTWorkspaceProperty does the job for
            the share and Set-HDTApplication for an application; a sequence's own
            name and description had no command - so the editor showed them and
            could not change them, which is the console's rule working correctly
            and leaving a hole.

            IT SPLICES AND NEVER RE-EMITS. A sequence is a document somebody
            wrote, commented and committed - DEMO-M4 is half commentary - and a
            parse-and-re-serialise hands back a dictionary with no comments in
            it. Only the line being changed is new.

            AN OMITTED PARAMETER MEANS "leave it alone" AND AN EMPTY STRING
            MEANS "take it away". Both are needed and they are not the same: a
            window with two boxes passes only what it was asked to change, or one
            blank box wipes a description nobody touched.

            THE NAME CANNOT BE CLEARED. The tree, the deployment wizard and this
            editor all show it, and a sequence with no name is a blank row in
            three places. The id is what identifies it and Remove-HDTTaskSequence
            is what deletes it.

            THE ID IS NOT EDITABLE HERE, ON PURPOSE. It is the folder name, so
            changing it is a move: rules that name it, boot images that select
            it and the run state on a machine mid-deployment all point at the old
            one. That is a command of its own, when there is a reason for it.

        .PARAMETER Line
            The sequence.yaml lines to edit. Returned spliced, with every line
            this command was not asked to change byte-identical.

        .PARAMETER Name
            The new name. An empty string is refused.

        .PARAMETER Description
            The new description. An empty string removes the key.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the sequence.yaml lines, spliced.

        .EXAMPLE
            $line = Get-Content -LiteralPath 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $line = Set-HDTTaskSequenceProperty -Line $line -Name 'Windows 11 LTSC, bare metal'
            Save-HDTSequenceDocument -Line $line -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'

        .EXAMPLE
            Set-HDTTaskSequenceProperty -Line $line -Description ''

            Takes the description away.

        .LINK
            Save-HDTSequenceDocument

        .LINK
            Remove-HDTTaskSequence
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Description,

        # WHICH FOLDER THE CONSOLE DRAWS IT UNDER. Empty takes it out of every
        # folder; the sequence never moves on disk either way - see the key's
        # own note in Import-HDTSequenceDocument for why HDT's folders cannot be
        # real directories the way Deployment Workbench's are.
        [Parameter()]
        [AllowEmptyString()]
        [string] $Folder
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $setsName = $PSBoundParameters.ContainsKey('Name')
    $setsDescription = $PSBoundParameters.ContainsKey('Description')
    $setsFolder = $PSBoundParameters.ContainsKey('Folder')

    if (-not ($setsName -or $setsDescription -or $setsFolder)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $null -Category InvalidArgument `
                    -Message 'nothing was asked for. Pass -Name, -Description or -Folder; an omitted one is left as it is.'))
    }

    if ($setsName -and [string]::IsNullOrWhiteSpace($Name)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category InvalidArgument `
                    -Message 'a task sequence name cannot be cleared - the tree, the wizard and the editor all show it, and one with none is a blank row in three places. The id identifies it; Remove-HDTTaskSequence deletes it.'))
    }

    # A FOLDER IS DRAWN FROM ITS OWN TEXT, so a leading or trailing separator
    # produces a nameless level in the tree and a doubled one produces two.
    # Refused here rather than drawn.
    if ($setsFolder -and -not [string]::IsNullOrWhiteSpace($Folder) -and
        ($Folder -match '^\\|\\$|\\\\' -or $Folder -match '/')) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Folder -Category InvalidArgument `
                    -Message ("'{0}' is not a folder path this window can draw. Separate levels with a single backslash - 'Clients\Laptops' - with nothing before the first or after the last." -f $Folder)))
    }

    # The document has to be readable before it is worth editing.
    [void] (ConvertFrom-HDTSequenceLine -Line $Line)

    $action = New-Object -TypeName System.Collections.ArrayList
    if ($setsName) { [void] $action.Add(("name to '{0}'" -f $Name)) }
    if ($setsDescription -and -not [string]::IsNullOrWhiteSpace($Description)) {
        [void] $action.Add(("description to '{0}'" -f $Description))
    }
    if ($setsDescription -and [string]::IsNullOrWhiteSpace($Description)) {
        [void] $action.Add('description removed')
    }
    if ($setsFolder -and -not [string]::IsNullOrWhiteSpace($Folder)) {
        [void] $action.Add(("folder to '{0}'" -f $Folder))
    }
    if ($setsFolder -and [string]::IsNullOrWhiteSpace($Folder)) {
        [void] $action.Add('taken out of its folder')
    }

    if (-not $PSCmdlet.ShouldProcess('sequence.yaml', ('Set the {0}' -f (@($action) -join ', ')))) {
        return [string[]] @($Line)
    }

    $result = [string[]] @($Line)

    if ($setsName) {
        $result = [string[]] @(Set-HDTDocumentHeaderKey -Line $result -Key 'name' -Value $Name)
    }

    if ($setsDescription) {
        $result = [string[]] @(Set-HDTDocumentHeaderKey -Line $result -Key 'description' -Value $Description)
    }

    if ($setsFolder) {
        $result = [string[]] @(Set-HDTDocumentHeaderKey -Line $result -Key 'folder' -Value $Folder `
                -Order @('schemaVersion', 'id', 'name', 'description', 'folder'))
    }

    try {
        [void] (ConvertFrom-HDTSequenceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
