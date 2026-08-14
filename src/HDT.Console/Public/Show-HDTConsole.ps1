function Show-HDTConsole {
    <#
        .SYNOPSIS
            Opens the HDT admin console on one or more deployment shares.

        .DESCRIPTION
            C1 of the WPF-first direction (.planning/WPF-FIRST.md): the
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
            Already-read shares from Get-HDTConsoleWorkspace, when the caller has
            them and does not want the shares read again.

        .PARAMETER XamlPath
            The window to show. Defaults to the HDTConsole.xaml that ships beside
            this module.

        .PARAMETER Title
            The window title.

        .PARAMETER Theme
            Light or Dark. LIGHT IS THE DEFAULT: the console is a desktop
            application sitting beside Explorer and the Workbench it replaces,
            in an office. The WinPE wizard keeps its dark palette, because that
            one is read on a bench with nothing else on the screen.

        .PARAMETER ConsoleHost
            An IConsoleHost. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

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
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'FromPath')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'FromWorkspace')]
        [ValidateNotNull()]
        [object[]] $Workspace,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath = (Join-Path -Path $script:HDTConsoleRoot -ChildPath 'UI\HDTConsole.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Title = 'Hephaestus Deployment Toolkit',

        [Parameter()]
        [AllowNull()]
        [object] $ConsoleHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [ValidateSet('Light', 'Dark')]
        [string] $Theme = 'Light',

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
        $PSCmdlet.ThrowTerminatingError((New-HDTConsoleErrorRecord -ErrorId 'HDTEnvironmentError' `
                    -Category InvalidOperation `
                    -Message ("WPF needs a single-threaded apartment and this thread is {0}. Run the console with 'pwsh -STA', with windows powershell, or through Start-HDTConsole.ps1, which arranges it. A window created on an MTA thread never appears and reports nothing." -f
                        $ApartmentState)))
    }

    # -- the window file, before anything is read off a share --------------
    #
    # Deliberately first: a share can take a moment over the network, and a
    # missing window file is a mistake in the install rather than in the share.

    if (-not $FileSystem.TestPath($XamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTConsoleErrorRecord -Path $XamlPath -Category ObjectNotFound `
                    -Message 'the console window is not there, so there is nothing to show. It ships as UI\HDTConsole.xaml beside the HDT.Console module.'))
    }

    $xaml = [string] $FileSystem.ReadAllText($XamlPath)

    # An empty file is checked separately because [xml] '' does NOT throw - it
    # yields an empty document - so the well-formedness check below would pass a
    # zero-byte window straight through to XamlReader, which fails with an
    # exception about a root element that reads like a XAML problem. A file that
    # was copied badly is the way this happens.
    if ([string]::IsNullOrWhiteSpace($xaml)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTConsoleErrorRecord -Path $XamlPath -Category InvalidData `
                    -Message 'the console window is empty, so there is nothing to show.'))
    }

    try {
        [void] ([xml] $xaml)
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTConsoleErrorRecord -Path $XamlPath -Category InvalidData `
                    -Message ('the console window is not well-formed XML, so it could not be shown: {0}' -f
                        [string] $_.Exception.Message)))
    }

    # -- what it shows -----------------------------------------------------

    $share = New-Object -TypeName System.Collections.ArrayList

    if ($PSCmdlet.ParameterSetName -eq 'FromWorkspace') {
        foreach ($current in @($Workspace)) {
            [void] $share.Add($current)
        }
    } else {
        foreach ($current in @($Path)) {
            try {
                [void] $share.Add((Get-HDTConsoleWorkspace -Path $current -FileSystem $FileSystem))
            } catch {
                [void] $share.Add((New-HDTConsoleShareFailure -Path $current -Message ([string] $_.Exception.Message)))
            }
        }
    }

    $node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($share)))

    # THE HOST IS HANDED THE ROOTS, NOT EVERY ROW. WPF builds the branches from
    # each row's Children, so the depth-0 rows are the whole ItemsSource. Which
    # rows those are is decided here rather than in the adapter, which is not
    # unit tested and must therefore not be the thing that knows.
    $treeRoot = @($node | Where-Object { $_.Depth -eq 0 })

    # -- show it -----------------------------------------------------------

    $answer = [string] $ConsoleHost.Show($xaml, $Title, [object[]] $treeRoot, (Get-HDTConsoleTheme -Name $Theme))

    # A window that was shut and a window whose Close button was pressed are the
    # same outcome here. See the header for why that differs from the wizard.
    $action = 'Close'
    if (-not [string]::IsNullOrWhiteSpace($answer)) { $action = $answer }

    return [pscustomobject] @{
        Action    = $action
        Title     = $Title
        XamlPath  = $XamlPath
        NodeCount = @($node).Count
        Workspace = [object[]] @($share)
    }
}
