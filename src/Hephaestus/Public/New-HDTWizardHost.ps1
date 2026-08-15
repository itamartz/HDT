function New-HDTWizardHost {
    <#
        .SYNOPSIS
            The real IWizardHost: loads XAML with XamlReader and shows the
            window.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER AN EXTERNAL TOOL AND IS DELIBERATELY THIN.
            CLAUDE.md rule 1's only exception to TDD is a thin adapter over
            something that cannot be faked - here WPF itself - and THE PRICE OF
            THAT EXEMPTION IS THAT THE ADAPTER MUST HAVE NOTHING IN IT WORTH
            TESTING. That is a condition, not a description, and this file
            stopped meeting it once: it read the network, decided which named
            boxes were present, decided what belonged in each, and swallowed
            every failure. The first time it was ever really executed, it
            crashed - on a bench, in WinPE, which is exactly where an untested
            adapter's bugs get found.

            SO THE DECISIONS LEFT. Get-HDTWizardField works out what every box
            should say and is unit tested against fakes; Show-HDTWizard owns
            what an answer means and is unit tested against
            New-HDTFakeWizardHost. What is left here is load the markup, set
            text by name, attach handlers by name, show it - and that is what
            the exemption was written for.

            WPF IN WinPE IS NOT A GUESS. friendsOfMDT/PSD ships
            Scripts/PSDWizard.xaml and loads it exactly this way inside WinPE
            (PSDWizardNew.psm1), which is the proof that PresentationFramework
            is usable there. What makes it possible is WinPE-NetFx, one of the
            six required components Get-HDTBootImageComponent always injects -
            so no boot image change is needed to show a window.

            XamlReader::Load PARSES MARKUP ONLY. There is no compiler in WinPE,
            so the window carries no x:Class and no code-behind; handlers are
            attached here, by name, after the tree exists. Every name this file
            reaches for must exist in a shipped window, and
            tests/contract/WinPeUiStack.Contract.Tests.ps1 asserts that - a name
            nothing answers to is a control that silently does nothing on the
            one machine nobody can debug.

            THE DEFAULT ANSWER IS EMPTY, NOT 'Cancel'. A window closed with the
            X never runs any handler, so this returns what it was given -
            nothing - and Show-HDTWizard is what turns that into a Cancel. The
            adapter does not get to make that decision, because then two places
            would have an opinion about what a dismissed window means.

        .OUTPUTS
            A PSCustomObject with:

              Show(xaml, title, field, pane)
                  one window, one answer.

              ShowShell(shellXaml, themeXaml, title, state, field, pane, navigator)
                  MDT's LiteTouch shell: ONE window whose page is swapped in
                  place. The navigator - Step-HDTWizardPage, passed in - decides
                  every move, so page order never enters this adapter.

              Apply(root, field, pane)
                  the by-name work both of them do, and that ShowShell repeats
                  for each page it swaps in.

            Show and ShowShell return 'Next', 'Cancel', 'CommandPrompt', or an
            empty string.

        .EXAMPLE
            Show-HDTWizard -XamlPath 'X:\HDT\UI\HDTWizard.xaml' -WizardHost (New-HDTWizardHost)

        .EXAMPLE
            $field = Get-HDTWizardField -NetworkConfiguration (Get-HDTNetworkConfiguration)
            Show-HDTWizard -XamlPath 'X:\HDT\UI\HDTWelcome.xaml' -Field $field

            The Welcome screen with the lease the machine actually got in it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. Show is where a window appears, and it is a method.')]
    # ShowShell's Field, Pane and Navigator ARE used - inside the $render and
    # Add_Click scriptblocks, every one of which is .GetNewClosure(). The
    # analyzer does not follow a parameter into a closure and reports all three
    # as unused. Removing them to satisfy it would remove the navigation.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Used inside GetNewClosure scriptblocks, which PSReviewUnusedParameter does not follow.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Answer = ''
    }

    # EVERYTHING DONE BY NAME, IN ONE PLACE. Both Show and ShowShell fill boxes,
    # collapse panes and wire the password eye, and ShowShell has to do it again
    # for every page it swaps in - so it lives here rather than being written
    # twice and drifting once.
    #
    # $Root IS NOT ALWAYS THE WINDOW. A page loaded into HDTPageHost carries its
    # own name scope, so the window cannot find the controls inside it; the page
    # root can. Passing the root in is what makes one method serve both.
    $service | Add-Member -MemberType ScriptMethod -Name Apply -Value {
        param([object] $Root, [object[]] $Field, [object[]] $Pane)

        # WHAT GOES IN THE BOXES WAS DECIDED SOMEWHERE ELSE. Get-HDTWizardField
        # works it out - the lease, the share, the account - and this applies it
        # by name and interprets none of it. That is what put this adapter back
        # inside its own TDD exemption: the exemption is conditional on being
        # branch-free, and the version that read the network here was not.
        #
        # A NAME NOTHING ANSWERS TO IS SKIPPED, because the same host shows
        # every page and no page has all the controls.
        foreach ($current in @($Field)) {
            $control = $Root.FindName([string] $current.Name)
            if ($null -ne $control) { $control.Text = [string] $current.Text }
        }

        # WHICH PANES EXIST WAS ALSO DECIDED SOMEWHERE ELSE. Get-HDTWizardSkip
        # resolves MDT's Skip* rules and hands over Visible flags, so this never
        # has to reason about the word "skip".
        #
        # COLLAPSED, NOT HIDDEN: Visibility.Hidden leaves the space behind, so
        # a screen with two panes turned off would be mostly gap. Collapsed
        # takes the space back and the remaining panes close up.
        foreach ($current in @($Pane)) {
            $control = $Root.FindName([string] $current.Name)
            if ($null -eq $control) { continue }

            $control.Visibility = [System.Windows.Visibility]::Collapsed
            if ($current.Visible) { $control.Visibility = [System.Windows.Visibility]::Visible }
        }

        # THE EYE, AND WHY IT IS WIRED HERE RATHER THAN IN THE MARKUP.
        # PasswordBox.Password is not a DependencyProperty, so it cannot be
        # bound, styled or DataTriggered - there is no declarative way to reveal
        # it, and there is no code-behind to put one in. So the markup carries
        # two boxes in one cell and this swaps which is visible, copying the
        # text across so the technician never loses what they typed.
        #
        # BOTH DIRECTIONS, because a password typed while revealed has to
        # survive being hidden again just as much as the other way round.
        $revealToggle = $Root.FindName('HDTPasswordRevealToggle')
        $passwordBox = $Root.FindName('HDTPasswordBox')
        $revealBox = $Root.FindName('HDTPasswordRevealBox')

        if ($null -ne $revealToggle -and $null -ne $passwordBox -and $null -ne $revealBox) {

            $revealToggle.Add_Checked({
                    $revealBox.Text = $passwordBox.Password
                    $passwordBox.Visibility = [System.Windows.Visibility]::Collapsed
                    $revealBox.Visibility = [System.Windows.Visibility]::Visible
                    $revealToggle.ToolTip = 'Hide the password'
                }.GetNewClosure())

            $revealToggle.Add_Unchecked({
                    $passwordBox.Password = $revealBox.Text
                    $revealBox.Visibility = [System.Windows.Visibility]::Collapsed
                    $passwordBox.Visibility = [System.Windows.Visibility]::Visible
                    $revealToggle.ToolTip = 'Show the password'
                }.GetNewClosure())
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name Show -Value {
        param([string] $Xaml, [string] $Title, [object[]] $Field, [object[]] $Pane)

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        $window.Title = $Title

        $this.Answer = ''

        # THE HOST, CAPTURED BY NAME. Inside an Add_Click handler $this is the
        # BUTTON that raised the event, not this object - and the enclosing
        # function's $service is not in scope inside a ScriptMethod at all, so
        # the handlers below were closing over a variable that did not exist.
        # Under StrictMode that throws, which is exactly what it did the first
        # time this adapter was ever really run.
        #
        # W1 did not catch it because W1's WinPE probe loads the XAML itself to
        # answer "does WPF render here"; the desktop tool is the first thing to
        # go through this host end to end. An adapter is exempt from unit tests
        # (CLAUDE.md rule 1) precisely because it is thin - so the first real
        # execution IS its test, and this is what that test found.
        $wizardHost = $this

        $this.Apply($window, $Field, $Pane)

        # DRAG BY THE BANNER. WindowStyle=None removes the title bar - which is
        # right for WinPE, where an X is a third way out of a deployment wizard -
        # but it also removes the thing you grab to move the window. A banner
        # that answers DragMove gives that back without giving back the X.
        #
        # OPTIONAL BY DESIGN: a page with no HDTDragBanner simply cannot be
        # moved, which is fine on a machine with nothing else on screen.
        $banner = $window.FindName('HDTDragBanner')
        if ($null -ne $banner) {
            $banner.Add_MouseLeftButtonDown({
                    # DragMove throws unless the primary button is genuinely
                    # down, and a stray synthetic event would otherwise take the
                    # whole wizard down with it.
                    if ($_.ButtonState -eq 'Pressed') { $window.DragMove() }
                }.GetNewClosure())
        }

        # THE BUTTON MAP, and it is the whole of what this host decides: which
        # named control reports which answer. Show-HDTWizard owns what those
        # answers MEAN, including that anything else is a Cancel - so a page
        # missing a button simply cannot produce that answer, rather than
        # producing a different one.
        foreach ($pair in @(
                @{ Name = 'HDTNextButton'; Answer = 'Next' },
                @{ Name = 'HDTCancelButton'; Answer = 'Cancel' },
                @{ Name = 'HDTOpenCmdButton'; Answer = 'CommandPrompt' })) {

            $button = $window.FindName([string] $pair.Name)
            if ($null -eq $button) { continue }

            $answer = [string] $pair.Answer

            # GetNewClosure snapshots $answer per iteration; without it every
            # handler would report whatever the loop variable held last.
            $button.Add_Click({
                    $wizardHost.Answer = $answer
                    $window.Close()
                }.GetNewClosure())
        }

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    # THE MULTI-PAGE SHELL. Show opens a window and reports a button; this opens
    # HDTWizardShell.xaml ONCE and swaps the page inside it - MDT's LiteTouch
    # behaviour, and the reason a technician can press Back without the window
    # closing and reopening underneath them.
    #
    # IT DECIDES NOTHING ABOUT ORDER. Step-HDTWizardPage is handed in as
    # $Navigator and answers "which page now, what does the rail show, is Back
    # available, what does Next say, is this the end" - so page order never
    # enters this adapter, which is the condition of its TDD exemption
    # (CLAUDE.md rule 1). What is left here is: load markup, set things by name,
    # attach handlers, show it.
    $service | Add-Member -MemberType ScriptMethod -Name ShowShell -Value {
        param(
            [string] $ShellXaml,
            [string] $ThemeXaml,
            [string] $Title,
            [object] $State,
            [object[]] $Field,
            [object[]] $Pane,
            [scriptblock] $Navigator)

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $ShellXaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        $window.Title = $Title

        # THE THEME IS MERGED AT RUNTIME, NOT BY ResourceDictionary Source=.
        # A Source= reference is a second file that must reach the RAM disk
        # intact, and a half-copied one is a XamlParseException where a wizard
        # should be. Merging here means the shell's markup names no other file
        # at all - which is what WinPeUiStack.Contract.Tests.ps1 enforces.
        if (-not [string]::IsNullOrWhiteSpace($ThemeXaml)) {
            $themeReader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $ThemeXaml)
            $window.Resources.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Load($themeReader))
        }

        $this.Answer = ''
        $wizardHost = $this

        # A HASHTABLE, BECAUSE GetNewClosure SNAPSHOTS. The click handlers below
        # have to see the CURRENT page, not the one that was current when they
        # were attached - and a closed-over [int] would be frozen at 0 forever,
        # so Next would walk from page one every time.
        #
        # Closing IS THE WIZARD SAYING "THIS ONE IS MINE". See the Closing
        # handler below: every close this window did not ask for is refused.
        # Value IS WHAT THE TECHNICIAN HAS FILLED IN SO FAR, and Root is the
        # page it is currently on screen in - the only place those controls can
        # be read from, because a loaded page has its own name scope.
        $trip = @{ State = $State; Closing = $false; Value = @{}; Root = $null }

        # ALT+F4 IS THE ONLY WAY OUT LEFT, AND IT IS NOT ONE. WindowStyle=None
        # already took the title bar and its X away - right for WinPE, where a
        # deployment wizard should not have a corner that makes it disappear -
        # but Alt+F4 still closed it, and a technician who does that in WinPE
        # lands on the console the payload hid behind the window.
        #
        # IT WAS NEVER DANGEROUS: Show-HDTWizardShell reads a window that
        # answered nothing as Cancel and never as Next, so a dismissed wizard
        # could not start a deployment. What it was is UNACCOUNTABLE - a window
        # that vanished with nothing anywhere recording why. Now it can only
        # leave through Cancel, Open CMD or Deploy, each of which reports an
        # answer the payload acts on.
        #
        # ONLY THE SHELL. Show above still closes on WM_CLOSE, deliberately:
        # tests/e2e/payload/Start-HDTWizardProbe.ps1 dismisses the Welcome
        # screen exactly that way in an unattended lab run, and asserts the
        # answer is Cancel. Refusing it there would hang the probe rather than
        # protect anything.
        $window.Add_Closing({
                if (-not $trip.Closing) { $_.Cancel = $true }
            }.GetNewClosure())

        $heading = $window.FindName('HDTPageHeading')
        $subheading = $window.FindName('HDTPageSubheading')
        $pageHost = $window.FindName('HDTPageHost')
        $pageList = $window.FindName('HDTPageList')
        $backButton = $window.FindName('HDTBackButton')
        $nextButton = $window.FindName('HDTNextButton')
        $messageText = $window.FindName('HDTMessageText')

        # RENDER ONE STATE. Everything it touches was decided by the navigator;
        # nothing here chooses what to show, only where to put it.
        $render = {
            param([object] $Current)

            if ($null -ne $heading) { $heading.Text = [string] $Current.Heading }
            if ($null -ne $subheading) { $subheading.Text = [string] $Current.Subheading }
            if ($null -ne $pageList) { $pageList.ItemsSource = @($Current.Rail) }
            if ($null -ne $backButton) { $backButton.IsEnabled = [bool] $Current.BackEnabled }
            if ($null -ne $nextButton) { $nextButton.Content = [string] $Current.NextCaption }

            # EVERY PAGE STARTS CLEAN. A message left over from the page before
            # would accuse this one of a fault it does not have, and a Next left
            # disabled by an earlier page's refusal would strand the technician
            # on a page with nothing wrong with it - with no way to fix it,
            # because the box that was refused is on a different page.
            if ($null -ne $messageText) { $messageText.Text = '' }
            if ($null -ne $nextButton) { $nextButton.IsEnabled = $true }

            if ($null -eq $pageHost -or $null -eq $Current.Page) { return }

            # THE PAGE CARRIES ITS OWN NAME SCOPE once it is loaded, so the
            # window cannot find the controls inside it and Apply is given the
            # page root instead. Fields and panes are re-applied on every swap
            # because a page reached twice - Back, then Next - is parsed twice.
            $pageReader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] ([string] $Current.Page.Xaml))
            $pageRoot = [System.Windows.Markup.XamlReader]::Load($pageReader)

            $wizardHost.Apply($pageRoot, $Field, $Pane)

            $pageHost.Content = $pageRoot
            $trip.Root = $pageRoot

            # THE SUMMARY'S ROWS ARE COMPUTED BY THE NAVIGATOR, NOT HERE. This
            # puts them where the page said to put them and nothing else - the
            # same ItemsSource mechanism the rail uses, for the same reason.
            if ($null -ne $Current.Page.Summary) {

                $rowControl = $pageRoot.FindName([string] $Current.Page.Summary.RowControl)
                if ($null -ne $rowControl) { $rowControl.ItemsSource = @($Current.SummaryRow) }

                $snippetControl = $pageRoot.FindName([string] $Current.Page.Summary.SnippetControl)
                if ($null -ne $snippetControl) { $snippetControl.Text = [string] $Current.SummarySnippet }
            }

            # WHAT THE PAGE SAID IT VALIDATES. The page named a control and a
            # rule; Show-HDTWizardShell resolved the rule to this scriptblock.
            # This runs it and paints the answer, and knows nothing about
            # computer names, lengths or legal characters.
            #
            # ON EVERY KEYSTROKE, AND ONCE BEFORE ANY. A box that is wrong the
            # moment the page opens - empty, or prefilled from a rule that built
            # too long a name - must say so then, not after the technician has
            # typed and deleted a character to find out.
            $validator = $null
            if ($null -ne $Current.Page.PSObject.Properties['Validator']) { $validator = $Current.Page.Validator }

            if ($null -eq $validator -or $null -eq $Current.Page.Validate) { return }

            $watched = $pageRoot.FindName([string] $Current.Page.Validate.Control)
            if ($null -eq $watched) { return }

            $judge = {
                $judgement = & $validator ([string] $watched.Text)

                if ($null -ne $messageText) {
                    # THE SEVERITY GOES IN Tag AND THE MARKUP PAINTS IT. A
                    # warning is not a refusal and must not be the same red;
                    # deciding that here would put the palette back in the
                    # engine, which is the thing the rail template exists to
                    # avoid.
                    $messageText.Tag = [string] $judgement.Severity
                    $messageText.Text = [string] $judgement.Reason
                }

                # NEXT IS THE GATE, AND ONLY A REFUSAL CLOSES IT. IsValid is
                # false only for a real refusal - a name DNS cannot carry is
                # still a legal computer name, and blocking it here would stop a
                # deployment over something Windows itself permits.
                if ($null -ne $nextButton) { $nextButton.IsEnabled = [bool] $judgement.IsValid }
            }.GetNewClosure()

            $watched.Add_TextChanged($judge)
            & $judge

            # A CHARACTER THAT CANNOT BE IN THE ANSWER CANNOT BE TYPED INTO THE
            # BOX. The page said RestrictInput, which means "judge a keystroke
            # with the same rule" - and the rule is the only place the legal
            # characters are written down, so the keyboard is not checking
            # against a second list that could disagree with the first.
            #
            # PreviewTextInput IS BEFORE THE CHARACTER LANDS, which is the whole
            # point: Handled = true and it never appears. TextChanged would fire
            # after, leaving the technician to watch the wizard delete what they
            # just typed.
            #
            # IT COVERS PASTE TOO, because a pasted block is judged whole - one
            # illegal character refuses the paste rather than half-applying it.
            if (-not $Current.Page.RestrictInput) { return }

            $watched.Add_PreviewTextInput({
                    $_.Handled = -not [bool] (& $validator ([string] $_.Text)).IsValid
                }.GetNewClosure())

            # SPACE ARRIVES AS A KEY, NOT AS TEXT INPUT, on a TextBox - it is
            # handled by the control before PreviewTextInput sees it, so a space
            # would be the one illegal character that still got in.
            $watched.Add_PreviewKeyDown({
                    if ($_.Key -eq [System.Windows.Input.Key]::Space) { $_.Handled = $true }
                }.GetNewClosure())
        }.GetNewClosure()

        # WHAT THIS PAGE WAS FILLED IN WITH, READ BEFORE LEAVING IT. The page
        # declared the control, the property to read and the variable it fills,
        # so a ListBox and a TextBox are the same thing here - a named property
        # on a named control. Nothing in this adapter knows what a task sequence
        # or a computer name is.
        #
        # ON THE WAY OUT, NOT ON EVERY KEYSTROKE: the page is about to be
        # replaced and its controls are about to stop existing, and a value
        # captured then is the one the technician settled on.
        $harvest = {
            if ($null -eq $trip.Root -or $null -eq $trip.State.Page) { return }

            $collect = $trip.State.Page.Collect
            if ($null -eq $collect) { return }

            # ONE PAGE, SEVERAL VARIABLES. MDT's Computer Details pane collects
            # a name, a domain or a workgroup, an OU and the account that joins.
            foreach ($declaration in @($collect)) {

                $control = $trip.Root.FindName([string] $declaration.Control)
                if ($null -eq $control) { continue }

                # A DISABLED CONTROL COLLECTS NOTHING, and this is not a
                # nicety. The Computer Details page offers a domain OR a
                # workgroup and disables whichever was not chosen; without this,
                # a machine joining corp.contoso.com also wrote
                # HDTJoinWorkgroup: WORKGROUP into the summary - the box's own
                # default, which the technician never saw, never chose and could
                # not have removed. A rules.yaml carrying both is a rules.yaml
                # that says two contradictory things about one machine.
                #
                # AND IT NEEDS NO NEW DECLARATION. The markup already disables
                # the half that was not chosen, declaratively, off the radio -
                # so the fact is already on the page and this reads it rather
                # than restating it in PowerShell.
                if (-not $control.IsEnabled) { continue }

                $property = 'Text'
                if (-not [string]::IsNullOrWhiteSpace([string] $declaration.Property)) { $property = [string] $declaration.Property }

                $raw = [string] $control.$property

                # ONE BOX, TWO VARIABLES. The join account is typed as
                # CORP\svc-hdt-join and DESIGN 4.5.3 wants HDTDomainAdmin and
                # HDTDomainAdminDomain out of it. The splitting is
                # Split-HDTAccountName's, resolved by Show-HDTWizardShell; this
                # calls it and puts the parts where the declaration says.
                $splitter = $null
                if ($null -ne $declaration.PSObject.Properties['Splitter']) { $splitter = $declaration.Splitter }

                if ($null -ne $splitter) {
                    $part = & $splitter $raw

                    $domain = [string] $part.Domain

                    # WHERE THE ACCOUNT'S DOMAIN COMES FROM, MOST SPECIFIC
                    # FIRST:
                    #
                    #   1. a DOMAIN\ prefix the technician typed. It wins over
                    #      the box below, following the rule
                    #      Get-HDTWizardCredential already set: "a UserID that
                    #      already carries a domain is left alone", so
                    #      'CORP\svc' never becomes 'CORP\CORP\svc'.
                    #   2. what the account-domain box was filled in with. It
                    #      is collected first, so it is already in the bag.
                    #   3. the domain being joined - because a bare account
                    #      belongs to it, and that fact is on this same page.
                    #
                    # EMPTY NEVER OVERWRITES A REAL ANSWER. Without the check
                    # against the bag, a technician who filled the box and typed
                    # a bare account would have their box erased by the split.
                    if ([string]::IsNullOrWhiteSpace($domain)) {

                        $already = ''
                        if ($trip.Value.ContainsKey([string] $declaration.SplitVariable)) {
                            $already = [string] $trip.Value[[string] $declaration.SplitVariable]
                        }

                        if (-not [string]::IsNullOrWhiteSpace($already)) {
                            $domain = $already
                        } elseif (-not [string]::IsNullOrWhiteSpace([string] $declaration.SplitDefaultFrom)) {
                            $from = [string] $declaration.SplitDefaultFrom
                            if ($trip.Value.ContainsKey($from)) { $domain = [string] $trip.Value[$from] }
                        }
                    }

                    $trip.Value[[string] $declaration.Variable] = [string] $part.User
                    $trip.Value[[string] $declaration.SplitVariable] = $domain
                    continue
                }

                $trip.Value[[string] $declaration.Variable] = $raw
            }
        }.GetNewClosure()

        & $render $trip.State

        # DRAG BY THE BANNER, exactly as Show does it: WindowStyle=None takes
        # the title bar away, and with it the thing you grab to move the window.
        $banner = $window.FindName('HDTDragBanner')
        if ($null -ne $banner) {
            $banner.Add_MouseLeftButtonDown({
                    if ($_.ButtonState -eq 'Pressed') { $window.DragMove() }
                }.GetNewClosure())
        }

        # NAVIGATION. Back and Next ask the navigator and re-render; they are
        # the only two buttons that do not end the window - except for the one
        # Next that does, which is the Next the navigator calls Done.
        foreach ($pair in @(
                @{ Name = 'HDTBackButton'; Action = 'Back' },
                @{ Name = 'HDTNextButton'; Action = 'Next' })) {

            $button = $window.FindName([string] $pair.Name)
            if ($null -eq $button) { continue }

            $action = [string] $pair.Action

            $button.Add_Click({
                    & $harvest
                    $moved = & $Navigator $trip.State.Index $action $trip.Value

                    # DONE IS THE ONLY WAY THIS WINDOW REPORTS 'Next', and the
                    # navigator is the only thing that says Done. A shell that
                    # answered Next on any click of the Next button would start
                    # a deployment from page one.
                    if ($moved.Done) {
                        $wizardHost.Answer = 'Next'
                        $trip.Closing = $true
                        $window.Close()
                        return
                    }

                    $trip.State = $moved
                    & $render $moved
                }.GetNewClosure())
        }

        # LEAVING. Cancel and Open CMD are not navigation - they close the
        # window and report what was asked for. Show-HDTWizardShell owns what
        # those answers mean, including that anything else is a Cancel.
        foreach ($pair in @(
                @{ Name = 'HDTCancelButton'; Answer = 'Cancel' },
                @{ Name = 'HDTOpenCmdButton'; Answer = 'CommandPrompt' })) {

            $button = $window.FindName([string] $pair.Name)
            if ($null -eq $button) { continue }

            $answer = [string] $pair.Answer

            $button.Add_Click({
                    $wizardHost.Answer = $answer
                    $trip.Closing = $true
                    $window.Close()
                }.GetNewClosure())
        }

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    return $service
}
