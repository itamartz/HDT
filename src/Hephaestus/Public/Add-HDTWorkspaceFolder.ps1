function Add-HDTWorkspaceFolder {
    <#
        .SYNOPSIS
            Declares a console folder on the share, leaving every other line of
            workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to make a folder, and the one the
            console's New Folder item has to run.

            A FOLDER WITH SOMETHING IN IT NEEDS NOTHING WRITTEN HERE. Task
            sequences, operating systems and applications each carry a folder key
            naming where the console draws them, and the tree builds the folder
            from that - see Set-HDTTaskSequenceProperty -Folder. That covers every
            folder except the one somebody has just made and not yet put anything
            in, which is the folder this command is for: without it, New Folder
            would draw a folder that the next refresh silently deleted.

            THE TREE DRAWS THE UNION of what is listed here and what the documents
            name, so a folder made here and then filled is not listed twice, and a
            folder named by a hand-edited document draws without being listed at
            all.

            THE PARENTS ARE WRITTEN WITH IT. A tree cannot draw Clients\Laptops
            without Clients, so both are declared - otherwise removing the child
            would take a folder nobody asked to remove with it.

            ONE LIST PER CATEGORY: 'Clients' under task sequences and 'Clients'
            under operating systems are different folders, here and in the tree.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Category
            Which part of the tree the folder belongs to.

        .PARAMETER Folder
            The folder, with levels separated by a single backslash -
            'Clients\Laptops'.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the folder declared.

        .EXAMPLE
            Add-HDTWorkspaceFolder -Line $line -Category TaskSequence -Folder 'Clients\Laptops'

        .LINK
            Remove-HDTWorkspaceFolder

        .LINK
            Set-HDTTaskSequenceProperty
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
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
        [AllowEmptyString()]
        [string] $Folder
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $key = Get-HDTWorkspaceFolderKey -Category $Category

    if ([string]::IsNullOrWhiteSpace($Folder) -or $Folder -match '^\\|\\$|\\\\' -or $Folder -match '/') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Folder -Category InvalidArgument `
                    -Message ("'{0}' is not a folder path this window can draw. Separate levels with a single backslash - 'Clients\Laptops' - with nothing before the first or after the last." -f $Folder)))
    }

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line
    $declared = [string[]] @($workspace.Folder.$Category)

    # THE FOLDER AND EVERY LEVEL ABOVE IT, in order, skipping the ones already
    # declared - adding Clients\Laptops to a share that has Clients writes one
    # line, not two.
    $part = @($Folder -split '\\')
    $wanted = New-Object -TypeName System.Collections.ArrayList

    for ($index = 0; $index -lt $part.Count; $index++) {
        [void] $wanted.Add([string]::Join('\', $part[0..$index]))
    }

    $existing = @($declared | ForEach-Object { ([string] $_).ToLowerInvariant() })

    if ($existing -contains $Folder.ToLowerInvariant()) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Folder -Category InvalidArgument `
                    -Message ("'{0}' is already a folder on this share. Folder names are compared without regard to case." -f $Folder)))
    }

    $adding = @($wanted | Where-Object { $existing -notcontains ([string] $_).ToLowerInvariant() })

    if (-not $PSCmdlet.ShouldProcess($Folder, ('Add to the {0} folders' -f $Category))) {
        return [string[]] @($Line)
    }

    $result = [string[]] @($Line)

    foreach ($current in @($adding)) {
        $block = Get-HDTWorkspaceKey -Line $result -Path @('folders', $key)

        if ($null -ne $block) {
            $result = [string[]] @(Add-HDTWorkspaceItem -Line $result -Block $block `
                    -Text ([string[]] @('- {0}' -f (ConvertTo-HDTRuleScalarText -Value ([string] $current)))))
        } else {
            $result = [string[]] @(Set-HDTWorkspaceKey -Line $result -Path @('folders', $key) `
                    -Text ([string[]] @(
                        ('{0}:' -f $key)
                        ('  - {0}' -f (ConvertTo-HDTRuleScalarText -Value ([string] $current))))))
        }
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
