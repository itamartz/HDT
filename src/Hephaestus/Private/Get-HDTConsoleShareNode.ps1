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

    # THE THREE THIS ROW SETS, and they arrived here from the Windows PE
    # window's Bootstrap tab: a share's name, where clients reach it and how
    # much it logs are the SHARE's settings, and that tab's subject is the rules
    # file. The id and the schema version are fixed at creation; 'Opened from'
    # is where this console found it.
    #
    # THE CREDENTIAL IS NOT AMONG THEM. Setting it writes two things - a line in
    # workspace.yaml and a protected file beside it - so a box writing one would
    # leave a share declaring an account no secret exists for, which is a build
    # that refuses. Set-HDTShareCredential does both.
    $shareField = @(
        New-HDTConsoleField -Label 'Share' -Value $Workspace.Name -Property 'name'
        New-HDTConsoleField -Label 'Id' -Value $Workspace.Id
        New-HDTConsoleField -Label 'Schema version' -Value $Workspace.SchemaVersion
        New-HDTConsoleField -Label 'Opened from' -Value $Workspace.Root
        New-HDTConsoleField -Label 'Deploy root' -Value $Workspace.DeployRoot -Property 'deployRoot'
        New-HDTConsoleField -Label 'Log level' -Value $Workspace.LogLevel -Property 'logLevel'
        New-HDTConsoleField -Label 'Credential' -Value (Get-HDTConsoleDisplayText -Text $Workspace.CredentialUser -Fallback '(none - the share is opened as the signed-in user)')
        New-HDTConsoleField -Label 'Document' -Value $Workspace.WorkspacePath
    )

    $shareNode = New-HDTConsoleNode -Depth 1 -Kind 'Share' -Status 'Ok' `
        -Text ('{0} ({1})' -f $Workspace.Name, $Workspace.Id) `
        -Field $shareField `
        -Command ("Get-HDTConsoleWorkspace -Path '{0}'" -f $Workspace.Root) `
        -Header $header -Subject $Workspace

    [void] $node.Add($shareNode)

    # THE CATEGORY ORDER IS THE ORDER A SHARE IS BUILT IN, and it is not
    # Workbench's alphabetical-ish one: boot image, operating systems, drivers,
    # then task sequences. A share is useless until it has an image that boots
    # and an OS to lay down; drivers make that OS work on the hardware in front
    # of you; the task sequence is what finally ties them together, and it is
    # the thing that can only be written once the other three exist. Reading top
    # to bottom is reading the order the work happens in.
    #
    # MONITORING COMES LAST, AFTER ALL OF IT, for the same reason: it is what
    # happens once the share has been built, not another thing to build. The
    # four categories above are a share's contents; this one is the share in
    # use.

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

    # -- applications ------------------------------------------------------
    #
    # WORKBENCH'S THIRD CATEGORY, and the one an administrator changes weekly:
    # media is imported once, sequences are written once, and the application
    # list moves every time somebody ships a new version. The engine has had the
    # whole catalog since M7 - Import, Get, Set, detection, dependency order -
    # and none of it was on screen, so the part that changes most was the part
    # that could only be reached from a prompt.

    $appFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind Applications
    $appCommand = "Get-HDTApplication -WorkspaceRoot '{0}' -FileSystem (New-HDTFileSystem)" -f $Workspace.Root

    # NAMED, as the other two are: the window hangs New Application off this row
    # and must tell it from the rest without parsing a label somebody may
    # reword.
    $appCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'Applications' `
        -Text ('Applications ({0})' -f @($Workspace.Application).Count) `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $appFolder
        New-HDTConsoleField -Label 'Applications' -Value @($Workspace.Application).Count
    ) `
        -Command $appCommand -Header $header

    [void] $node.Add($appCategory)
    [void] $shareNode.Children.Add($appCategory)

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
            New-HDTConsoleField -Label 'Depends on' -Value (@($application.Dependency) -join ', ') -Property 'dependencies' `
                -Hint 'Ids that must install first, comma separated. Selecting this application selects them too, and they install ahead of it.'
            New-HDTConsoleField -Label 'Source' -Value $application.SourcePath
            New-HDTConsoleField -Label 'Document' -Value $application.Path
        )

        # THE NAME, AND THE VERSION IF THE NAME DOES NOT ALREADY CARRY IT.
        #
        # NOT 'id - name', WHICH THE OTHER TWO CATEGORIES USE. An application's
        # id is composed FROM its name and version (Get-HDTApplicationName), so
        # a row showing both reads 'Igor-Pavlov-7-Zip-24.09 - Igor Pavlov 7-Zip
        # 24.09': the same sentence twice, once with the spaces hyphenated. The
        # id is on the row's own properties pane, where it is needed by whoever
        # is writing a sequence that names it.
        #
        # AND THE VERSION IS WHAT MAKES TWO ENTRIES TELLABLE APART, so an entry
        # whose name is just 'Acrobat Reader' gets it appended - and one whose
        # name already ends with it does not say it twice.
        $text = [string] $application.Name
        $stated = [string] $application.Version

        if (-not [string]::IsNullOrWhiteSpace($stated) -and $text -notmatch [regex]::Escape($stated)) {
            $text = '{0} {1}' -f $text, $stated
        }

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
            -Command ("Get-HDTApplication -WorkspaceRoot '{0}' -Id '{1}' -FileSystem (New-HDTFileSystem)" -f
                $Workspace.Root, $application.Id) `
            -Header $header -Subject $application

        $row | Add-Member -MemberType NoteProperty -Name 'Folder' `
            -Value ([string] $application.Folder) -Force

        [void] $appRow.Add($row)
    }

    $appGrouped = Group-HDTConsoleFolderRow -Row ([object[]] @($appRow)) -Depth 3 `
        -Declared ([string[]] @($Workspace.Folder.Application)) -Category Application -Header $header

    foreach ($current in @($appGrouped.Node)) { [void] $node.Add($current) }
    foreach ($current in @($appGrouped.TopLevel)) { [void] $appCategory.Children.Add($current) }

    if (@($Workspace.Application).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $appFolder
            New-HDTConsoleField -Label '' -Value 'There is no application on this share yet. Add one with Import-HDTApplication; it lands as a folder under the folder above with an app.yaml and a source\ payload in it.'
        ) `
            -Command $appCommand -Header $header

        [void] $node.Add($row)
        [void] $appCategory.Children.Add($row)
    }

    # -- operating systems -------------------------------------------------

    $osFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind OperatingSystems
    $osCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind OperatingSystems" -f $Workspace.Root

    # NAMED, NOT JUST LABELLED, for the same reason TaskSequences is: the window
    # hangs Import Operating System off this row and must be able to tell it
    # from the other three categories without parsing a label somebody may
    # reword.
    $osCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'OperatingSystems' `
        -Text ('Operating Systems ({0})' -f @($Workspace.OperatingSystem).Count) `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $osFolder
        New-HDTConsoleField -Label 'Operating Systems' -Value @($Workspace.OperatingSystem).Count
    ) `
        -Command $osCommand -Header $header

    [void] $node.Add($osCategory)
    [void] $shareNode.Children.Add($osCategory)

    $osRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($operatingSystem in @($Workspace.OperatingSystem)) {
        $image = foreach ($current in @($operatingSystem.Image)) {
            '{0,-3} {1} [{2}] {3}' -f $current.Index, $current.Name, $current.Edition, $current.Version
        }

        # THE TWO THAT CAN BE TYPED INTO, as on a task sequence: Workbench edits
        # both on an imported OS's Properties sheet, and everything below them
        # is a reading of the media rather than a decision anybody made. The id
        # is not among them - it is the folder name and what a sequence names to
        # select the image, so changing it is a move.
        $field = @(
            New-HDTConsoleField -Label 'Id' -Value $operatingSystem.Id
            New-HDTConsoleField -Label 'Name' -Value $operatingSystem.Name -Property 'name'
            New-HDTConsoleField -Label 'Description' -Value ([string] $operatingSystem.Description) -Property 'description'
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
            -Header $header -Subject $operatingSystem

        # THE FOLDER THE DOCUMENT NAMED, carried on the row so the grouping
        # below can read it without going back to the document.
        $row | Add-Member -MemberType NoteProperty -Name 'Folder' `
            -Value ([string] $operatingSystem.Folder) -Force

        [void] $osRow.Add($row)
    }

    $osGrouped = Group-HDTConsoleFolderRow -Row ([object[]] @($osRow)) -Depth 3 `
        -Declared ([string[]] @($Workspace.Folder.OperatingSystem)) -Category OperatingSystem -Header $header

    foreach ($current in @($osGrouped.Node)) { [void] $node.Add($current) }
    foreach ($current in @($osGrouped.TopLevel)) { [void] $osCategory.Children.Add($current) }

    if (@($Workspace.OperatingSystem).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $osFolder
            New-HDTConsoleField -Label '' -Value 'There is no operating system on this share yet. Import one with Import-HDTOperatingSystem; it lands as a folder under the folder above with an os.yaml in it.'
        ) `
            -Command $osCommand -Header $header

        [void] $node.Add($row)
        [void] $osCategory.Children.Add($row)
    }

    # -- drivers -----------------------------------------------------------
    #
    # THE FOLDER, AND AN HONEST SENTENCE ABOUT THE REST. DESIGN 7 describes a
    # driver store and the engine has not built one - there is no Get-HDTDriver
    # and no driver schema. The category is here because this is where it
    # belongs in the order, and because an administrator looking for drivers
    # should find out they are not supported yet from the console rather than
    # from a deployment that silently installs none.

    $driverCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind Drivers" -f $Workspace.Root

    $driverCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' -Text 'Drivers' `
        -Icon (Get-HDTConsoleIcon -Kind 'DriverStore' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $Workspace.Driver.Folder
        New-HDTConsoleField -Label 'Folder exists' -Value (Get-HDTConsoleFlagText -Value $Workspace.Driver.Present)
    ) `
        -Command $driverCommand -Header $header

    [void] $node.Add($driverCategory)
    [void] $shareNode.Children.Add($driverCategory)

    $driverRow = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(not supported yet)' `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $Workspace.Driver.Folder
        New-HDTConsoleField -Label 'Folder exists' -Value (Get-HDTConsoleFlagText -Value $Workspace.Driver.Present)
        New-HDTConsoleField -Label '' -Value ('The engine has no driver catalog yet: there is no command that reads this folder and no step that injects from it, so nothing here would reach a deployed machine. The console will list it as soon as the engine can read it.')
    ) `
        -Command $driverCommand -Header $header

    [void] $node.Add($driverRow)
    [void] $driverCategory.Children.Add($driverRow)

    # -- task sequences ----------------------------------------------------

    $sequenceFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind TaskSequences
    $sequenceCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind TaskSequences" -f $Workspace.Root

    # NAMED, NOT JUST LABELLED. The text carries a count - 'Task Sequences (5)' -
    # and the window has to be able to tell this row from the other three
    # categories to hang New Task Sequence off it. Matching on a label would put
    # a parser in the window and break the day somebody rewords it.
    $sequenceCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'TaskSequences' `
        -Text ('Task Sequences ({0})' -f @($Workspace.TaskSequence).Count) `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $sequenceFolder
        New-HDTConsoleField -Label 'Task Sequences' -Value @($Workspace.TaskSequence).Count
    ) `
        -Command $sequenceCommand -Header $header

    [void] $node.Add($sequenceCategory)
    [void] $shareNode.Children.Add($sequenceCategory)

    $sequenceRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($sequence in @($Workspace.TaskSequence)) {
        # DESIGN 12'S "VALIDATION, SURFACED INLINE". Test-HDTTaskSequence answers
        # what a schema cannot - would this sequence actually work on the machine
        # you are about to deploy - and Get-HDTConsoleWorkspace has already asked
        # it. This puts the answer where somebody will see it before they boot a
        # machine rather than after.
        $lint = Get-HDTConsoleLintText -Finding $sequence.Finding

        # THE TWO THAT CAN BE TYPED INTO, and they are typed into HERE rather
        # than in a window that has to be opened first: renaming a sequence is
        # the commonest edit there is, and Workbench asks for a properties
        # dialog to do it. The id is not among them - it is the folder name, so
        # changing it is a move rather than an edit.
        #
        # NO '(none)' ON THE DESCRIPTION: the fallback is for reading, and a box
        # somebody tabs out of writes what is in it. The empty box says the same
        # thing and writes nothing.
        $field = @(
            New-HDTConsoleField -Label 'Id' -Value $sequence.Id
            New-HDTConsoleField -Label 'Name' -Value $sequence.Name -Property 'name'
            New-HDTConsoleField -Label 'Description' -Value ([string] $sequence.Description) -Property 'description'
            New-HDTConsoleField -Label 'Steps' -Value $sequence.StepCount
            New-HDTConsoleField -Label 'Groups' -Value $sequence.GroupCount
            New-HDTConsoleField -Label 'Validation' -Value $lint.Detail
            New-HDTConsoleField -Label 'Document' -Value $sequence.Path
        )

        $text = '{0} - {1}' -f $sequence.Id, $sequence.Name

        # THE COUNT GOES ON THE ROW. A tree of thirty sequences is scanned, not
        # read: the row has to say "this one" without being opened, and the pane
        # is for somebody who has already decided to look.
        $sequenceStatus = $sequence.Status

        if ($sequence.Status -eq 'Ok' -and -not [string]::IsNullOrEmpty($lint.Caption)) {
            $text = '{0} - {1}  ({2})' -f $sequence.Id, $sequence.Name, $lint.Caption
            $sequenceStatus = $lint.Status
        }

        if ($sequence.Status -eq 'Error') {
            $text = '{0} - (unreadable)' -f $sequence.Id
            $field = @(
                New-HDTConsoleField -Label 'Id' -Value $sequence.Id
                New-HDTConsoleField -Label 'Document' -Value $sequence.Path
                New-HDTConsoleField -Label 'Could not be read' -Value $sequence.Error
            )
        }

        # THE ID IS THE NAME, and Text is only the label. Name falls back to Text
        # when it is not given, so the tree's Remove was handed
        # 'DEMO-M4 - Deploy Windows 11 LTSC' as an id and refused it for having
        # spaces - a row that would not go, for a reason that appeared in the
        # command box rather than anywhere near the row. It is also what survives
        # somebody rewording the label.
        $row = New-HDTConsoleNode -Depth 3 -Kind 'TaskSequence' -Status $sequenceStatus `
            -Name ([string] $sequence.Id) `
            -Text $text -Field $field `
            -Command ("Import-HDTSequenceDocument -Path '{0}' -FileSystem (New-HDTFileSystem)" -f $sequence.Path) `
            -Header $header -Subject $sequence

        # THE BROWSER STOPS HERE, and the steps are Get-HDTConsoleSequenceEditor's.
        # Deployment Workbench lists task sequences in the tree and edits their
        # steps in a properties window opened from one; CLAUDE.md asks for a
        # console close enough to it that muscle memory transfers. Expanding
        # every step of every sequence of every share would also be unusable at
        # the size an administrator runs - the lab's own sample share is four
        # sequences and over thirty step rows before a single operating system.
        $row | Add-Member -MemberType NoteProperty -Name 'Folder' `
            -Value ([string] $sequence.Folder) -Force

        [void] $sequenceRow.Add($row)
    }

    $sequenceGrouped = Group-HDTConsoleFolderRow -Row ([object[]] @($sequenceRow)) -Depth 3 `
        -Declared ([string[]] @($Workspace.Folder.TaskSequence)) -Category TaskSequence -Header $header

    foreach ($current in @($sequenceGrouped.Node)) { [void] $node.Add($current) }
    foreach ($current in @($sequenceGrouped.TopLevel)) { [void] $sequenceCategory.Children.Add($current) }

    if (@($Workspace.TaskSequence).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $sequenceFolder
            New-HDTConsoleField -Label '' -Value 'There is no task sequence on this share yet. A task sequence is a folder under the folder above with a sequence.yaml in it.'
        ) `
            -Command $sequenceCommand -Header $header

        [void] $node.Add($row)
        [void] $sequenceCategory.Children.Add($row)
    }

    # -- monitoring --------------------------------------------------------
    #
    # DESIGN 12 lists it among the tree's categories, so an administrator looking
    # for what is running finds it where they find everything else about the
    # share rather than having to know a command exists. It comes LAST because it
    # is the share in use rather than another thing to build.
    #
    # THE WHOLE SUBTREE IS Get-HDTConsoleMonitorNode'S, and that is not tidiness:
    # the console rebuilds this branch on a timer while the window is open
    # (ROADMAP M8, "tailing"), and the tree as first drawn has to be the same
    # shape as the tree as refreshed. One builder, called from both, is the only
    # arrangement in which they cannot drift.

    $monitorCategory = Get-HDTConsoleMonitorNode -Path $Workspace.Root -Header $header `
        -Monitor $Workspace.Monitor

    [void] $node.Add($monitorCategory)
    [void] $shareNode.Children.Add($monitorCategory)

    # The flat reading gets the run rows too - it is every row in display order,
    # and a caller counting them must not find the branch missing from it.
    foreach ($current in @($monitorCategory.Children)) {
        [void] $node.Add($current)
    }

    return [pscustomobject[]] @($node)
}
