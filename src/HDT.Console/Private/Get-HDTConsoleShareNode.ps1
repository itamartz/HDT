function Get-HDTConsoleShareNode {
    <#
        .SYNOPSIS
            Builds the rows for one deployment share - the share itself and the
            three categories beneath it.

        .DESCRIPTION
            One share's subtree, so Get-HDTConsoleTreeNode can hold several of
            them without repeating any of this. The rows start at Depth 1
            because Depth 0 is the Deployment Shares root every share hangs off,
            the way Deployment Workbench roots them.

            A SHARE THAT WOULD NOT OPEN IS STILL A ROW. With one share, a bad
            path could reasonably throw; with four, throwing means three shares
            an administrator can see nothing of because of a fourth. So a
            failure is a row that says which path failed and why, and the other
            shares are unaffected.

        .PARAMETER Workspace
            A share from Get-HDTConsoleWorkspace, or a failure from
            New-HDTConsoleShareFailure.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - console nodes in
            display order.

        .EXAMPLE
            Get-HDTConsoleShareNode -Workspace (Get-HDTConsoleWorkspace -Path 'C:\HDTLab\Share')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Workspace
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $node = New-Object -TypeName System.Collections.ArrayList
    $header = Get-HDTConsoleHeader -Workspace $Workspace

    # -- a share that would not open ---------------------------------------

    if ($Workspace.Status -ne 'Ok') {
        $field = @(
            New-HDTConsoleField -Label 'Path' -Value $Workspace.Root
            New-HDTConsoleField -Label 'Could not be opened' -Value $Workspace.Error
        )

        [void] $node.Add((New-HDTConsoleNode -Depth 1 -Kind 'Share' -Status 'Error' `
                    -Text ('{0} - (could not be opened)' -f $Workspace.Root) `
                    -Field $field `
                    -Command ("Get-HDTConsoleWorkspace -Path '{0}'" -f $Workspace.Root) `
                    -Header $header))

        return [pscustomobject[]] @($node)
    }

    # -- the share ---------------------------------------------------------
    #
    # TWO SHAPES, ONE PASS. $node is the flat reading, in display order, and
    # every row is also added to its parent's Children so the window has a tree
    # to expand. Building them separately is how the two would come to disagree.

    $shareField = @(
        New-HDTConsoleField -Label 'Share' -Value $Workspace.Name
        New-HDTConsoleField -Label 'Id' -Value $Workspace.Id
        New-HDTConsoleField -Label 'Schema version' -Value $Workspace.SchemaVersion
        New-HDTConsoleField -Label 'Opened from' -Value $Workspace.Root
        New-HDTConsoleField -Label 'Deploy root' -Value $Workspace.DeployRoot
        New-HDTConsoleField -Label 'Log level' -Value $Workspace.LogLevel
        New-HDTConsoleField -Label 'Credential' -Value (Get-HDTConsoleDisplayText -Text $Workspace.CredentialUser -Fallback '(none - the share is opened as the signed-in user)')
        New-HDTConsoleField -Label 'Document' -Value $Workspace.WorkspacePath
    )

    $shareNode = New-HDTConsoleNode -Depth 1 -Kind 'Share' -Status 'Ok' `
        -Text ('{0} ({1})' -f $Workspace.Name, $Workspace.Id) `
        -Field $shareField `
        -Command ("Get-HDTConsoleWorkspace -Path '{0}'" -f $Workspace.Root) `
        -Header $header

    [void] $node.Add($shareNode)

    # -- task sequences ----------------------------------------------------

    $sequenceFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind TaskSequences
    $sequenceCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind TaskSequences" -f $Workspace.Root

    $sequenceCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Text ('Task Sequences ({0})' -f @($Workspace.TaskSequence).Count) `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $sequenceFolder
        New-HDTConsoleField -Label 'Task Sequences' -Value @($Workspace.TaskSequence).Count
    ) `
        -Command $sequenceCommand -Header $header

    [void] $node.Add($sequenceCategory)
    [void] $shareNode.Children.Add($sequenceCategory)

    foreach ($sequence in @($Workspace.TaskSequence)) {
        $field = @(
            New-HDTConsoleField -Label 'Id' -Value $sequence.Id
            New-HDTConsoleField -Label 'Name' -Value $sequence.Name
            New-HDTConsoleField -Label 'Description' -Value (Get-HDTConsoleDisplayText -Text $sequence.Description -Fallback '(none)')
            New-HDTConsoleField -Label 'Steps' -Value $sequence.StepCount
            New-HDTConsoleField -Label 'Groups' -Value $sequence.GroupCount
            New-HDTConsoleField -Label 'Document' -Value $sequence.Path
        )

        $text = '{0} - {1}' -f $sequence.Id, $sequence.Name
        if ($sequence.Status -eq 'Error') {
            $text = '{0} - (unreadable)' -f $sequence.Id
            $field = @(
                New-HDTConsoleField -Label 'Id' -Value $sequence.Id
                New-HDTConsoleField -Label 'Document' -Value $sequence.Path
                New-HDTConsoleField -Label 'Could not be read' -Value $sequence.Error
            )
        }

        $row = New-HDTConsoleNode -Depth 3 -Kind 'TaskSequence' -Status $sequence.Status `
            -Text $text -Field $field `
            -Command ("Import-HDTSequenceDocument -Path '{0}' -FileSystem (New-HDTFileSystem)" -f $sequence.Path) `
            -Header $header

        [void] $node.Add($row)
        [void] $sequenceCategory.Children.Add($row)
    }

    if (@($Workspace.TaskSequence).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $sequenceFolder
            New-HDTConsoleField -Label '' -Value 'There is no task sequence on this share yet. A task sequence is a folder under the folder above with a sequence.yaml in it (DESIGN 2.1).'
        ) `
            -Command $sequenceCommand -Header $header

        [void] $node.Add($row)
        [void] $sequenceCategory.Children.Add($row)
    }

    # -- operating systems -------------------------------------------------

    $osFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind OperatingSystems
    $osCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind OperatingSystems" -f $Workspace.Root

    $osCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Text ('Operating Systems ({0})' -f @($Workspace.OperatingSystem).Count) `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $osFolder
        New-HDTConsoleField -Label 'Operating Systems' -Value @($Workspace.OperatingSystem).Count
    ) `
        -Command $osCommand -Header $header

    [void] $node.Add($osCategory)
    [void] $shareNode.Children.Add($osCategory)

    foreach ($operatingSystem in @($Workspace.OperatingSystem)) {
        $image = foreach ($current in @($operatingSystem.Image)) {
            '{0,-3} {1} [{2}] {3}' -f $current.Index, $current.Name, $current.Edition, $current.Version
        }

        $field = @(
            New-HDTConsoleField -Label 'Id' -Value $operatingSystem.Id
            New-HDTConsoleField -Label 'Name' -Value $operatingSystem.Name
            New-HDTConsoleField -Label 'Type' -Value $operatingSystem.Type
            New-HDTConsoleField -Label 'Architecture' -Value (Get-HDTConsoleDisplayText -Text $operatingSystem.Architecture -Fallback '(not recorded)')
            New-HDTConsoleField -Label 'Default index' -Value $operatingSystem.DefaultIndex
            New-HDTConsoleField -Label ('Images ({0})' -f $operatingSystem.ImageCount) -Value (@($image) -join [System.Environment]::NewLine)
            New-HDTConsoleField -Label 'Source path' -Value $operatingSystem.SourcePath
            New-HDTConsoleField -Label 'Image path' -Value $operatingSystem.ImagePath
            New-HDTConsoleField -Label 'Document' -Value $operatingSystem.Path
        )

        $text = '{0} - {1}' -f $operatingSystem.Id, $operatingSystem.Name
        if ($operatingSystem.Status -eq 'Error') {
            $text = '{0} - (unreadable)' -f $operatingSystem.Id
            $field = @(
                New-HDTConsoleField -Label 'Id' -Value $operatingSystem.Id
                New-HDTConsoleField -Label 'Document' -Value $operatingSystem.Path
                New-HDTConsoleField -Label 'Could not be read' -Value $operatingSystem.Error
            )
        }

        $row = New-HDTConsoleNode -Depth 3 -Kind 'OperatingSystem' -Status $operatingSystem.Status `
            -Text $text -Field $field `
            -Command ("Get-HDTOperatingSystem -WorkspaceRoot '{0}' -Id '{1}' -FileSystem (New-HDTFileSystem)" -f
                $Workspace.Root, $operatingSystem.Id) `
            -Header $header

        [void] $node.Add($row)
        [void] $osCategory.Children.Add($row)
    }

    if (@($Workspace.OperatingSystem).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $osFolder
            New-HDTConsoleField -Label '' -Value 'There is no operating system on this share yet. Import one with Import-HDTOperatingSystem; it lands as a folder under the folder above with an os.yaml in it (DESIGN 9.3).'
        ) `
            -Command $osCommand -Header $header

        [void] $node.Add($row)
        [void] $osCategory.Children.Add($row)
    }

    # -- the boot image ----------------------------------------------------

    $bootFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind Boot

    $bootCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' -Text 'Boot Image' `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $bootFolder
        New-HDTConsoleField -Label 'Image name' -Value $Workspace.BootImage.Name
    ) `
        -Command ("Get-HDTWorkspacePath -Root '{0}' -Kind Boot" -f $Workspace.Root) `
        -Header $header

    [void] $node.Add($bootCategory)
    [void] $shareNode.Children.Add($bootCategory)

    $bootNode = Get-HDTConsoleBootImageNode -BootImage $Workspace.BootImage -Workspace $Workspace -Header $header

    [void] $node.Add($bootNode)
    [void] $bootCategory.Children.Add($bootNode)

    return [pscustomobject[]] @($node)
}
