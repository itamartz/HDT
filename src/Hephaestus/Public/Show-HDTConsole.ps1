function Show-HDTConsole {
    <#
        .SYNOPSIS
            Opens the HDT admin console on one or more deployment shares.

        .DESCRIPTION
            The
            Deployment Workbench equivalent, showing what is on a share - its
            deployRoot, its task sequences, its operating systems, and the boot
            image with its build date and hashes.

            SEVERAL SHARES AT ONCE. -Path takes a list, and every share appears
            under the one 'Deployment Shares' root, the way Deployment Workbench
            roots them. An administrator with a lab share and a production share
            has them side by side rather than in two windows.

            A SHARE THAT WILL NOT OPEN DOES NOT CLOSE THE CONSOLE. Each share is
            read in its own try/catch and a failure becomes a row naming the path
            and the reason. Get-HDTConsoleWorkspace still throws when it is
            called directly on one bad share - that is the right answer for a
            command - but a window is not a command, and three good shares must
            not disappear because of a fourth.

            THE WINDOW IS NOT IN THIS FUNCTION. An injected IConsoleHost owns
            everything WPF - Add-Type, XamlReader, ShowDialog - and this function
            owns the decisions, exactly as Show-HDTWizard does for the technician
            wizard. New-HDTConsoleHost is the real one, and it is branch-free
            BECAUSE it is not unit tested; what is on the screen is decided by
            Get-HDTConsoleWorkspace and Get-HDTConsoleTreeNode, both of which are.

            WPF NEEDS A SINGLE-THREADED APARTMENT. Windows PowerShell 5.1 and
            pwsh 7.5 both start STA, so this guard is normally a no-op - but
            'pwsh -MTA', and any host that runs a script on an MTA thread, do
            not, and a WPF window created there fails in the worst way a UI can:
            with no window and nothing said. Refusing with a sentence naming the
            switch costs one comparison and turns that into something an
            administrator can act on. Start-HDTConsole.ps1 re-launches itself
            with -STA so they never meet it at all.

            THE XAML IS CHECKED BEFORE THE WINDOW IS SHOWN. A file that is not
            there, that is empty, or that is not well-formed, is refused by name.
            What is checked is XML well-formedness, not XAML semantics: a tag WPF
            dislikes still fails at Show, but a truncated or half-written file
            fails here, with a sentence naming the file.

            A DISMISSED WINDOW IS A CLOSE, AND THAT IS NOT WHAT THE WIZARD DOES.
            Show-HDTWizard reads anything that is not an explicit Next as a
            Cancel, because its Next leads to a task sequence that partitions a
            disk and silence must never read as approval. C1 of the console reads
            the shares and writes nothing to them, so there is no approval to
            withhold and an empty answer is simply a window that was shut. The
            asymmetry is deliberate; when the console grows an action that
            changes a share, that action gets the wizard's rule, not this one.

            IT IS READ-ONLY, ON PURPOSE. Nothing in C1 writes to a share.

        .PARAMETER Path
            The deployment shares to open - local paths or UNC shares, in the
            order they should appear.

        .PARAMETER Workspace
            Already-read shares, when the caller has them and does not want the
            shares read again. The window builds these itself from -Path; this is
            the seam a test injects through, not a second way to open a share.

        .PARAMETER XamlPath
            The window to show. Defaults to the HDTConsole.xaml that ships beside
            this module.

        .PARAMETER Title
            The window title.

        .PARAMETER ConsoleHost
            An IConsoleHost. Defaults to the real adapter.

        .PARAMETER RefreshSecond
            How often the Monitoring branch re-reads Logs\_active\, in seconds.
            Fifteen by default: short enough that a technician watching a build
            sees it move, long enough that a console left open on somebody's
            second monitor is not hammering an SMB share all afternoon. The
            engine writes a heartbeat per STEP, so polling faster would mostly
            re-read the same file.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Environment
            An IEnvironmentProvider, used to find the remembered window size
            under the user profile. Defaults to the real adapter.

        .PARAMETER Screen
            An IScreen, used to fit the remembered size to the desktop the
            window has to open on. Defaults to the real adapter.

        .PARAMETER ApartmentState
            The apartment the window would be created on. Defaults to the
            calling thread's, and exists so the refusal above is provable
            without a second process.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action ('Close'),
            Title, XamlPath, NodeCount and Workspace - the shares that were
            shown, so a caller can go on working with exactly what the
            administrator saw.

        .EXAMPLE
            Show-HDTConsole -Path 'C:\HDTLab\Share'

            Opens the console on the lab share.

        .EXAMPLE
            Show-HDTConsole -Path 'C:\HDTLab\Share', '\\192.168.2.108\HDTShare'

            Two shares, one window.

        .EXAMPLE
            $answer = Show-HDTConsole -Path 'C:\HDTLab\Share'
            $answer.Workspace[0].BootImage.HashMatch

            The window closed, and the fact it showed, still in hand.
    #>
    [CmdletBinding(DefaultParameterSetName = 'FromPath')]
    [OutputType([pscustomobject])]
    param(
        # NOT MANDATORY ANY MORE. A console opened with no path opens the
        # shares it was last closed on, the way Workbench comes back to the ones
        # somebody added - and on a machine that has never opened one, it opens
        # empty with New and Open on the root row's menu, which is a window
        # somebody can act on rather than a parameter binding error.
        [Parameter(Position = 0, ParameterSetName = 'FromPath')]
        [AllowEmptyCollection()]
        [string[]] $Path = @(),

        [Parameter(Mandatory = $true, ParameterSetName = 'FromWorkspace')]
        [ValidateNotNull()]
        [object[]] $Workspace,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTConsole.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $NewSequenceXamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTNewSequence.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ImportOperatingSystemXamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTImportOperatingSystem.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ImportApplicationXamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTImportApplication.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ApplicationDependencyXamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTApplicationDependency.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ApplicationDetectionXamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTApplicationDetection.xaml'),



        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $NewWorkspaceXamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTNewWorkspace.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Title = 'Hephaestus Deployment Toolkit',

        [Parameter()]
        [AllowNull()]
        [object] $ConsoleHost,

        [Parameter()]
        [ValidateRange(2, 3600)]
        [int] $RefreshSecond = 15,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Environment,

        [Parameter()]
        [AllowNull()]
        [object] $Screen,


        [Parameter()]
        [System.Threading.ApartmentState] $ApartmentState =
        [System.Threading.Thread]::CurrentThread.GetApartmentState()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $ConsoleHost) { $ConsoleHost = New-HDTConsoleHost }

    # -- the apartment, before anything else -------------------------------

    if ($ApartmentState -ne [System.Threading.ApartmentState]::STA) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTEnvironmentError' `
                    -Category InvalidOperation `
                    -Message ("WPF needs a single-threaded apartment and this thread is {0}. Run the console with 'pwsh -STA', with windows powershell, or through Start-HDTConsole.ps1, which arranges it. A window created on an MTA thread never appears and reports nothing." -f
                        $ApartmentState)))
    }

    # -- the window file, before anything is read off a share --------------
    #
    # Deliberately first: a share can take a moment over the network, and a
    # missing window file is a mistake in the install rather than in the share.

    if (-not $FileSystem.TestPath($XamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath -Category ObjectNotFound `
                    -Message 'the console window is not there, so there is nothing to show. It ships as UI\Console\HDTConsole.xaml beside the Hephaestus module.'))
    }

    $xaml = [string] $FileSystem.ReadAllText($XamlPath)

    # An empty file is checked separately because [xml] '' does NOT throw - it
    # yields an empty document - so the well-formedness check below would pass a
    # zero-byte window straight through to XamlReader, which fails with an
    # exception about a root element that reads like a XAML problem. A file that
    # was copied badly is the way this happens.
    if ([string]::IsNullOrWhiteSpace($xaml)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath -Category InvalidData `
                    -Message 'the console window is empty, so there is nothing to show.'))
    }

    try {
        [void] ([xml] $xaml)
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath -Category InvalidData `
                    -Message ('the console window is not well-formed XML, so it could not be shown: {0}' -f
                        [string] $_.Exception.Message)))
    }

    # -- what it shows -----------------------------------------------------

    # THE SIZE IT WAS LEFT AT, FITTED TO THE SCREEN IT HAS TO OPEN ON, AND THE
    # CORNER IT OPENS IN. The window is placed rather than centred, so a
    # remembered size larger than this desktop would hang off the right and the
    # bottom - and the bottom is where the Close button is. The position is not
    # remembered: it is the origin of today's work area, measured every time.
    #
    # READ HERE RATHER THAN JUST BEFORE THE WINDOW, because the same file
    # remembers which SHARES this console was last closed on, and those decide
    # what the tree is built from.
    $size = Get-HDTConsoleSetting -FileSystem $FileSystem -Environment $Environment -Screen $Screen

    # NO PATH MEANS THE ONES IT WAS LAST CLOSED ON, which is how Workbench
    # behaves: the shares somebody added are there the next morning. A machine
    # that has never opened one gets an empty window with New Deployment Share
    # and Open Deployment Share on the root row - something to act on, rather
    # than a parameter binding error.
    if ($PSCmdlet.ParameterSetName -eq 'FromPath' -and @($Path).Count -eq 0) {
        $Path = [string[]] @($size.Share)
    }


    # THE WINDOW OPENS BEFORE THE SHARE IS READ.
    #
    # Get-HDTConsoleWorkspace costs 820ms on the lab share - it reads and
    # validates every task sequence in it - and until this was deferred that was
    # 820ms with nothing on screen at all, because the tree had to exist before
    # the window could be shown. The window now comes up holding one row saying
    # it is reading, and the reading happens once it is up.
    #
    # NOT A BACKGROUND RUNSPACE. The read runs on the dispatcher after the first
    # paint, so the window is visible and busy for that second rather than
    # absent for it. A second runspace would need this module imported into it -
    # which is the OTHER second the console used to spend - before it could read
    # anything, and would then have to marshal every row back.
    #
    # A WORKSPACE HANDED IN HAS ALREADY BEEN READ, so that parameter set builds
    # its tree here exactly as it always did.
    $share = New-Object -TypeName System.Collections.ArrayList
    $carried = @{ Node = @() }

    $fill = $null

    if ($PSCmdlet.ParameterSetName -eq 'FromWorkspace') {
        foreach ($current in @($Workspace)) {
            [void] $share.Add($current)
        }

        # FOLDED ON THE FIRST BUILD - see New-HDTConsoleShareReader, which does
        # the same for the -Path set.
        $carried.Node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($share)) -Collapsed)

        # THE HOST IS HANDED THE ROOTS, NOT EVERY ROW. WPF builds the branches
        # from each row's Children, so the depth-0 rows are the whole
        # ItemsSource. Which rows those are is decided here rather than in the
        # adapter, which is not unit tested and must therefore not be the thing
        # that knows.
        $treeRoot = @($carried.Node | Where-Object { $_.Depth -eq 0 })
    } else {
        $treeRoot = @(New-HDTConsolePendingNode -Path ([string[]] @($Path)))

        # WHAT THE RESULT REPORTS COMES OUT OF HERE TOO. This command returns
        # NodeCount and Workspace, and neither is known until the read has
        # happened - so both are carried in objects the block writes into rather
        # than read from variables that were still empty when the window opened.
        #
        # THE BLOCK IS BUILT ELSEWHERE, and New-HDTConsoleShareReader's own
        # notes say why: a plain script block would resolve $share against the
        # window host that invokes it, and GetNewClosure called here would choke
        # on the other parameter set's validated, empty parameter.
        $fill = New-HDTConsoleShareReader -Path ([string[]] @($Path)) -FileSystem $FileSystem `
            -Share $share -Carried $carried
    }

    # -- show it -----------------------------------------------------------

    # THE WIZARD'S MARKUP TRAVELS WITH THE CONSOLE'S, so the host never touches
    # the file system - the same reason the console's own markup arrives as a
    # string. Absent, the New Task Sequence button hides itself rather than
    # promising a window that cannot open.
    $newSequenceXaml = ''
    if (Test-Path -LiteralPath $NewSequenceXamlPath) {
        $newSequenceXaml = [System.IO.File]::ReadAllText($NewSequenceXamlPath)
    }

    $importOperatingSystemXaml = ''
    if (Test-Path -LiteralPath $ImportOperatingSystemXamlPath) {
        $importOperatingSystemXaml = [System.IO.File]::ReadAllText($ImportOperatingSystemXamlPath)
    }

    $importApplicationXaml = ''
    if (Test-Path -LiteralPath $ImportApplicationXamlPath) {
        $importApplicationXaml = [System.IO.File]::ReadAllText($ImportApplicationXamlPath)
    }

    $applicationDependencyXaml = ''
    if (Test-Path -LiteralPath $ApplicationDependencyXamlPath) {
        $applicationDependencyXaml = [System.IO.File]::ReadAllText($ApplicationDependencyXamlPath)
    }

    $applicationDetectionXaml = ''
    if (Test-Path -LiteralPath $ApplicationDetectionXamlPath) {
        $applicationDetectionXaml = [System.IO.File]::ReadAllText($ApplicationDetectionXamlPath)
    }

    $newWorkspaceXaml = ''
    if (Test-Path -LiteralPath $NewWorkspaceXamlPath) {
        $newWorkspaceXaml = [System.IO.File]::ReadAllText($NewWorkspaceXamlPath)
    }

    # THE LOG OPENS BEFORE THE WINDOW AND CLOSES AFTER IT, and the close is in a
    # finally: the session worth reading is the one that ended badly, and a log
    # that records an open and never a close cannot tell a console somebody shut
    # from one that died. Start-HDTConsoleLog never throws, so a log that will
    # not open costs the administrator a log and not a console.
    # THE FIRST SHARE IS WHERE IT WRITES. A console can be opened on several;
    # its log goes in the Logs folder of the one it opened with, beside that
    # share's deployment logs. Opened on none, there is no log - see
    # Get-HDTConsoleLogPath, which says what that costs.
    $logShare = ''
    if (@($Path).Count -gt 0) { $logShare = [string] @($Path)[0] }

    # THROUGH THE INJECTED FILE SYSTEM, like everything else this command
    # touches. Omitting it defaulted to the REAL adapter, so every test that
    # opens a console on the fake root wrote C:\ws\Logs\Console.log to an actual
    # disk - which is what GatherAndResolve.EndToEnd's "the run touched nothing
    # real" assertion is for, and what it caught within hours of this being
    # added. Rule 5 is not only about hardware: a log is a write like any other.
    [void] (Start-HDTConsoleLog -WorkspaceRoot $logShare -FileSystem $FileSystem)

    try {
        $answer = [string] $ConsoleHost.Show($xaml, $Title, [object[]] $treeRoot,
            (Get-HDTConsoleTheme), $size, $RefreshSecond, $newSequenceXaml,
            $importOperatingSystemXaml, $importApplicationXaml, $applicationDependencyXaml,
            $applicationDetectionXaml, $fill, $newWorkspaceXaml)
    } finally {
        Stop-HDTConsoleLog
    }

    # THE SIZE IT WAS LEFT AT, REMEMBERED. Save-HDTConsoleSetting refuses a size
    # below the window's minimum and never throws, so a closing window cannot
    # fail because a preference could not be written.
    # AND THE SHARES IT ENDED UP WITH, so the next console comes back to them.
    # Only when the window said - a host that never reported any is a window
    # that was never filled, and forgetting the list on that would lose it to
    # any failure at all.
    $settingSplat = @{
        Width       = [int] $ConsoleHost.Width
        Height      = [int] $ConsoleHost.Height
        FileSystem  = $FileSystem
        Environment = $Environment
    }

    if (@($ConsoleHost.PSObject.Properties.Match('OpenShare')).Count -gt 0 -and
        $null -ne $ConsoleHost.OpenShare) {

        $settingSplat['Share'] = [string[]] @($ConsoleHost.OpenShare)
    }

    [void] (Save-HDTConsoleSetting @settingSplat)

    # A window that was shut and a window whose Close button was pressed are the
    # same outcome here. See the header for why that differs from the wizard.
    $action = 'Close'
    if (-not [string]::IsNullOrWhiteSpace($answer)) { $action = $answer }

    return [pscustomobject] @{
        Action    = $action
        Title     = $Title
        XamlPath  = $XamlPath
        NodeCount = @($carried.Node).Count
        Workspace = [object[]] @($share)
    }
}
