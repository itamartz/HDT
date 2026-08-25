function Get-HDTConsoleWorkspace {
    <#
        .SYNOPSIS
            Reads a deployment share and returns everything the admin console
            shows about it.

        .DESCRIPTION
            The backend half of the console,
            and the whole of what the window knows. The rule is that the
            console may not do anything the cmdlets can't, so this reads the
            share through the SAME commands an administrator would type:

              Import-HDTWorkspaceDocument   the share identity and its deployRoot
              Get-HDTWorkspacePath          where each catalog folder is
              Import-HDTSequenceDocument    one task sequence
              Get-HDTOperatingSystem        one operating system

            Nothing here re-parses YAML the engine already parses, and nothing
            here knows a folder name the engine does not know. A console that
            grew its own reader would be a second opinion about what is on the
            share, and the deployment's opinion is the one that matters.

            THE PATH IT WAS OPENED THROUGH AND THE deployRoot IT DECLARES ARE
            BOTH REPORTED, AND THEY ARE NOT THE SAME FACT. The lab share is
            C:\HDTLab\Share to the administrator sitting at the host and
            \\192.168.2.108\HDTShare to a machine that booted the image; the
            boot image carries the second. Showing only one of them is how an
            admin edits a share that no client can reach and cannot see why.

            ONE UNREADABLE DOCUMENT DOES NOT EMPTY THE CONSOLE. A sequence whose
            YAML does not parse, or an os.yaml that fails validation, becomes a
            row with Status 'Error' carrying the engine's own message - the file
            and the line included, because that is what the engine's error says.
            Deployment Workbench shows the broken item and complains about it;
            throwing instead would show an administrator nothing at all on
            exactly the day something on their share is broken. THE ROOT
            workspace.yaml IS THE ONE EXCEPTION: without it there is no share to
            show, so that failure is terminating and names the file.

            THE BOOT IMAGE COMES FROM THE MANIFEST, NOT FROM THE ARTIFACTS.
            Update-HDTBootImage writes Boot\<name>.manifest.json beside the .wim
            and the .iso, and it records the build date, the machine, the engine
            version and the SHA-256 of both artifacts. Reading it is how the
            console can state the ISO claim - that the WIM inside the ISO
            hashes equal to the standalone WIM - instead of hashing 500 MB twice
            to re-derive it. A share whose image has never been built says so and
            names Update-HDTBootImage, rather than showing an image with empty
            hashes.

        .PARAMETER Path
            The deployment share to open - a local path or a UNC share. The
            console only ever reads it.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter by default, New-HDTFakeFileSystem
            in a test.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Root, WorkspacePath, SchemaVersion, Id, Name, DeployRoot,
              LogLevel, CredentialUser, Status, Error
              TaskSequence    [pscustomobject[]] Id, Name, Description,
                              StepCount, GroupCount, Step, Group, Variable, Path,
                              Status, Error. Step is the engine's flat ordered
                              step list, each carrying its GroupPath; Group is
                              the group list. Both are empty when Status is
                              'Error'.
              OperatingSystem [pscustomobject[]] Id, Name, Description, Type,
                              Architecture, DefaultIndex, ImageCount, Image,
                              SourcePath, ImagePath, Path, Status, Error
              Driver          Folder, Present - the folder only; the engine has
                              no driver catalog to read
              BootImage       Name, Architecture, Language, ManifestPath,
                              Status ('Ok', 'Missing' or 'Error'), Error,
                              BuildId, BuiltUtc, BuiltOn, EngineVersion,
                              WimPath, WimSha256, WimSizeBytes,
                              IsoPath, IsoSha256, IsoSizeBytes,
                              IsoBootWimSha256, HashMatch

        .EXAMPLE
            Get-HDTConsoleWorkspace -Path 'C:\HDTLab\Share'

            What the console calls when it opens a share.

        .EXAMPLE
            (Get-HDTConsoleWorkspace -Path '\\192.168.2.108\HDTShare').TaskSequence |
                Format-Table Id, Name, StepCount, Status

            The same answer without a window - the console shows nothing the
            command line cannot.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        # THE MONITOR NEEDS ONE, AND IT COMES IN HERE so a share can be opened
        # at a known instant. "How long since this deployment said anything" is
        # the only thing on this screen that changes without anything being
        # written, and a share read against the real wall clock could only be
        # tested by sleeping.
        [Parameter()]
        [AllowNull()]
        [object] $Clock
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Clock) { $Clock = New-HDTClock }

    # A trailing separator would put a doubled one in every path built below and
    # in every path shown on screen. 'C:\' is three characters and its separator
    # is part of the root.
    $root = $Path
    if ($root.Length -gt 3) {
        $root = $root.TrimEnd('\', '/')
    }

    $workspacePath = [System.IO.Path]::Combine($root, 'workspace.yaml')

    if (-not $FileSystem.TestPath($workspacePath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $workspacePath `
                    -Category ObjectNotFound `
                    -Message ("there is no workspace document here, so '{0}' is not a deployment share. A share declares its identity and its deployRoot in workspace.yaml at its root." -f $root)))
    }

    # Deliberately NOT wrapped: a workspace.yaml that does not parse is a share
    # that cannot be shown at all, and the engine's error already names the file
    # and the line.
    $workspace = Import-HDTWorkspaceDocument -Path $workspacePath -FileSystem $FileSystem

    $credentialUser = ''
    if ($null -ne $workspace.Credential) {
        $credentialUser = [string] $workspace.Credential.Username
    }

    # -- task sequences ----------------------------------------------------

    $sequenceRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($entry in @(Get-HDTConsoleCatalogEntry -Root $root -Kind TaskSequences `
                -DocumentName 'sequence.yaml' -FileSystem $FileSystem)) {

        # Step and Group carry the ENGINE'S OWN resolution of the document -
        # a flat, ordered step list where each step knows its GroupPath. The
        # console renders that; it does not re-parse the YAML and does not
        # decide an order of its own, so what the tree shows is what
        # Invoke-HDTTaskSequence would run.
        $row = [pscustomobject] @{
            Id          = $entry.Id
            Name        = $entry.Id
            Version     = ''
            Description = ''
            StepCount   = 0
            GroupCount  = 0
            Step        = @()
            Group       = @()

            # WHAT THE NEW SEQUENCE WINDOW WROTE, and what its editor's
            # Variables tab shows: the block an author is expected to change.
            # Empty rather than absent, so a window may read it without asking
            # whether the document declared one.
            Variable    = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            # WHICH FOLDER THE TREE DRAWS IT UNDER. '' rather than absent: the
            # key is optional and most documents do not carry it, so every
            # reader would otherwise need a guard.
            Folder      = ''
            Path        = $entry.DocumentPath
            Status      = 'Ok'
            Error       = ''

            # WHAT THE LINT SAID, carried here so nothing downstream runs it
            # again. Test-HDTTaskSequence answers the question a schema cannot -
            # "would this sequence actually work on the machine you are about to
            # deploy" - and its own header names the console as the place those
            # findings are meant to surface (DESIGN 12: validation, inline).
            Finding      = [pscustomobject[]] @()
            ErrorCount   = 0
            WarningCount = 0
        }

        try {
            $sequence = Import-HDTSequenceDocument -Path $entry.DocumentPath -FileSystem $FileSystem

            $row.Name = [string] $sequence.Name
            $row.Version = [string] $sequence.Version
            $row.Description = [string] $sequence.Description
            $row.Step = @($sequence.Step)
            $row.Group = @($sequence.Group)
            $row.StepCount = @($sequence.Step).Count
            $row.GroupCount = @($sequence.Group).Count

            $row.Folder = [string] $sequence.Folder

            if ($null -ne $sequence.PSObject.Properties['Variable'] -and $null -ne $sequence.Variable) {
                foreach ($name in @($sequence.Variable.Keys)) {
                    $row.Variable[[string] $name] = $sequence.Variable[$name]
                }
            }

            # THE LINT IS NOT ALLOWED TO TAKE THE SEQUENCE OFF THE SCREEN. It is
            # a lint: it returns findings rather than throwing, but a step type
            # registry that could not be read, or a rule that trips over an
            # unusual document, must not turn a readable sequence into an
            # unreadable one. A share full of task sequences is the console's
            # whole subject.
            try {
                $row.Finding = [pscustomobject[]] @(Test-HDTTaskSequence -Sequence $sequence)
            } catch {
                $row.Finding = [pscustomobject[]] @()
            }

            $row.ErrorCount = @($row.Finding | Where-Object { $_.Severity -eq 'Error' }).Count
            $row.WarningCount = @($row.Finding | Where-Object { $_.Severity -eq 'Warning' }).Count
        } catch {
            $row.Status = 'Error'
            $row.Error = [string] $_.Exception.Message
        }

        [void] $sequenceRow.Add($row)
    }

    # -- operating systems -------------------------------------------------

    $osRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($entry in @(Get-HDTConsoleCatalogEntry -Root $root -Kind OperatingSystems `
                -DocumentName 'os.yaml' -FileSystem $FileSystem)) {

        $row = [pscustomobject] @{
            Id           = $entry.Id
            Name         = $entry.Id
            Description  = ''

            # WHICH FOLDER THE TREE DRAWS IT UNDER, as on a task sequence row.
            Folder       = ''
            Type         = ''
            Architecture = ''
            DefaultIndex = 0
            ImageCount   = 0
            Image        = [pscustomobject[]] @()
            SourcePath   = ''
            ImagePath    = ''
            Path         = $entry.DocumentPath
            Status       = 'Ok'
            Error        = ''
        }

        try {
            $operatingSystem = Get-HDTOperatingSystem -WorkspaceRoot $root -Id $entry.Id -FileSystem $FileSystem

            $row.Name = [string] $operatingSystem.Name
            $row.Description = [string] $operatingSystem.Description
            $row.Folder = [string] $operatingSystem.Folder
            $row.Type = [string] $operatingSystem.Type
            $row.Architecture = [string] $operatingSystem.Architecture
            $row.DefaultIndex = [int] $operatingSystem.DefaultIndex
            $row.Image = [pscustomobject[]] @($operatingSystem.Images)
            $row.ImageCount = @($operatingSystem.Images).Count
            $row.SourcePath = [string] $operatingSystem.SourcePath
            $row.ImagePath = [string] $operatingSystem.ImagePath
        } catch {
            $row.Status = 'Error'
            $row.Error = [string] $_.Exception.Message
        }

        [void] $osRow.Add($row)
    }

    # -- applications ------------------------------------------------------
    #
    # THE CATALOG IS THE DIRECTORY (DESIGN 2.1): one folder per application
    # holding its app.yaml, so the rows are an enumeration and a read, exactly
    # as the operating systems above are. Get-HDTApplication is the command an
    # administrator would type, and it is the one used here.

    $appRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($entry in @(Get-HDTConsoleCatalogEntry -Root $root -Kind Applications `
                -DocumentName 'app.yaml' -FileSystem $FileSystem)) {

        $row = [pscustomobject] @{
            Id          = $entry.Id
            Name        = $entry.Id
            Description = ''

            # WHO MAKES IT AND WHICH VERSION - Workbench's other two questions,
            # and what tells two entries called Reader apart.
            Publisher   = ''
            Version     = ''

            # WHICH FOLDER THE TREE DRAWS IT UNDER, as on the other two.
            Folder      = ''
            Install     = ''
            Uninstall   = ''
            RunIn       = ''
            Detection   = ''

            # THE RULE AS THE DOCUMENT WRITES IT, beside the sentence that
            # describes it. The pane's box writes app.yaml, so it has to hold
            # what app.yaml holds; the sentence is for reading and would become
            # the document's detection rule if it were ever typed back.
            DetectText  = ''

            # WHAT WILL HAPPEN, INHERITED DEFAULTS INCLUDED. DESIGN 8 gives an
            # application that declares neither key 0 and 3010 for success and
            # 3010 for reboot, and a blank box where those are in force would
            # read as "no code succeeds" - the opposite of what is true.
            SuccessCode = [int[]] @()
            RebootCode  = [int[]] @()
            Dependency  = [string[]] @()
            SourcePath  = ''
            Path        = $entry.DocumentPath
            Status      = 'Ok'
            Error       = ''
        }

        try {
            $application = Get-HDTApplication -WorkspaceRoot $root -Id $entry.Id -FileSystem $FileSystem

            $row.Name = [string] $application.Name
            $row.Description = [string] $application.Description
            $row.Publisher = [string] $application.Publisher
            $row.Version = [string] $application.Version
            $row.Folder = [string] $application.Folder
            $row.Install = [string] $application.Install
            $row.Uninstall = [string] $application.Uninstall
            $row.RunIn = [string] $application.RunIn
            $row.Detection = Get-HDTConsoleDetectionText -Detect $application.Detect
            $row.DetectText = Get-HDTConsoleDetectRuleText -Detect $application.Detect
            $row.SuccessCode = [int[]] @($application.SuccessCodes)
            $row.RebootCode = [int[]] @($application.RebootCodes)
            $row.Dependency = [string[]] @($application.Dependencies)
            $row.SourcePath = [string] $application.SourcePath
        } catch {
            $row.Status = 'Error'
            $row.Error = [string] $_.Exception.Message
        }

        [void] $appRow.Add($row)
    }

    # -- drivers -----------------------------------------------------------
    #
    # THE FOLDER, AND NOTHING ABOUT ITS CONTENTS. DESIGN 7 describes a driver
    # store; the engine has no command that reads one - no Get-HDTDriver, no
    # driver schema, nothing (M5 is deferred). So the console reports where the
    # folder is and whether it exists, which is true, and says the rest is not
    # built yet. Enumerating the tree here would put a driver inventory on
    # screen that no deployment could act on, and inventing a reader is exactly
    # what DESIGN 12's "the console may not do anything the cmdlets can't"
    # forbids.
    $driverFolder = Get-HDTWorkspacePath -Root $root -Kind Drivers

    $driver = [pscustomobject] @{
        Folder  = $driverFolder
        Present = [bool] $FileSystem.TestPath($driverFolder)
    }

    # -- the selection profiles --------------------------------------------
    #
    # WHAT THE DRIVER STORE COULD NOT BE. There is still no driver catalog, but
    # a selection profile is a document with a reader behind it - so this branch
    # of the tree can say something an administrator can act on, which is
    # exactly the test the Drivers node fails.
    #
    # A BROKEN DOCUMENT LEAVES THE BRANCH EMPTY RATHER THAN TAKING THE CONSOLE
    # DOWN. Get-HDTConsoleShareNode draws a row saying so; a share whose profile
    # document has a typo in it still has five other branches worth opening.
    $selectionProfile = @()
    $selectionProfileFailure = ''

    try {
        $selectionProfile = @(Get-HDTSelectionProfile -Root $root -FileSystem $FileSystem)
    } catch {
        $selectionProfileFailure = [string] $_.Exception.Message
    }

    # -- the boot image ----------------------------------------------------

    $bootImage = Get-HDTConsoleBootImage -Root $root -BootImage $workspace.BootImage -FileSystem $FileSystem

    return [pscustomobject] @{
        Root            = $root
        WorkspacePath   = $workspacePath
        SchemaVersion   = [int] $workspace.SchemaVersion
        Id              = [string] $workspace.Id
        Name            = [string] $workspace.Name
        DeployRoot      = [string] $workspace.DeployRoot
        LogLevel        = [string] $workspace.LogLevel
        CredentialUser  = $credentialUser

        # A share this command returned is by definition one it could open. The
        # member is here so a share that could NOT be opened
        # (New-HDTConsoleShareFailure) is the same shape, and nothing downstream
        # needs to know which kind it is holding.
        Status          = 'Ok'
        Error           = ''

        # WHETHER THE RULES DOCUMENT WOULD PARSE, which was the one document on
        # a share with no status anywhere in the tree. Sequences, operating
        # systems and applications all carry one; rules.yaml was validated per
        # keystroke in the Windows PE window's Rules tab and NOWHERE ELSE, so a
        # share whose rules were broken looked healthy in the browser until
        # somebody happened to open that tab.
        #
        # AND IT BREAKS EVERY DEPLOYMENT FROM THE SHARE, not one of them - it is
        # what CustomSettings.ini was. That is why it belongs on the share row
        # rather than under a category.
        Rule            = (Get-HDTConsoleWorkspaceRule -Root $root -FileSystem $FileSystem)
        # THE FOLDERS THE SHARE DECLARES, which are the ones nothing is in
        # yet - see Add-HDTWorkspaceFolder. A folder a document names needs
        # no declaration, and the tree draws the union of the two.
        Folder          = $workspace.Folder

        TaskSequence    = [pscustomobject[]] @($sequenceRow)
        OperatingSystem = [pscustomobject[]] @($osRow)
        Application     = [pscustomobject[]] @($appRow)
        Driver          = $driver
        SelectionProfile = [object[]] @($selectionProfile)
        SelectionProfileFailure = $selectionProfileFailure
        BootImage       = $bootImage

        # WHAT IS RUNNING ON IT, right now. DESIGN 12 lists Monitoring among the
        # tree's categories, so it is part of what a share IS rather than a
        # separate command an administrator has to know exists.
        Monitor         = (Get-HDTConsoleMonitor -Path $root -FileSystem $FileSystem -Clock $Clock)
    }
}
