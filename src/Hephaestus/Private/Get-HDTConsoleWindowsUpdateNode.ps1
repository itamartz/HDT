function Get-HDTConsoleWindowsUpdateNode {
    <#
        .SYNOPSIS
            The Windows Updates category of one share, grouped by release.

        .DESCRIPTION
            MDT's Packages node. The grouping is the point of it: a .msu does not say
            which product it is for, so the release an administrator chose at import is
            the organising fact and the release rows are computed from the updates
            rather than declared by anybody.

            ONE CATEGORY, ONE BUILDER - see Get-HDTConsoleShareNode, which composes
            this one with the rest in the order a share is built.

        .PARAMETER Workspace
            The share from Get-HDTConsoleWorkspace this category belongs to.
            The whole projection is passed rather than the one list this
            category draws: the rows carry the share root in their commands and
            some carry the share itself as Subject, so a narrower parameter
            would be three parameters that always travel together.

        .PARAMETER Header
            The banner every node in the tree carries, from
            Get-HDTConsoleHeader.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - the category row
            first, then every row beneath it in display order. The rows are also
            wired into the Children of their parents, so the caller adds the
            whole list to the flat reading and the first row to the tree.

        .EXAMPLE
            Get-HDTConsoleWindowsUpdateNode -Workspace $workspace -Header $header
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Workspace,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Header
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $node = New-Object -TypeName System.Collections.ArrayList

    # GROUPED BY RELEASE, AND THE GROUPING IS THE POINT OF THE CATEGORY. An
    # update is only meaningful against the operating system it is for, and
    # nothing in a .msu says which one that is: the Windows 11 24H2 and Windows
    # Server 2025 cumulative updates share a file-name shape, an architecture and
    # the build 26100. So the release an administrator chose at import is the
    # organising fact, and a flat list of KB numbers would hide exactly the thing
    # somebody opens this node to check.
    #
    # THE RELEASE ROWS ARE COMPUTED, NOT DECLARED. They come from what the
    # updates say, not from a folder anybody made, so there is no New Folder here
    # and no rename - which is why they are their own Kind rather than 'Folder'.

    $updateFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind WindowsUpdates
    $updateCommand = "Get-HDTWindowsUpdate -WorkspaceRoot '{0}'" -f $Workspace.Root

    $update = @($Workspace.WindowsUpdate)

    # NAMED, as the other categories are: the window hangs Import Windows Update
    # off this row and must tell it from the rest without parsing a label
    # somebody may reword. It carries the share as Subject for the same reason
    # the Drivers category does - the import handler needs the root.
    $updateCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'WindowsUpdates' `
        -Text ('Windows Updates ({0})' -f $update.Count) `
        -Icon (Get-HDTConsoleIcon -Kind 'WindowsUpdate' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $updateFolder
        New-HDTConsoleField -Label 'Updates' -Value $update.Count
        New-HDTConsoleField -Label 'Releases' -Value (@(@($update | ForEach-Object { $_.Release } | Sort-Object -Unique)) -join ', ')
        New-HDTConsoleField -Label '' -Value 'Updates applied to the image offline, before the machine first boots - MDT''s Packages node. Import a .msu and the ApplyUpdates step injects it into the applied volume.'
    ) `
        -Command $updateCommand -Header $Header -Subject $Workspace

    [void] $node.Add($updateCategory)

    if ($update.Count -eq 0) {
        $emptyUpdateRow = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $updateFolder
            New-HDTConsoleField -Label '' -Value 'There is no Windows update on this share yet. Add one with Import-HDTWindowsUpdate, or right-click this node and choose Import Windows Update. It lands as a folder under the folder above with an update.yaml and the .msu beside it.'
        ) `
            -Command $updateCommand -Header $Header

        [void] $node.Add($emptyUpdateRow)
        [void] $updateCategory.Children.Add($emptyUpdateRow)
    }

    # ONE GROUP PER RELEASE THAT HAS UPDATES IN IT, in the order the releases are
    # declared, so two shares with the same updates draw the same tree.
    $releaseOrder = @(@($Workspace.OsRelease | ForEach-Object { [string] $_.Id }) +
        @($update | ForEach-Object { [string] $_.Release })) | Select-Object -Unique

    foreach ($releaseId in $releaseOrder) {

        $inRelease = @($update | Where-Object { [string] $_.Release -eq $releaseId })

        if ($inRelease.Count -eq 0) { continue }

        $releaseRow = @($Workspace.OsRelease | Where-Object { [string] $_.Id -eq $releaseId })

        $releaseName = $releaseId
        $releaseField = New-Object -TypeName System.Collections.ArrayList
        [void] $releaseField.Add((New-HDTConsoleField -Label 'Release' -Value $releaseId))

        if ($releaseRow.Count -gt 0) {
            $releaseName = [string] $releaseRow[0].Name

            [void] $releaseField.Add((New-HDTConsoleField -Label 'Name' -Value $releaseRow[0].Name))

            # WHETHER THE BUILD IS A FACT, SAID ON THE ROW AND NOT ONLY IN THE
            # YAML. A release whose build was never read off real media cannot
            # check anything an update claims, and an administrator reading this
            # pane has to be able to see that without opening a file. Windows 11
            # 26H2 ships with no build on purpose.
            if ($releaseRow[0].HasBuild) {
                [void] $releaseField.Add((New-HDTConsoleField -Label 'Build' -Value $releaseRow[0].Build))
            } else {
                [void] $releaseField.Add((New-HDTConsoleField -Label 'Build' -Value '(not recorded)'))
            }

            [void] $releaseField.Add((New-HDTConsoleField -Label 'Build verified' -Value (Get-HDTConsoleFlagText -Value $releaseRow[0].Verified)))

            if (-not [string]::IsNullOrWhiteSpace([string] $releaseRow[0].Note)) {
                [void] $releaseField.Add((New-HDTConsoleField -Label 'Note' -Value $releaseRow[0].Note))
            }

            [void] $releaseField.Add((New-HDTConsoleField -Label 'Release list' -Value ([string] $releaseRow[0].Source)))
        }

        [void] $releaseField.Add((New-HDTConsoleField -Label 'Updates' -Value $inRelease.Count))

        # THE LABEL SAYS UNVERIFIED ON THE ROW ITSELF. A marker in the detail
        # pane only is a marker nobody sees while scanning the tree, and the
        # whole point of shipping an unverified release is that it must not pass
        # for a measured one.
        $releaseText = '{0} ({1})' -f $releaseName, $inRelease.Count
        if ($releaseRow.Count -gt 0 -and -not $releaseRow[0].Verified) {
            $releaseText = '{0} ({1}) - build not verified' -f $releaseName, $inRelease.Count
        }

        $releaseNode = New-HDTConsoleNode -Depth 3 -Kind 'UpdateRelease' -Status 'Ok' `
            -Name $releaseId -Text $releaseText `
            -Icon (Get-HDTConsoleIcon -Kind 'UpdateRelease' -Status 'Ok') `
            -Field ([object[]] @($releaseField)) `
            -Command ("Get-HDTWindowsUpdate -WorkspaceRoot '{0}' -Release '{1}'" -f $Workspace.Root, $releaseId) `
            -Header $Header

        [void] $node.Add($releaseNode)
        [void] $updateCategory.Children.Add($releaseNode)

        foreach ($current in $inRelease) {

            $field = @(
                New-HDTConsoleField -Label 'KB' -Value $current.Kb
                New-HDTConsoleField -Label 'Id' -Value $current.Id

                # THE TWO AN ADMINISTRATOR OWNS, and the only two on this pane
                # that can be typed. Everything below came out of the package's
                # own CompDB metadata, and the id above is the folder name under
                # WindowsUpdates\ - so a box on either would be a box offering to
                # rewrite a measured fact or to move a directory.
                #
                # Nothing in a deployment matches on these: the ApplyUpdates step
                # selects by RELEASE, never by id or name, so a rename changes
                # what a technician reads and nothing about what gets applied.
                New-HDTConsoleField -Label 'Name' -Value $current.Name -Property 'name'
                New-HDTConsoleField -Label 'Description' -Value ([string] $current.Description) -Property 'description'

                New-HDTConsoleField -Label 'Release' -Value $current.Release
                # READ OUT OF THE PACKAGE, NOT OFF ITS NAME, which is the
                # difference between this catalog and one built by parsing file
                # names - and the reason the two packages below can be told apart
                # at all.
                New-HDTConsoleField -Label 'Kind' -Value $current.Kind
                New-HDTConsoleField -Label 'Architecture' -Value $current.Architecture
                New-HDTConsoleField -Label 'Applies to build' -Value ([string] $current.BaselineVersion)
                New-HDTConsoleField -Label 'Produces build' -Value ([string] $current.TargetVersion)
                New-HDTConsoleField -Label 'Bundled servicing stack' -Value ([string] $current.BundledSsuKb)
                New-HDTConsoleField -Label 'Package identity' -Value ([string] $current.PackageId)
                New-HDTConsoleField -Label 'Servicing branch' -Value ([string] $current.SourceBranch)
                New-HDTConsoleField -Label 'Package' -Value ([string] $current.FileName)
                New-HDTConsoleField -Label 'Size' -Value (Format-HDTConsoleByteCount -Byte ([long] $current.SizeBytes))
                New-HDTConsoleField -Label 'Built' -Value ([string] $current.CreatedUtc)
                New-HDTConsoleField -Label 'Imported' -Value ([string] $current.ImportedUtc)
                New-HDTConsoleField -Label 'Enabled' -Value (Get-HDTConsoleFlagText -Value $current.Enabled)
                New-HDTConsoleField -Label 'Note' -Value ([string] $current.Note)
                New-HDTConsoleField -Label 'Document' -Value ([string] $current.Path)
            )

            $text = '{0} - {1}' -f $current.Kb, $current.Name

            if ([string] $current.Status -eq 'Error') {
                $text = '{0} - (unreadable)' -f $current.Id
                $field = @(
                    New-HDTConsoleField -Label 'Id' -Value $current.Id
                    New-HDTConsoleField -Label 'Document' -Value ([string] $current.Path)
                    New-HDTConsoleField -Label 'Could not be read' -Value ([string] $current.Error)
                )
            }

            $updateItemRow = New-HDTConsoleNode -Depth 4 -Kind 'WindowsUpdate' -Status $current.Status `
                -Name $current.Id -Text $text `
                -Icon (Get-HDTConsoleIcon -Kind 'WindowsUpdate' -Status $current.Status) `
                -Field $field `
                -Command ("Get-HDTWindowsUpdate -WorkspaceRoot '{0}' -Id '{1}'" -f $Workspace.Root, $current.Id) `
                -Header $Header -Subject $current

            [void] $node.Add($updateItemRow)
            [void] $releaseNode.Children.Add($updateItemRow)
        }
    }

    return [pscustomobject[]] @($node)
}
