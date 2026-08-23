function Get-HDTConsoleTreeNode {
    <#
        .SYNOPSIS
            Turns one or more console workspaces into the ordered rows the
            console window displays.

        .DESCRIPTION
            EVERYTHING THAT REACHES THE SCREEN IS DECIDED HERE. The window is
            loaded by XamlReader and driven by an injected IConsoleHost that adds
            these rows to a list and shows the selected row's detail; the host
            makes no decisions and formats nothing, which is what leaves it
            branch-free and honestly exempt from TDD. If the
            host built the rows, the only thing that could ever check the
            console's output would be a person looking at a screen.

            SEVERAL SHARES, UNDER ONE ROOT. An administrator works on more than
            one deployment share - a lab share and a production share, or one per
            site - so the tree is rooted at 'Deployment Shares' and every share
            hangs off it, exactly as Deployment Workbench roots them. The root is
            there with one share as well as with six: a console whose shape
            changes depending on how many shares are open is a console whose
            screenshots cannot be compared, and it makes "where do I add the next
            one" a question rather than a place.

            THE ORDER IS DEPLOYMENT WORKBENCH'S, deliberately: each share, then
            Task Sequences, Operating Systems and the Boot Image beneath it
            ("deliberately close to Deployment Workbench so muscle
            memory transfers"). Depth carries the nesting and Display carries the
            indentation already applied, so a flat ListBox in a monospaced font
            reads as a tree without a converter, a TreeView, or a line of XAML
            that has to be right first time in a window nobody can unit test.

            EVERY ROW CARRIES THE COMMAND THAT PRODUCED IT: "the
            console may not do anything the cmdlets can't. Every action it
            performs maps to a cmdlet invocation, and the console shows that
            invocation - so an admin can learn the automation surface by clicking
            around, and script anything they can do in the UI." Command is that
            invocation, spelled the way it would be typed.

            EVERY ROW ALSO CARRIES ITS SHARE'S BANNER, so the window can name the
            share a selected row belongs to without the host working out which
            share that was.

            NUMBERS AND DATES ARE FORMATTED INVARIANTLY. A build time rendered in
            the viewer's zone means two administrators reading the same share
            disagree about when the image was built, and a size grouped by the
            viewer's culture means a screenshot cannot be compared to a test.
            The manifest records UTC; the console shows UTC and says so.

            A ROW IS NEVER HIDDEN BECAUSE IT IS BROKEN. An item whose document
            would not parse appears with Status 'Error' and the engine's message
            in its detail; so does a whole share that would not open. An empty
            category says '(none)' rather than showing nothing, because an empty
            list and a list that failed to load look identical on a screen.

        .PARAMETER Workspace
            One or more shares from Get-HDTConsoleWorkspace, in the order they
            should appear.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[], in display order:

              Depth    0 the root, 1 a share, 2 a category, 3 an item
              Kind     Root, Share, Category, TaskSequence, OperatingSystem,
                       BootImage or Empty
              Status   Ok, Error or Missing
              Text     the row, without indentation
              Display  the row as the list shows it, indented by Depth
              Detail   the multi-line text the detail pane shows
              Command  the module command that produced the row
              HeaderTitle, HeaderRoot, HeaderDeployRoot
                       what the banner says while the row is selected

        .EXAMPLE
            Get-HDTConsoleTreeNode -Workspace (Get-HDTConsoleWorkspace -Path 'C:\HDTLab\Share') |
                Format-Table Depth, Kind, Text

            The whole window, on a console, with no window.

        .EXAMPLE
            $share = 'C:\HDTLab\Share', '\\192.168.2.108\HDTShare' |
                ForEach-Object { Get-HDTConsoleWorkspace -Path $_ }
            Get-HDTConsoleTreeNode -Workspace $share

            Two shares in one tree.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object[]] $Workspace
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $share = @($Workspace)
    $node = New-Object -TypeName System.Collections.ArrayList

    # The root row is the window, not one share, so it names the command that
    # opened it - and, unlike what stood here, one an administrator can run.
    $rootCommand = "Show-HDTConsole -Path '{0}'" -f (@($share | ForEach-Object { $_.Root }) -join "', '")

    $listed = foreach ($current in $share) {
        '{0,-8} {1}' -f $current.Status, $current.Root
    }

    $rootField = @(
        New-HDTConsoleField -Label 'Shares' -Value $share.Count
        New-HDTConsoleField -Label 'Opened' -Value (@($listed) -join [System.Environment]::NewLine)
    )

    $rootNode = New-HDTConsoleNode -Depth 0 -Kind 'Root' -Status 'Ok' `
        -Text ('Deployment Shares ({0})' -f $share.Count) `
        -Field $rootField `
        -Command $rootCommand `
        -Header ([pscustomobject] @{
                Title      = 'Deployment Shares'
                Root       = '(select a share)'
                DeployRoot = '(select a share)'
            })

    [void] $node.Add($rootNode)

    foreach ($current in $share) {
        $subtree = @(Get-HDTConsoleShareNode -Workspace $current)

        # The share's own row is first, by construction, and everything after it
        # is already nested underneath it.
        [void] $rootNode.Children.Add($subtree[0])

        foreach ($row in $subtree) {
            [void] $node.Add($row)
        }
    }

    return [pscustomobject[]] @($node)
}
