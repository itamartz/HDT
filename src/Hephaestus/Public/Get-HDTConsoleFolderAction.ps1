function Get-HDTConsoleFolderAction {
    <#
        .SYNOPSIS
            What the tree's right-click menu offers on one row, for folders.

        .DESCRIPTION
            THE DECISION, OUT OF THE CLICK HANDLER. Which of New Folder, Delete
            Folder and Move To offers itself is a fact about the row under the
            pointer, and a fact settled inside a Click handler cannot be tested.
            The window applies what this returns to three MenuItem.Visibility
            properties and nothing else.

            DELETE IS REFUSED WHILE ANYTHING IS IN IT, and that is not caution.
            A folder is a label on the documents (see Add-HDTWorkspaceFolder), so
            deleting the declaration while a sequence still says 'Clients' leaves
            the tree drawing 'Clients' from the sequence - a delete that appears
            to do nothing. The refusal says what is in it, because "empty it
            first" is the next thing to do.

            IT READS THE ROW AND NOTHING ELSE. Re-reading the share when the
            menu opens costs 400ms on the lab share - measured - in front of a
            menu that is meant to appear under the pointer, so the folders the
            tree draws and the category they belong to are stamped on every row
            when the tree is built. What is IN a folder is what is under it on
            screen, which is the same fact and free to count.

            ONE CATEGORY AT A TIME. 'Clients' under task sequences and 'Clients'
            under operating systems are different folders, so a sequence is never
            offered an operating system's folder.

        .PARAMETER Row
            The row under the pointer, or $null.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

              Category       which category the row belongs to, or ''
              CanCreate      New Folder applies
              Parent         the folder a new one would go inside, '' at the top
              CanDelete      Delete Folder applies
              DeleteRefusal  why it does not, when it does not
              CanMove        Move To Folder applies
              Choice         the folders it could be moved into

        .EXAMPLE
            $action = Get-HDTConsoleFolderAction -Row $tree.SelectedItem
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Row
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $nothing = [pscustomobject] @{
        Category      = ''
        CanCreate     = $false
        Parent        = ''
        CanDelete     = $false
        DeleteRefusal = ''
        CanMove       = $false
        Choice        = [string[]] @()
    }

    if ($null -eq $Row) { return $nothing }

    $kind = [string] $Row.Kind

    # The tree's category rows carry the name the share's property has, which is
    # what makes this one lookup rather than three comparisons.
    $categoryOf = @{
        TaskSequences    = 'TaskSequence'
        OperatingSystems = 'OperatingSystem'
    }

    $itemOf = @{
        TaskSequence    = 'TaskSequence'
        OperatingSystem = 'OperatingSystem'
    }

    $category = ''
    $onCategory = $false
    $onFolder = $false
    $onItem = $false

    if ($kind -eq 'Category') {
        $name = ''
        if ($null -ne $Row.PSObject.Properties['Name']) { $name = [string] $Row.Name }

        if ($categoryOf.ContainsKey($name)) {
            $category = [string] $categoryOf[$name]
            $onCategory = $true
        }
    } elseif ($kind -eq 'Folder') {
        if ($null -ne $Row.PSObject.Properties['FolderCategory']) {
            $category = [string] $Row.FolderCategory
            $onFolder = -not [string]::IsNullOrWhiteSpace($category)
        }
    } elseif ($itemOf.ContainsKey($kind)) {
        $category = [string] $itemOf[$kind]
        $onItem = $true
    }

    if (-not ($onCategory -or $onFolder -or $onItem)) { return $nothing }

    # THE FOLDERS THE TREE IS ALREADY DRAWING, stamped on the row by
    # Group-HDTConsoleFolderRow when it built them.
    $all = [string[]] @()
    if ($null -ne $Row.PSObject.Properties['FolderChoice']) { $all = [string[]] @($Row.FolderChoice) }

    $parent = ''
    if ($onFolder) { $parent = [string] $Row.FolderPath }

    $canDelete = $false
    $refusal = ''

    if ($onFolder) {
        # WHAT IS IN IT IS WHAT IS UNDER IT ON SCREEN - the rows filed there and
        # the folders inside it, which are the same node's children.
        $holding = @($Row.Children)

        if (@($holding).Count -eq 0) {
            $canDelete = $true
        } else {
            $plural = 's'
            if (@($holding).Count -eq 1) { $plural = '' }

            $refusal = ("'{0}' still has {1} item{2} in it. A folder is a label on the documents in it, so this would delete the label and leave the tree drawing the folder again from what is still filed there - move them out first." -f
                $parent, @($holding).Count, $plural)
        }
    }

    return [pscustomobject] @{
        Category      = $category
        CanCreate     = ($onCategory -or $onFolder)
        Parent        = $parent
        CanDelete     = $canDelete
        DeleteRefusal = $refusal
        CanMove       = $onItem
        Choice        = [string[]] @($all)
    }
}
