function Remove-HDTWorkspaceFolder {
    <#
        .SYNOPSIS
            Takes a console folder off the share, leaving every other line of
            workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to delete a folder, and the one the
            console's Delete Folder item has to run.

            IT DELETES A LABEL, NOT A TASK SEQUENCE. Nothing on disk moves and no
            document is touched: a sequence still in the folder keeps saying so
            and the tree draws the folder again from the document. That is why the
            console refuses to delete a folder with anything in it - the delete
            would appear to do nothing.

            WHAT IS INSIDE IT GOES WITH IT. Removing Clients while
            Clients\Laptops is still declared leaves a folder the tree draws
            anyway, from the child's own path, so the child is removed too.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Category
            Which part of the tree the folder belongs to.

        .PARAMETER Folder
            The folder, exactly as it is declared.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the folder removed.

        .EXAMPLE
            Remove-HDTWorkspaceFolder -Line $line -Category TaskSequence -Folder 'Clients'

        .LINK
            Add-HDTWorkspaceFolder
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('TaskSequence', 'OperatingSystem', 'Application')]
        [string] $Category,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Folder
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $key = Get-HDTWorkspaceFolderKey -Category $Category

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line
    $declared = [string[]] @($workspace.Folder.$Category)

    $comparable = $Folder.ToLowerInvariant()
    $inside = $comparable + '\'

    # THE FOLDER AND EVERYTHING UNDER IT, by position, because position is how
    # Remove-HDTWorkspaceItem names an entry - and highest first, so removing one
    # does not move the next.
    $doomed = New-Object -TypeName System.Collections.ArrayList

    for ($index = 0; $index -lt @($declared).Count; $index++) {
        $current = ([string] $declared[$index]).ToLowerInvariant()

        if ($current -eq $comparable -or $current.StartsWith($inside)) { [void] $doomed.Add($index) }
    }

    if (@($doomed).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Folder -Category ObjectNotFound `
                    -Message ("'{0}' is not a folder declared on this share. Only a folder made here is declared; one the console draws because a document names it is removed by taking that document out of it." -f $Folder)))
    }

    if (-not $PSCmdlet.ShouldProcess($Folder, ('Remove from the {0} folders' -f $Category))) {
        return [string[]] @($Line)
    }

    $result = [string[]] @($Line)

    foreach ($index in @($doomed | Sort-Object -Descending)) {
        $result = [string[]] @(Remove-HDTWorkspaceItem -Line $result -Path @('folders', $key) -Position $index)
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
