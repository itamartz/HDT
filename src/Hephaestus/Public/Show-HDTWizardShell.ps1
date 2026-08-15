function Show-HDTWizardShell {
    <#
        .SYNOPSIS
            Shows the multi-page technician wizard and returns what the
            technician chose.

        .DESCRIPTION
            MDT'S LITETOUCH WIZARD, DRIVEN. Show-HDTWizard shows ONE window and
            reports the button that was pressed. This shows
            HDTWizardShell.xaml - a rail down the left, the current page to the
            right of it, Back / Next / Cancel / Open CMD along the bottom - and
            drives it across every page the deployment still has to ask.

            ONE WINDOW, AND THE PAGE INSIDE IT IS SWAPPED. Not one dialog per
            page: a window that closed and reopened between pages would flicker,
            lose wherever the technician had dragged it, and make Back feel like
            a different program. The host opens the shell once and replaces the
            content of HDTPageHost; this decides what that content is.

            THE DECISIONS ARE NOT IN THE HOST AND MUST NOT BE. Step-HDTWizardPage
            is the navigator and is unit tested; this command owns which file is
            refused and what an answer means; New-HDTWizardHost owns WPF and is
            exempt from TDD only for as long as it has nothing in it worth
            testing (CLAUDE.md rule 1). The host is handed a NAVIGATOR to call
            on each click, so page order never lives inside the adapter.

            EVERY PAGE IS CHECKED BEFORE THE FIRST ONE IS SHOWN. A missing or
            half-written page file is refused here, by name, while a human can
            still read the message - not two clicks into a deployment, in WinPE,
            on a machine whose console has been hidden to put this window on
            screen. That is the same rule Show-HDTWizard holds for its single
            window, applied to all of them.

            A DISMISSED WINDOW IS A CANCEL, and the allow-list is the same three
            answers for the same reason: Next leads to a task sequence that
            partitions a disk, so anything that is not exactly 'Next', 'Cancel'
            or 'CommandPrompt' comes back as 'Cancel'.

            OPENING THE PROMPT IS STILL THE CALLER'S JOB. 'CommandPrompt' is
            MDT's "Exit to Command Prompt": the window closes and the technician
            is left at a prompt - which in WinPE means the caller restores the
            console it hid (Hide-HDTShellWindow -Restore). This command reports
            what was asked for and opens nothing.

        .PARAMETER ShellXamlPath
            The shell window. X:\HDT\UI\HDTWizardShell.xaml inside a boot image.

        .PARAMETER Page
            The ordered pages this deployment will actually ask - already
            filtered, because a skipped page does not appear in the rail either
            (DESIGN 11.2). Each entry carries Id, Title, Heading, Subheading and
            XamlPath; the markup at XamlPath is read here and handed over, so the
            host never touches the file system.

        .PARAMETER Title
            The window title.

        .PARAMETER ThemeXamlPath
            HDTTheme.xaml, merged into the shell at runtime so every page is
            styled from one place. Omitted, the shell renders on whatever its own
            markup declares.

        .PARAMETER Field
            What every box should say, from Get-HDTWizardField. Applied by name
            after each page is loaded; a name no page answers to is skipped.

        .PARAMETER Pane
            Which panes are visible, from Get-HDTWizardSkip.

        .PARAMETER WizardHost
            An IWizardHost. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action ('Next',
            'Cancel' or 'CommandPrompt'), Title, ShellXamlPath and PageCount.

        .EXAMPLE
            Show-HDTWizardShell -ShellXamlPath 'X:\HDT\UI\HDTWizardShell.xaml' -Page $page

            What the payload calls in WinPE.

        .EXAMPLE
            $answer = Show-HDTWizardShell -ShellXamlPath $p -Page $page
            if ($answer.Action -eq 'CommandPrompt') { [void] (Hide-HDTShellWindow -Restore); return }
            if ($answer.Action -ne 'Next') { return }

            How every caller must read it: a prompt is not a cancel, and only an
            explicit Next deploys.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $ShellXamlPath,

        # EMPTY IS ALLOWED THROUGH THE BINDER SO IT CAN BE REFUSED BY NAME below.
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Page,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Title = 'Hephaestus Deployment Toolkit',

        [Parameter()]
        [AllowEmptyString()]
        [string] $ThemeXamlPath = '',

        [Parameter()]
        [AllowNull()]
        [object[]] $Field,

        [Parameter()]
        [AllowNull()]
        [object[]] $Pane,

        [Parameter()]
        [AllowNull()]
        [object] $WizardHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $WizardHost) { $WizardHost = New-HDTWizardHost }

    if (@($Page).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ('the wizard has no pages to show. Every page being skipped means NOT SHOWING THE WIZARD, which is the caller''s decision - see DESIGN 11.2 and HDTSkipWizard.')))
    }

    # -- every file, before anything is shown ------------------------------
    #
    # See the header: a wizard that opens and then dies on page four is worse
    # than one that refuses to open and says which file is broken.

    $read = {
        param([string] $Path, [string] $What)

        if (-not $FileSystem.TestPath($Path)) {
            throw (New-HDTErrorRecord -Path $Path -Category ObjectNotFound `
                    -Message ('{0} is not there, so the wizard cannot be shown. In a boot image it is staged to X:\HDT\UI\ by Update-HDTBootImage.' -f $What))
        }

        $text = [string] $FileSystem.ReadAllText($Path)

        # WELL-FORMEDNESS ONLY, not XAML semantics - a tag WPF dislikes still
        # fails at Show. What is caught here is the truncated or half-written
        # file a bad copy into a boot image produces.
        try {
            [void] ([xml] $text)
        } catch {
            throw (New-HDTErrorRecord -Path $Path -Category InvalidData `
                    -Message ('{0} is not well-formed XML, so it could not be shown: {1}' -f
                        $What, [string] $_.Exception.Message))
        }

        return $text
    }

    try {
        $shellXaml = & $read $ShellXamlPath 'the wizard shell'

        $themeXaml = ''
        if (-not [string]::IsNullOrWhiteSpace($ThemeXamlPath)) {
            $themeXaml = & $read $ThemeXamlPath 'the wizard theme'
        }

        # THE PAGE MARKUP IS READ HERE, NOT IN THE HOST. The host is a WPF
        # adapter; an adapter that reads files has something in it worth
        # testing, which is the exemption it would then no longer qualify for.
        $loaded = @()
        foreach ($current in @($Page)) {
            $id = [string] $current.Id

            $loaded += [pscustomobject] @{
                Id         = $id
                Title      = [string] $current.Title
                Heading    = [string] $current.Heading
                Subheading = [string] $current.Subheading
                XamlPath   = [string] $current.XamlPath
                Xaml       = (& $read ([string] $current.XamlPath) ('wizard page ''{0}''' -f $id))
            }
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    # -- show it -----------------------------------------------------------

    $state = Step-HDTWizardPage -Page $loaded -Index 0 -Action 'Start'

    # THE NAVIGATOR THE HOST CALLS ON EVERY CLICK. GetNewClosure captures
    # $loaded, so the host is handed a question it can ask rather than a list it
    # would have to reason about.
    $navigator = {
        param([int] $Index, [string] $Action)

        return Step-HDTWizardPage -Page $loaded -Index $Index -Action $Action
    }.GetNewClosure()

    $answer = [string] $WizardHost.ShowShell($shellXaml, $themeXaml, $Title, $state, @($Field), @($Pane), $navigator)

    # THE ALLOW-LIST, and it is the same one Show-HDTWizard holds for the same
    # reason. Matched case-sensitively, and the ALLOW-LIST's spelling is what is
    # returned - never the host's string.
    $action = 'Cancel'
    foreach ($allowed in @('Next', 'Cancel', 'CommandPrompt')) {
        if ($answer -ceq $allowed) {
            $action = $allowed
            break
        }
    }

    return [pscustomobject] @{
        Action        = $action
        Title         = $Title
        ShellXamlPath = $ShellXamlPath
        PageCount     = @($loaded).Count
    }
}
