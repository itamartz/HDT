function Get-HDTConsoleApplicationNode {
    <#
        .SYNOPSIS
            The Applications category of one share, and every row under it.

        .DESCRIPTION
            Workbench's third category, and the one an administrator changes weekly.
            Its rows come from Get-HDTApplication - nothing here re-reads app.yaml -
            and the folders a document names become levels through
            Group-HDTConsoleFolderRow, which all three filed categories share.

            ONE CATEGORY, ONE BUILDER. Get-HDTConsoleShareNode composes a share out of
            these; what a row of each category says differs entirely, and the order
            they are composed in is the share's, not any one category's.

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
            Get-HDTConsoleApplicationNode -Workspace $workspace -Header $header
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

    # WORKBENCH'S THIRD CATEGORY, and the one an administrator changes weekly:
    # media is imported once, sequences are written once, and the application
    # list moves every time somebody ships a new version. The engine has had the
    # whole catalog since M7 - Import, Get, Set, detection, dependency order -
    # and none of it was on screen, so the part that changes most was the part
    # that could only be reached from a prompt.

    $appFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind Applications
    $appCommand = "Get-HDTApplication -WorkspaceRoot '{0}'" -f $Workspace.Root

    # NAMED, as the other two are: the window hangs New Application off this row
    # and must tell it from the rest without parsing a label somebody may
    # reword.
    $appCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'Applications' `
        -Text ('Applications ({0})' -f @($Workspace.Application).Count) `
        -Icon (Get-HDTConsoleIcon -Kind 'Application' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $appFolder
        New-HDTConsoleField -Label 'Applications' -Value @($Workspace.Application).Count
    ) `
        -Command $appCommand -Header $Header

    [void] $node.Add($appCategory)

    $appRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($application in @($Workspace.Application)) {

        # THE FOUR THAT CAN BE TYPED INTO, as on the other two rows: Workbench
        # edits name, comments and both command lines on an application's
        # Properties sheet. The id is not among them - it is the folder name and
        # what a sequence names to select it, so changing it is a move.
        $field = @(
            New-HDTConsoleField -Label 'Id' -Value $application.Id
            New-HDTConsoleField -Label 'Name' -Value $application.Name -Property 'name'
            # NO FALLBACK IN A BOX THAT WRITES, which is the rule the sequence
            # rows already follow: '(not recorded)' is for reading, and leaving
            # it in a box that writes app.yaml means an administrator adding a
            # publisher has to delete the words first - or, worse, tabs out and
            # writes the phrase into the document as the publisher.
            New-HDTConsoleField -Label 'Publisher' -Value ([string] $application.Publisher) -Property 'publisher'
            New-HDTConsoleField -Label 'Version' -Value ([string] $application.Version) -Property 'version'
            New-HDTConsoleField -Label 'Description' -Value ([string] $application.Description) -Property 'description'
            # WHERE THE COMMAND LINE RUNS, WHICH THE ROW CANNOT SHOW.
            # Invoke-HDTInstallApplicationsStep hands the line to cmd.exe with
            # the application's own source folder as the working directory, so a
            # bare 'setup.msi' resolves and %CD% is that folder.
            #
            # %~dp0 IS THE ONE EVERY ADMINISTRATOR REACHES FOR, and it is the
            # one that does not work: it expands only inside a .cmd file, and
            # there is no batch file here - the string IS the command. Typed
            # into this box it reaches msiexec as six literal characters and
            # comes back as 1619, "the installation package could not be
            # opened", naming a path that does not exist rather than the
            # mistake. That is a defect a technician cannot diagnose from the
            # error, which is exactly what a hint is for.
            New-HDTConsoleField -Label 'Install' -Value $application.Install -Property 'install' `
                -Hint 'Runs through cmd.exe from the application''s own folder, so %CD% is that folder and a bare file name resolves. %~dp0 expands only inside a .cmd file, not here.'
            New-HDTConsoleField -Label 'Uninstall' -Value ([string] $application.Uninstall) -Property 'uninstall' `
                -Hint 'Optional, and run exactly as Install is: cmd.exe, the application''s own folder, %CD% for it, no %~dp0. For an .msi: msiexec.exe /x {ProductCode} /qn /norestart.'
            New-HDTConsoleField -Label 'Runs in' -Value $application.RunIn

            # THE THREE THAT WERE A REPORT AND ARE NOW A FORM. Workbench edits
            # every one of them on an application's Properties sheet;
            # Set-HDTApplication has written all three since M7, and the pane
            # showed them as text nobody could correct - so the only way to fix
            # an exit code list was a prompt.
            #
            # NO FALLBACK TEXT IN A BOX THAT WRITES. '(nothing)' and '(none)'
            # are for reading, and tabbing out of a box holding one of them
            # would put the word into app.yaml as a dependency id. The empty
            # box IS the answer, and the ? beside it says what empty means.
            New-HDTConsoleField -Label 'Success codes' -Value ((@($application.SuccessCode) | ForEach-Object { [string] $_ }) -join ', ') -Property 'successCodes' `
                -Hint 'Exit codes that mean it worked, comma separated. Empty inherits 0 and 3010 - and 3010 is "installed, reboot required", not a failure.'
            New-HDTConsoleField -Label 'Reboot codes' -Value ((@($application.RebootCode) | ForEach-Object { [string] $_ }) -join ', ') -Property 'rebootCodes' `
                -Hint 'Exit codes that mean the machine owes a restart, comma separated. Empty inherits 3010; the sequence reboots and resumes at the next application.'
            New-HDTConsoleField -Label 'Detection' -Value $application.DetectText -Property 'detect' `
                -Hint 'The rule that decides it is already installed, written as app.yaml writes it: type: msiProduct, then the keys that type takes. Empty means it installs every time.'
            # SHOWN HERE, PICKED FROM THE MENU. This is the one of the four that
            # can be checked against something: an exit code and a detection
            # rule are knowledge about the package, and typing is the only way
            # to state them, but a dependency is an id that either is or is not
            # on this share. A misspelled one is not caught until a deployment
            # runs, when Resolve-HDTApplicationOrder refuses the WHOLE plan
            # rather than that one application - so the tree's Depends On item
            # offers what is there and refuses what would close a loop.
            New-HDTConsoleField -Label 'Depends on' -Value (@($application.Dependency) -join ', ') `
                -Hint 'Ids that must install first. Right-click this application and choose Depends On to change them: they are picked from what is on the share, so an id that does not exist cannot be written here.'
            New-HDTConsoleField -Label 'Source' -Value $application.SourcePath
            New-HDTConsoleField -Label 'Document' -Value $application.Path
        )

        # THE NAME, AND THE VERSION IF THE NAME DOES NOT ALREADY CARRY IT -
        # never 'id - name', which the other two categories use. See
        # Get-HDTConsoleApplicationLabel for why.
        #
        # THE ID IS ON THE ROW'S OWN PROPERTIES PANE, where it is needed by
        # whoever is writing a sequence that names it.
        #
        # ONE RULE, SHARED WITH THE EDITOR'S APPLICATION PAGE. A row somebody
        # ticks there has to read the same as the row they found here.
        $text = Get-HDTConsoleApplicationLabel -Name ([string] $application.Name) `
            -Version ([string] $application.Version) -Id ([string] $application.Id)

        if ($application.Status -eq 'Error') {
            $text = '{0} - (unreadable)' -f $application.Id
            $field = @(
                New-HDTConsoleField -Label 'Id' -Value $application.Id
                New-HDTConsoleField -Label 'Document' -Value $application.Path
                New-HDTConsoleField -Label 'Could not be read' -Value $application.Error
            )
        }

        $row = New-HDTConsoleNode -Depth 3 -Kind 'Application' -Status $application.Status `
            -Text $text -Field $field `
            -Name $application.Id `
            -Command ("Get-HDTApplication -WorkspaceRoot '{0}' -Id '{1}'" -f
                $Workspace.Root, $application.Id) `
            -Header $Header -Subject $application

        $row | Add-Member -MemberType NoteProperty -Name 'Folder' `
            -Value ([string] $application.Folder) -Force

        [void] $appRow.Add($row)
    }

    $appGrouped = Group-HDTConsoleFolderRow -Row ([object[]] @($appRow)) -Depth 3 `
        -Declared ([string[]] @($Workspace.Folder.Application)) -Category Application -Header $Header

    foreach ($current in @($appGrouped.Node)) { [void] $node.Add($current) }
    foreach ($current in @($appGrouped.TopLevel)) { [void] $appCategory.Children.Add($current) }

    if (@($Workspace.Application).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $appFolder
            New-HDTConsoleField -Label '' -Value 'There is no application on this share yet. Add one with Import-HDTApplication; it lands as a folder under the folder above with an app.yaml and a source\ payload in it.'
        ) `
            -Command $appCommand -Header $Header

        [void] $node.Add($row)
        [void] $appCategory.Children.Add($row)
    }

    return [pscustomobject[]] @($node)
}
