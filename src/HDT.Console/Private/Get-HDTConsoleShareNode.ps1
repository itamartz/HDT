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
        $detail = @(
            ('{0,-16}: {1}' -f 'Path', $Workspace.Root)
            ''
            'This deployment share could not be opened:'
            ''
            $Workspace.Error
        )

        [void] $node.Add((New-HDTConsoleNode -Depth 1 -Kind 'Share' -Status 'Error' `
                    -Text ('{0} - (could not be opened)' -f $Workspace.Root) `
                    -Detail ($detail -join [System.Environment]::NewLine) `
                    -Command ("Get-HDTConsoleWorkspace -Path '{0}'" -f $Workspace.Root) `
                    -Header $header))

        return [pscustomobject[]] @($node)
    }

    # -- the share ---------------------------------------------------------
    #
    # TWO SHAPES, ONE PASS. $node is the flat reading, in display order, and
    # every row is also added to its parent's Children so the window has a tree
    # to expand. Building them separately is how the two would come to disagree.

    $shareDetail = @(
        ('{0,-16}: {1}' -f 'Share', $Workspace.Name)
        ('{0,-16}: {1}' -f 'Id', $Workspace.Id)
        ('{0,-16}: {1}' -f 'Schema version', $Workspace.SchemaVersion)
        ''
        ('{0,-16}: {1}' -f 'Opened from', $Workspace.Root)
        ('{0,-16}: {1}' -f 'Deploy root', $Workspace.DeployRoot)
        ''
        ('{0,-16}: {1}' -f 'Log level', $Workspace.LogLevel)
        ('{0,-16}: {1}' -f 'Credential', (Get-HDTConsoleDisplayText -Text $Workspace.CredentialUser -Fallback '(none - the share is opened as the signed-in user)'))
        ('{0,-16}: {1}' -f 'Document', $Workspace.WorkspacePath)
    )

    $shareNode = New-HDTConsoleNode -Depth 1 -Kind 'Share' -Status 'Ok' `
        -Text ('{0} ({1})' -f $Workspace.Name, $Workspace.Id) `
        -Detail ($shareDetail -join [System.Environment]::NewLine) `
        -Command ("Get-HDTConsoleWorkspace -Path '{0}'" -f $Workspace.Root) `
        -Header $header

    [void] $node.Add($shareNode)

    # -- task sequences ----------------------------------------------------

    $sequenceFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind TaskSequences
    $sequenceCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind TaskSequences" -f $Workspace.Root

    $sequenceCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Text ('Task Sequences ({0})' -f @($Workspace.TaskSequence).Count) `
        -Detail (@(
            ('{0,-16}: {1}' -f 'Folder', $sequenceFolder)
            ('{0,-16}: {1}' -f 'Task Sequences', @($Workspace.TaskSequence).Count)
        ) -join [System.Environment]::NewLine) `
        -Command $sequenceCommand -Header $header

    [void] $node.Add($sequenceCategory)
    [void] $shareNode.Children.Add($sequenceCategory)

    foreach ($sequence in @($Workspace.TaskSequence)) {
        $detail = @(
            ('{0,-16}: {1}' -f 'Id', $sequence.Id)
            ('{0,-16}: {1}' -f 'Name', $sequence.Name)
            ('{0,-16}: {1}' -f 'Description', (Get-HDTConsoleDisplayText -Text $sequence.Description -Fallback '(none)'))
            ''
            ('{0,-16}: {1}' -f 'Steps', $sequence.StepCount)
            ('{0,-16}: {1}' -f 'Groups', $sequence.GroupCount)
            ('{0,-16}: {1}' -f 'Document', $sequence.Path)
        )

        $text = '{0} - {1}' -f $sequence.Id, $sequence.Name
        if ($sequence.Status -eq 'Error') {
            $text = '{0} - (unreadable)' -f $sequence.Id
            $detail = @(
                ('{0,-16}: {1}' -f 'Id', $sequence.Id)
                ('{0,-16}: {1}' -f 'Document', $sequence.Path)
                ''
                'This task sequence could not be read:'
                ''
                $sequence.Error
            )
        }

        $row = New-HDTConsoleNode -Depth 3 -Kind 'TaskSequence' -Status $sequence.Status `
            -Text $text -Detail ($detail -join [System.Environment]::NewLine) `
            -Command ("Import-HDTSequenceDocument -Path '{0}' -FileSystem (New-HDTFileSystem)" -f $sequence.Path) `
            -Header $header

        [void] $node.Add($row)
        [void] $sequenceCategory.Children.Add($row)
    }

    if (@($Workspace.TaskSequence).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Detail ("There is no task sequence on this share yet. A task sequence is a folder under {0} with a sequence.yaml in it (DESIGN 2.1)." -f $sequenceFolder) `
            -Command $sequenceCommand -Header $header

        [void] $node.Add($row)
        [void] $sequenceCategory.Children.Add($row)
    }

    # -- operating systems -------------------------------------------------

    $osFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind OperatingSystems
    $osCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind OperatingSystems" -f $Workspace.Root

    $osCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Text ('Operating Systems ({0})' -f @($Workspace.OperatingSystem).Count) `
        -Detail (@(
            ('{0,-16}: {1}' -f 'Folder', $osFolder)
            ('{0,-16}: {1}' -f 'Systems', @($Workspace.OperatingSystem).Count)
        ) -join [System.Environment]::NewLine) `
        -Command $osCommand -Header $header

    [void] $node.Add($osCategory)
    [void] $shareNode.Children.Add($osCategory)

    foreach ($operatingSystem in @($Workspace.OperatingSystem)) {
        $detail = @(
            ('{0,-16}: {1}' -f 'Id', $operatingSystem.Id)
            ('{0,-16}: {1}' -f 'Name', $operatingSystem.Name)
            ('{0,-16}: {1}' -f 'Type', $operatingSystem.Type)
            ('{0,-16}: {1}' -f 'Architecture', (Get-HDTConsoleDisplayText -Text $operatingSystem.Architecture -Fallback '(not recorded)'))
            ('{0,-16}: {1}' -f 'Default index', $operatingSystem.DefaultIndex)
            ''
            ('{0,-16}: {1}' -f 'Source path', $operatingSystem.SourcePath)
            ('{0,-16}: {1}' -f 'Image path', $operatingSystem.ImagePath)
            ('{0,-16}: {1}' -f 'Document', $operatingSystem.Path)
            ''
            ('Images ({0}):' -f $operatingSystem.ImageCount)
        )

        foreach ($image in @($operatingSystem.Image)) {
            $detail += '  {0,-3} {1} [{2}] {3}' -f $image.Index, $image.Name, $image.Edition, $image.Version
        }

        $text = '{0} - {1}' -f $operatingSystem.Id, $operatingSystem.Name
        if ($operatingSystem.Status -eq 'Error') {
            $text = '{0} - (unreadable)' -f $operatingSystem.Id
            $detail = @(
                ('{0,-16}: {1}' -f 'Id', $operatingSystem.Id)
                ('{0,-16}: {1}' -f 'Document', $operatingSystem.Path)
                ''
                'This operating system could not be read:'
                ''
                $operatingSystem.Error
            )
        }

        $row = New-HDTConsoleNode -Depth 3 -Kind 'OperatingSystem' -Status $operatingSystem.Status `
            -Text $text -Detail ($detail -join [System.Environment]::NewLine) `
            -Command ("Get-HDTOperatingSystem -WorkspaceRoot '{0}' -Id '{1}' -FileSystem (New-HDTFileSystem)" -f
                $Workspace.Root, $operatingSystem.Id) `
            -Header $header

        [void] $node.Add($row)
        [void] $osCategory.Children.Add($row)
    }

    if (@($Workspace.OperatingSystem).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Detail ("There is no operating system on this share yet. Import one with Import-HDTOperatingSystem; it lands as a folder under {0} with an os.yaml in it (DESIGN 9.3)." -f $osFolder) `
            -Command $osCommand -Header $header

        [void] $node.Add($row)
        [void] $osCategory.Children.Add($row)
    }

    # -- the boot image ----------------------------------------------------

    $bootFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind Boot

    $bootCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' -Text 'Boot Image' `
        -Detail (@(
            ('{0,-16}: {1}' -f 'Folder', $bootFolder)
            ('{0,-16}: {1}' -f 'Image name', $Workspace.BootImage.Name)
        ) -join [System.Environment]::NewLine) `
        -Command ("Get-HDTWorkspacePath -Root '{0}' -Kind Boot" -f $Workspace.Root) `
        -Header $header

    [void] $node.Add($bootCategory)
    [void] $shareNode.Children.Add($bootCategory)

    $bootNode = Get-HDTConsoleBootImageNode -BootImage $Workspace.BootImage -Workspace $Workspace -Header $header

    [void] $node.Add($bootNode)
    [void] $bootCategory.Children.Add($bootNode)

    return [pscustomobject[]] @($node)
}
