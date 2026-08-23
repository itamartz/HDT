function Set-HDTOperatingSystemProperty {
    <#
        .SYNOPSIS
            Renames an imported operating system, or changes its description.

        .DESCRIPTION
            DEPLOYMENT WORKBENCH EDITS BOTH ON AN OS's PROPERTIES SHEET, and
            until this existed HDT could only write them at import time - so a
            typo in the name meant importing the media again, which is minutes
            and several gigabytes.

            THE ID IS NOT AMONG THEM. It is the folder name under
            OperatingSystems\ and the value a task sequence names to select the
            image, so changing it is a move and a rewrite of every sequence that
            refers to it, not an edit.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTOperatingSystemDocument
            is what touches the share, and it checks the result first - the same
            split Add-HDTStep and Save-HDTSequenceDocument use, and the reason a
            refusal can be shown beside the box that caused it rather than after
            a file has already changed.

            AN EMPTIED DESCRIPTION REMOVES THE KEY rather than writing an empty
            one: 'description:' with nothing after it is a null a reader has to
            interpret, and "there is no description" is what was meant.

            THE DOCUMENT IS READ BEFORE IT IS EDITED. Splicing a file that does
            not parse would turn one broken document into a differently broken
            one, and the console would show '(unreadable)' with no way back.

        .PARAMETER Line
            The os.yaml, already split into lines.

        .PARAMETER Name
            The name the console, the sequence editor and the wizard show. It
            cannot be cleared.

        .PARAMETER Description
            What the media is, in a sentence. Empty removes the key.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document, spliced.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\OperatingSystems\Win11-LTSC-2024\os.yaml'))
            $line = Set-HDTOperatingSystemProperty -Line $line -Name 'Windows 11 LTSC 2024'
            Save-HDTOperatingSystemDocument -Path 'C:\HDTLab\Share\OperatingSystems\Win11-LTSC-2024\os.yaml' -Line $line

            Renames what an administrator reads in the console. The id is untouched -
            that is the folder name and what every task sequence names.

        .EXAMPLE
            @($line | Where-Object { $_ -match '^name:' })

            The one line that changed. Everything else in os.yaml, comments included, is
            byte for byte what it was.

        .LINK
            Save-HDTOperatingSystemDocument
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
        # folder; the operating system never moves on disk either way - see the
        # key's note in Import-HDTSequenceDocument for why HDT's folders are
        # labels rather than the real directories Workbench uses.
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
                    -Message 'an operating system name cannot be cleared - the console tree, the sequence editor and the deployment wizard all show it. The id identifies it; Remove-HDTOperatingSystem deletes it.'))
    }

    # A FOLDER IS DRAWN FROM ITS OWN TEXT, so a leading or trailing separator
    # produces a nameless level in the tree and a doubled one produces two.
    if ($setsFolder -and -not [string]::IsNullOrWhiteSpace($Folder) -and
        ($Folder -match '^\\|\\$|\\\\' -or $Folder -match '/')) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Folder -Category InvalidArgument `
                    -Message ("'{0}' is not a folder path this window can draw. Separate levels with a single backslash - 'Clients\Laptops' - with nothing before the first or after the last." -f $Folder)))
    }

    # Readable before it is worth editing.
    [void] (ConvertFrom-HDTYaml -Yaml (@($Line) -join [System.Environment]::NewLine) -Path 'os.yaml')

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

    if (-not $PSCmdlet.ShouldProcess('the operating system', ('set {0}' -f (@($action) -join ', ')))) {
        return [string[]] @($Line)
    }

    # THE HEADER'S OWN ORDER AND ITS OWN BLOCK. os.yaml carries more scalars
    # than a sequence does and ends at images:, whose rows each have a name of
    # their own - matching on the word alone would rename index 1.
    $order = @('schemaVersion', 'id', 'name', 'description', 'type', 'architecture',
        'sourcePath', 'importedUtc', 'defaultIndex')

    $result = [string[]] @($Line)

    if ($setsName) {
        $result = [string[]] @(Set-HDTDocumentHeaderKey -Line $result -Key 'name' -Value $Name `
                -Order $order -Block 'images')
    }

    if ($setsDescription) {
        $result = [string[]] @(Set-HDTDocumentHeaderKey -Line $result -Key 'description' -Value $Description `
                -Order $order -Block 'images')
    }

    if ($setsFolder) {
        $result = [string[]] @(Set-HDTDocumentHeaderKey -Line $result -Key 'folder' -Value $Folder `
                -Order ($order + @('folder')) -Block 'images')
    }

    return [string[]] @($result)
}
