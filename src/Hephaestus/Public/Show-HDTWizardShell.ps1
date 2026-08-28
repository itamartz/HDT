function Show-HDTWizardShell {
    <#
        .SYNOPSIS
            Shows the multi-page technician wizard and returns what the
            technician chose.

        .DESCRIPTION
            THE WHOLE WIZARD, DRIVEN. Show-HDTWizard shows ONE window and
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

            OPENING THE PROMPT IS STILL THE CALLER'S JOB. 'CommandPrompt' means
            the window closes and the technician is left at a prompt - which in
            WinPE means the caller restores the console it hid
            (Hide-HDTShellWindow -Restore). This command reports what was asked
            for and opens nothing.

        .PARAMETER ShellXamlPath
            The shell window. X:\HDT\UI\HDTWizardShell.xaml inside a boot image.

        .PARAMETER Page
            The ordered pages this deployment will actually ask - already
            filtered, because a skipped page does not appear in the rail either
            (DESIGN 11.2). Each entry carries Id, Title, Heading, Subheading and
            XamlPath; the markup at XamlPath is read here and handed over, so the
            host never touches the file system.

            A page may also carry Validate - a Control name and a Rule name -
            and the rule is resolved to a validator here. The page names a RULE
            and never a command, because pages live on the share: one that could
            name a command would be one that could run one. A rule this engine
            does not implement is refused rather than ignored.

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
            $p = 'X:\HDT\UI\HDTWizardShell.xaml'
            $provider = New-HDTLocalContentProvider -Root 'C:\HDTLab\Share'
            $page = @((Get-HDTWizardPage -Page (Import-HDTWizardDocument -Provider $provider).Page -Variable @{}).Page)
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

        # MDT'S _SMSTSOrgName, ON THE ONE SURFACE THAT HAS A BANNER. Empty means
        # the banner reads 'Hephaestus', which is what every machine built
        # before this parameter existed carried.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $BrandingName = '',

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
        [object] $FileSystem,

        # WHAT F8 RUNS, AND IT IS PASSED IN FOR THE SAME REASON THE NAVIGATOR IS.
        # The host is an adapter no Pester test can open a window against, so
        # anything decided inside it is decided where nothing can check it. The
        # decision here is small and worth checking anyway: F8 opens a prompt
        # OVER the wizard and the wizard stays - MDT's "Enable command support",
        # which every technician who has debugged a deployment already knows.
        # The Open CMD button is the other thing: an EXIT to a prompt, answered
        # back to the caller.
        [Parameter()]
        [AllowNull()]
        [scriptblock] $CommandPrompt
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $WizardHost) { $WizardHost = New-HDTWizardHost }

    # THE DEFAULT IS THE REAL PROMPT, so a caller that says nothing still gets
    # F8. Start-HDTCommandPrompt already refuses to throw - a prompt that will
    # not open must not take the wizard with it - so nothing here needs a guard.
    if ($null -eq $CommandPrompt) { $CommandPrompt = { [void] (Start-HDTCommandPrompt) } }

    if (@($Page).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ('the wizard has no pages to show. Every page being skipped means NOT SHOWING THE WIZARD, which is the caller''s decision - see DESIGN 11.2 and HDTSkipWizard.')))
    }

    # THE CLOSED SET OF VALIDATION RULES a page may name. Each one wraps a
    # command that already exists and is tested where it lives - this is a
    # lookup, not a second implementation.
    #
    # RestrictInput MEANS "JUDGE A KEYSTROKE WITH THE SAME RULE". A character is
    # typeable when a name consisting of just that character would be accepted -
    # which is exactly true for this rule, because its character set is a
    # per-character test. So an unusable character CANNOT BE TYPED, and there is
    # still only ONE copy of what the legal characters are: nothing anywhere
    # holds a second list for the keyboard to check against.
    #
    # That mattered the moment a technician asked why the wizard let them type an
    # underscore at all. Refusing it after the fact is a message; refusing the
    # keystroke is an answer.
    # ONE CONTROL, MORE THAN ONE VARIABLE. A page may declare Split on a Collect
    # entry: the typed string is put through the named splitter and the parts
    # land in the variables the declaration names. The join account is the case
    # that needed it - a technician types CORP\svc-hdt-join in one box, and
    # DESIGN 4.5.3 wants HDTDomainAdmin and HDTDomainAdminDomain out of it.
    #
    # A CLOSED SET, LIKE THE RULES BELOW. A page on the share names a splitter
    # and never a command.
    $knownSplit = @{
        AccountName = {
            param([string] $Value)

            return Split-HDTAccountName -Name $Value
        }
    }

    $knownRule = @{
        ComputerName = [pscustomobject] @{
            Validator     = {
                param([string] $Value)

                return Test-HDTComputerName -Name $Value
            }
            RestrictInput = $true
        }

        # THE ONE RULE THAT JUDGES TWO CONTROLS. The page names a confirm
        # control beside it and the host passes what that box holds as the
        # second argument; every other rule is called with one and this
        # signature still binds.
        #
        # NO RestrictInput. A password may contain any character - refusing
        # keystrokes here would refuse passwords the domain policy accepts, and
        # a technician cannot see what they typed to work out why.
        AdminPassword = [pscustomobject] @{
            Validator     = {
                param([string] $Value, [string] $Confirmation = '')

                return Test-HDTAdminPassword -Password $Value -Confirmation $Confirmation
            }
            RestrictInput = $false
        }
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

            # A PAGE DECLARES WHAT IT VALIDATES; IT DOES NOT CARRY THE RULE.
            # Pages live on the SHARE (DESIGN 11.2) and are edited by
            # administrators, so a page that could name a command would be a
            # page that could run one. It names a control and a RULE, and the
            # closed set below is what those names may be.
            #
            # AN UNKNOWN RULE IS REFUSED RATHER THAN IGNORED. A control that
            # silently never validates looks, on a bench, like a wizard that
            # accepts anything - and the value on the other side of it is a
            # machine's identity.
            $validate = $null
            $validator = $null
            $restrictInput = $false

            if ($null -ne $current.PSObject.Properties['Validate'] -and $null -ne $current.Validate) {
                $validate = $current.Validate
                $ruleName = [string] $validate.Rule

                if (-not $knownRule.Contains($ruleName)) {
                    throw (New-HDTErrorRecord -Category InvalidArgument `
                            -Message ('wizard page ''{0}'' declares the validation rule ''{1}'', which this engine does not implement. Known rules: {2}.' -f
                                $id, $ruleName, ((@($knownRule.Keys) | Sort-Object) -join ', ')))
                }

                $validator = $knownRule[$ruleName].Validator
                $restrictInput = [bool] $knownRule[$ruleName].RestrictInput
            }

            # WHAT THIS PAGE FILLS IN, AND WHAT HIDES IT. Collect names a
            # control, the variable it fills and the property to read it from -
            # so a ListBox and a TextBox are the same to the host, which reads
            # the named property and knows nothing about either. Skip is the
            # variable that suppresses this page, and exists so the summary can
            # TELL a technician what it is (DESIGN 11.2's skip model was
            # documented and undiscoverable).
            $collect = $null
            if ($null -ne $current.PSObject.Properties['Collect']) { $collect = $current.Collect }

            # A DECLARATION THAT SPLITS gets its splitter attached here, for the
            # same reason a validation rule does: the page names one, and an
            # unknown name is refused rather than silently doing nothing.
            $resolvedCollect = @()
            foreach ($declaration in @($collect)) {
                if ($null -eq $declaration) { continue }

                $splitName = ''
                if ($null -ne $declaration.PSObject.Properties['Split']) { $splitName = [string] $declaration.Split }

                if (-not [string]::IsNullOrWhiteSpace($splitName)) {
                    if (-not $knownSplit.Contains($splitName)) {
                        throw (New-HDTErrorRecord -Category InvalidArgument `
                                -Message ('wizard page ''{0}'' declares the splitter ''{1}'', which this engine does not implement. Known splitters: {2}.' -f
                                    $id, $splitName, ((@($knownSplit.Keys) | Sort-Object) -join ', ')))
                    }

                    $declaration | Add-Member -MemberType NoteProperty -Name 'Splitter' `
                        -Value $knownSplit[$splitName] -Force
                }

                $resolvedCollect += $declaration
            }

            if (@($resolvedCollect).Count -gt 0) { $collect = $resolvedCollect }

            $skip = ''
            if ($null -ne $current.PSObject.Properties['Skip']) { $skip = [string] $current.Skip }

            $summary = $null
            if ($null -ne $current.PSObject.Properties['Summary']) { $summary = $current.Summary }

            $loaded += [pscustomobject] @{
                Id         = $id
                Title      = [string] $current.Title
                Heading    = [string] $current.Heading
                Subheading = [string] $current.Subheading
                Collect    = $collect
                Skip       = $skip
                Summary    = $summary
                XamlPath   = [string] $current.XamlPath
                Xaml          = (& $read ([string] $current.XamlPath) ('wizard page ''{0}''' -f $id))
                Validate      = $validate
                Validator     = $validator
                RestrictInput = $restrictInput
            }
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    # -- show it -----------------------------------------------------------

    # THE NAVIGATOR THE HOST CALLS ON EVERY CLICK. GetNewClosure captures
    # $loaded, so the host is handed a question it can ask rather than a list it
    # would have to reason about.
    #
    # IT TAKES WHAT HAS BEEN COLLECTED SO FAR, because one page is not like the
    # others: the summary has to state what every EARLIER page ended up holding,
    # and it has to be right at the moment it is shown rather than at the moment
    # the wizard opened. A technician who presses Back, changes the name and
    # comes forward again must see the new one.
    # THE DOOR THE CLOSURE REACHES THE NAVIGATOR THROUGH - see
    # Get-HDTHandlerCall. GetNewClosure rebinds the block below to the session
    # state of whoever calls it, which is the host, where nothing private
    # exists; this is declared out here so the block captures it.
    $call = Get-HDTHandlerCall

    $navigator = {
        param([int] $Index, [string] $Action, [hashtable] $Value)

        $next = & $call 'Step-HDTWizardPage' -Page $loaded -Index $Index -Action $Action

        if ($null -ne $next.Page -and $null -ne $next.Page.Summary) {
            $built = Get-HDTWizardSummary -Page $loaded -Value $Value

            # ADDED TO THE STATE, NOT BAKED INTO THE PAGE. The page object is
            # reused every time it is reached; writing onto it would leave the
            # previous visit's rows behind on a Back that changed nothing.
            $next | Add-Member -MemberType NoteProperty -Name 'SummaryRow' -Value $built.Row -Force
            $next | Add-Member -MemberType NoteProperty -Name 'SummarySnippet' -Value $built.Snippet -Force
        }

        return $next
    }.GetNewClosure()

    $state = & $navigator 0 'Start' @{}

    # THE SHELL'S OWN TEXT - its title, its subtitle and the four buttons on
    # the rail. The PAGES inside it carry their own, and each page is parsed
    # into its own name scope, so the shell's block cannot reach them.
    #
    # THE FILE NAME IS THE BLOCK NAME, the same rule Show-HDTWizard uses.
    $string = @{}

    try {
        $string = Get-HDTStringTable -Page (
            [System.IO.Path]::GetFileNameWithoutExtension($ShellXamlPath) -replace '^HDT', '')
    } catch {
        Write-Verbose ("no string table block for '{0}': {1}" -f $ShellXamlPath, [string] $_.Exception.Message)
    }

    # THE BANNER, OVER THE TOP OF THE STRING TABLE THAT JUST SUPPLIED IT.
    # HDTShellTitle.Text is 'Hephaestus' in en-us.psd1; a share that named
    # itself replaces that line and keeps the subtitle, so the rail reads
    # 'Contoso' over 'Deployment Toolkit' rather than losing half its heading.
    #
    # THE WINDOW TITLE IS LEFT ALONE. -Title comes from wizard.yaml, which is an
    # author deciding what this particular wizard is called; overwriting it with
    # the organisation name would take a decision that was already made.
    #
    # Get-HDTBrandingName is what knows an unset value from a value of three
    # spaces - this file cannot be unit tested, and that distinction can.
    if (-not [string]::IsNullOrWhiteSpace($BrandingName)) {
        if ($null -eq $string) { $string = @{} }

        $string['HDTShellTitle.Text'] = Get-HDTBrandingName -Value $BrandingName
    }

    # NULLS ARE STRIPPED for the same reason Show-HDTWizard strips them: @($null)
    # is a one-element array carrying $null, and the host reads .Name off every
    # element under Set-StrictMode.
    $answer = [string] $WizardHost.ShowShell($shellXaml, $themeXaml, $Title, $state,
        @($Field | Where-Object { $null -ne $_ }),
        @($Pane | Where-Object { $null -ne $_ }),
        $navigator, $CommandPrompt, $string)

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

    # WHAT WAS TYPED COMES BACK WITH THE ANSWER. A wizard that reported Next and
    # dropped the values would be a wizard that asked a technician for a
    # computer name and then deployed the machine without it.
    #
    # THE HOST READ THEM, SO THE HOST HANDS THEM BACK - it is the only thing
    # that ever touched the controls. This forwards them and interprets none of
    # them; the payload puts them into the variable engine as the Wizard source
    # (DESIGN 3.1), where provenance records that they were typed.
    #
    # THEY COME BACK ON A CANCEL TOO. A cancel is not an erasure: what was typed
    # before it is worth logging, and what a cancel MEANS is the caller's
    # decision, not this command's.
    $value = @{}
    if ($null -ne $WizardHost.PSObject.Properties['Value'] -and $null -ne $WizardHost.Value) {
        $value = $WizardHost.Value
    }

    return [pscustomobject] @{
        Action        = $action
        Title         = $Title
        ShellXamlPath = $ShellXamlPath
        PageCount     = @($loaded).Count
        Value         = $value
    }
}
