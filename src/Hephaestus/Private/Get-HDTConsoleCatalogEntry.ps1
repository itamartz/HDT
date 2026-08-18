function Get-HDTConsoleCatalogEntry {
    <#
        .SYNOPSIS
            Finds the folders under one workspace directory that actually hold a
            catalog document.

        .DESCRIPTION
            TaskSequences\ and OperatingSystems\ are both "a folder per item,
            with one YAML document inside it", so both are
            enumerated the same way and the rule for what counts lives here once.

            A FOLDER IS A CATALOG ITEM ONLY IF THE DOCUMENT IS IN IT. The lab
            share has a loose sequence.yaml and an unattend.xml sitting beside
            the sequence folders, left there by an earlier phase, and a console
            that listed every child of TaskSequences\ would offer 'unattend.xml'
            as a task sequence. The test for a folder is therefore not "is it a
            directory" - IFileSystem has no such question - but "does the
            document exist inside it", which is the thing the console actually
            needs to be true and which answers correctly for a loose file as well.

            A MISSING DIRECTORY IS AN EMPTY CATALOG, NOT A FAILURE. A share
            created five minutes ago has no OperatingSystems\ folder yet, and an
            admin console that refuses to open until every folder exists is a
            console nobody can use to set the share up.

        .PARAMETER Root
            The workspace root.

        .PARAMETER Kind
            The workspace folder, as Get-HDTWorkspacePath names it.

        .PARAMETER DocumentName
            The document that makes a folder a catalog item - sequence.yaml or
            os.yaml.

        .PARAMETER FileSystem
            An IFileSystem.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Id, Folder and
            DocumentPath, ordered by Id.

        .EXAMPLE
            Get-HDTConsoleCatalogEntry -Root 'C:\HDTLab\Share' -Kind TaskSequences -DocumentName 'sequence.yaml' -FileSystem $fs
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [ValidateSet('TaskSequences', 'OperatingSystems', 'Applications')]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $DocumentName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $found = New-Object -TypeName System.Collections.ArrayList

    $catalogRoot = Get-HDTWorkspacePath -Root $Root -Kind $Kind

    if (-not $FileSystem.TestPath($catalogRoot)) {
        return [pscustomobject[]] @()
    }

    foreach ($child in @($FileSystem.GetChildItem($catalogRoot))) {
        $documentPath = [System.IO.Path]::Combine($child, $DocumentName)

        if (-not $FileSystem.TestPath($documentPath)) {
            continue
        }

        [void] $found.Add([pscustomobject] @{
                Id           = [System.IO.Path]::GetFileName($child)
                Folder       = $child
                DocumentPath = $documentPath
            })
    }

    return [pscustomobject[]] @($found | Sort-Object -Property Id)
}
