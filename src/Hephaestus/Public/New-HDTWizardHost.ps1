function New-HDTWizardHost {
    <#
        .SYNOPSIS
            The real IWizardHost: loads XAML with XamlReader and shows the
            window.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER AN EXTERNAL TOOL AND IS DELIBERATELY THIN.
            HDT's only exception to TDD is a thin adapter over
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
                  ONE window whose page is swapped in place, which is the
                  shape MDT's LiteTouch wizard has. The navigator -
                  Step-HDTWizardPage, passed in - decides every move, so page
                  order never enters this adapter.

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

        # WHAT THE TECHNICIAN FILLED IN, read off the controls as each page was
        # left. Show-HDTWizardShell hands it back to the caller, which puts it
        # into the variable engine as the Wizard source (DESIGN 3.1) - so a
        # typed computer name reaches the deployment and the provenance says it
        # was typed.
        #
        # THE WELCOME SCREEN USES THE SAME BAG, and did not until a real boot
        # showed why it had to: that screen answered with an Action alone, so a
        # technician who corrected an unreachable share watched the machine fail
        # on the address that was already wrong. Show fills this from
        # Get-HDTWizardHarvest's list exactly as ShowShell fills it from each
        # page's collect declarations.
        Value  = @{}

        # WHAT A RESOLVED SOURCE PUT IN EACH BOX BEFORE THE TECHNICIAN SAW IT,
        # keyed by control name. Get-HDTWizardSeed fills the boxes from the
        # resolved rules - MDT's behaviour - and every value the wizard collects
        # re-enters the engine as the WIZARD source, the highest precedence in
        # DESIGN 3.1. Without this, a seeded box nobody touched would be
        # collected as though somebody had typed it, and the report would say a
        # name was typed at the bench when a rule on the share produced it.
        #
        # A RESOLVED SOURCE, AND NOT WHATEVER WENT IN THE BOX. A field declares
        # Seed = $true to claim one; Apply below believes nothing that does not.
        # See the comment there for the deployment that bought the distinction.
        #
        # ORDINAL-INSENSITIVE ON THE KEY because a control name is a name; the
        # VALUES are compared case-sensitively, by Test-HDTWizardAnswerChanged.
        Seed   = (New-Object -TypeName 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList (
                [System.StringComparer]::OrdinalIgnoreCase))
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
            if ($null -eq $control) { continue }

            # THE PROPERTY THE FIELD NAMED, defaulting to Text for a producer
            # that predates the pair - a PasswordBox has no Text at all, so a
            # host that always wrote Text could not prefill one.
            $property = 'Text'
            if ($null -ne $current.PSObject.Properties['Property']) {
                $property = [string] $current.Property
            }

            # A FIELD MAY CARRY ROWS AS WELL AS A VALUE - W3's task sequence
            # picker is a field like any other - AND THE ROWS GO FIRST.
            # SelectedValue means nothing until the item carrying that value
            # exists, which is the same order the console's driver list needs.
            if ($null -ne $current.PSObject.Properties['Item']) {

                # ANY ROWS THE PAGE DECLARED ARE CLEARED FIRST, AND A REAL SHARE
                # IS WHY. WPF throws "Items collection must be empty before
                # using ItemsSource" when a ListBox carries inline
                # <ListBoxItem>s, and every page written before W3 carries them
                # - the picker was a hand-typed list. On a share not yet updated
                # that exception is thrown while the wizard is opening, in
                # WinPE, on a machine whose console has just been hidden: a
                # technician gets a black screen instead of a page.
                if ($control.Items.Count -gt 0) { $control.Items.Clear() }

                $control.ItemsSource = @($current.Item)
            }

            # A FIELD MAY BE ROWS AND NOTHING ELSE, and until the Applications
            # page there was no such field so this line ran unconditionally.
            # It threw "The property 'Text' cannot be found on this object"
            # while the page was being built - under Set-StrictMode a field
            # without one is an exception, and an ItemsControl has no Text to
            # write to even if the field carried an empty one.
            #
            # FOUND BY OPENING THE PAGE. Every unit test passed: the field is
            # built by one command and consumed by an adapter nothing calls
            # without a window.
            if ($null -eq $current.PSObject.Properties['Text']) { continue }

            $control.$property = [string] $current.Text

            # REMEMBERED ONLY IF THE FIELD SAYS IT IS A SEED, and that condition
            # is the whole fix. See $service.Seed above: the harvest drops an
            # answer equal to its seed, because a rule shown back to a technician
            # is not something they typed. This recorded EVERY field instead -
            # and a field is not always a rule being shown back. The task
            # sequence picker opened on its first row and the computer name box
            # offers a name built out of the serial; both are values the WIZARD
            # invented, with no provenance worth protecting, and recording them
            # made accepting them indistinguishable from answering nothing. A
            # real machine failed before its first step over the first of those.
            #
            # NOT-A-SEED IS THE DEFAULT, AND THE DIRECTION IS DELIBERATE. A field
            # that says nothing about itself is treated as the wizard's own
            # suggestion, so a producer written tomorrow has to CLAIM a resolved
            # source to be believed. That fails safe: a value collected
            # redundantly deploys the same machine and records Wizard in the
            # provenance, while a value silently dropped is a failed deployment.
            #
            # AND A LATER FIELD CLEARS AN EARLIER SEED. Fields are applied in
            # order and the last write is what the technician sees, so the seed
            # has to describe the last write or it would be compared against a
            # value that is no longer in the box.
            $isSeed = $false
            if ($null -ne $current.PSObject.Properties['Seed']) { $isSeed = [bool] $current.Seed }

            if ($isSeed) {
                $this.Seed[[string] $current.Name] = [string] $current.Text
            } else {
                [void] $this.Seed.Remove([string] $current.Name)
            }
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
        #
        # EVERY PAIR ON THE PAGE, NOT ONE. This block used to name the three
        # controls literally, so a page could carry exactly ONE revealable
        # password - which is why the administrator password page, which has
        # two boxes, carried no eye at all. Get-HDTWizardRevealPair decides
        # which trios a page has and is unit tested against a loaded tree; what
        # is left here is a loop, which is what the adapter exemption is for.
        $revealPair = @(Get-HDTWizardRevealPair -Root $Root)

        if ($revealPair.Count -gt 0) {

            # NO -Page, DELIBERATELY. The eye is on the Welcome window and on
            # two wizard pages, and this used to read the Welcome block by name
            # to find a caption that belongs to none of them in particular. The
            # merged table carries Common, which is where the two shared
            # captions live.
            $string = Get-HDTStringTable
        }

        foreach ($current in $revealPair) {

            # ONE SET OF VARIABLES PER ITERATION, AND THAT IS THE WHOLE TRICK.
            # GetNewClosure captures the values these names hold NOW, so each
            # handler gets its own pair; handlers written against the loop
            # variable itself would every one of them reveal the last pair.
            $toggle = $current.Toggle
            $passwordBox = $current.Password
            $revealBox = $current.Reveal

            # THE TWO WORDS THE TOGGLE SWAPS BETWEEN. It is the one caption on
            # these windows that changes while the window is open, so the table
            # cannot simply be applied to it once - it is read here and the
            # handlers below close over it.
            #
            # KEYED OFF THE TOGGLE'S OWN NAME, FALLING BACK TO THE SHARED PAIR.
            # A per-toggle key was the same defect as the per-toggle FindName
            # above it: every eye added afterwards would have had a blank
            # tooltip until somebody remembered. A page that wants different
            # wording still gets it by naming its own toggle in the table.
            $revealShow = [string] $toggle.ToolTip
            $revealHide = ''

            if ($string.ContainsKey('HDTPasswordReveal.ShowToolTip')) {
                $revealShow = [string] $string['HDTPasswordReveal.ShowToolTip']
            }
            if ($string.ContainsKey('HDTPasswordReveal.HideToolTip')) {
                $revealHide = [string] $string['HDTPasswordReveal.HideToolTip']
            }

            $showKey = '{0}.ToolTip' -f $toggle.Name
            $hideKey = '{0}.HideToolTip' -f $toggle.Name

            if ($string.ContainsKey($showKey)) { $revealShow = [string] $string[$showKey] }
            if ($string.ContainsKey($hideKey)) { $revealHide = [string] $string[$hideKey] }

            # THE SHIPPED CAPTION, PUT ON THE CONTROL RATHER THAN LEFT TO
            # Set-HDTWindowText. The Welcome window's eye carries no ToolTip in
            # its markup at all, and the table used to paint it by control name
            # - which meant the same sentence lived in the table twice, once
            # per eye, and would live there once more for every eye added.
            $toggle.ToolTip = $revealShow

            $toggle.Add_Checked({
                    $revealBox.Text = $passwordBox.Password
                    $passwordBox.Visibility = [System.Windows.Visibility]::Collapsed
                    $revealBox.Visibility = [System.Windows.Visibility]::Visible
                    $toggle.ToolTip = $revealHide
                }.GetNewClosure())

            $toggle.Add_Unchecked({
                    $passwordBox.Password = $revealBox.Text
                    $revealBox.Visibility = [System.Windows.Visibility]::Collapsed
                    $passwordBox.Visibility = [System.Windows.Visibility]::Visible
                    $toggle.ToolTip = $revealShow
                }.GetNewClosure())

            # THE PASSWORD BOX IS ALWAYS THE TRUTH, AND IT WAS NOT.
            # $harvest reads the control the page's collect declaration names -
            # HDTPasswordBox.Password, HDTAdminPasswordBox.Password - and the
            # validator subscribes to PasswordChanged on the same control.
            # Neither knows the reveal box exists. Without this line a password
            # typed with the eye OPEN reached neither: the PasswordBox still
            # held whatever was there before the reveal, so a technician
            # watching themselves type a password pressed Next and shipped a
            # different one, silently, onto the local Administrator account.
            #
            # IT DOES NOT LOOP. Checked writes Reveal.Text from Password, which
            # raises TextChanged, which writes Password back - and a PasswordBox
            # raises PasswordChanged, not TextChanged, so the round trip ends
            # there. Setting .Password is also what makes the validator fire
            # while the eye is open, which is the other half of the same defect.
            $revealBox.Add_TextChanged({
                    $passwordBox.Password = $revealBox.Text
                }.GetNewClosure())
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name Show -Value {
        param([string] $Xaml, [string] $ThemeXaml, [string] $Title, [object[]] $Field, [object[]] $Pane,
            [scriptblock] $CommandPrompt, [object[]] $Collect, [hashtable] $String, [bool] $Foreground)

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        # THE THEME, MERGED THE WAY ShowShell HAS MERGED IT SINCE W2, and the
        # Welcome screen is the last window to get it. It carried its own inline
        # copy of every style it needed - the one screen a palette change in
        # HDTTheme.xaml could not reach - because this method had no theme to
        # merge. The address boxes stayed 32 high while the theme said 34, and
        # nothing failed; it just looked slightly wrong on the first screen a
        # technician sees.
        #
        # AFTER THE LOAD, NOT BEFORE, AND THAT ORDER IS LOAD-BEARING TWICE.
        # A dictionary goes into a window's Resources, so the window has to
        # exist first - and parsing the theme BEFORE this window would poison
        # TextBox.IsReadOnly for it as well (see WinPeUiStack.Contract.Tests).
        # This window is the FIRST XamlReader::Load in the process, so it is
        # the one window that is always parsed clean.
        if (-not [string]::IsNullOrWhiteSpace($ThemeXaml)) {
            $themeReader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $ThemeXaml)
            $window.Resources.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Load($themeReader))
        }

        # THE TEXT, BEFORE ANYTHING IS WRITTEN OVER IT. Show-HDTWizard chose the
        # block; this puts it on the window and reads none of it. Apply comes
        # after, because a field carries what a technician typed and the table
        # carries only what the window says about itself.
        if ($null -ne $String -and $String.Count -gt 0) {
            [void] (Set-HDTWindowText -Root $window -String $String)
        }

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

        # THE FOREGROUND'S OWN STATE, AND WHY A WINDOW NEEDS ANY.
        #
        # A HASHTABLE FOR THE SAME REASON $trip IS ONE in ShowShell:
        # GetNewClosure snapshots values, so a closed-over [bool] would be
        # frozen at $false in every handler forever. The handlers share the
        # reference and mutate through it.
        #
        #   Busy        a force is in flight on this thread; see Add_Deactivated
        #   Suppressed  the technician has taken the front on purpose, and keeps it
        #   LastUtc     when the last force ran, for the cooldown
        $foreground = @{ Busy = $false; Suppressed = $false; LastUtc = [datetime]::MinValue }

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
                @{ Name = 'HDTOpenCmdButton'; Answer = 'CommandPrompt' },

                # THE DEPLOYMENT SUMMARY'S ONE BUTTON. Only HDTFailure.xaml
                # declares it, and a page without it is skipped by the guard
                # below - so this costs every other window nothing.
                @{ Name = 'HDTFinishButton'; Answer = 'Finish' })) {

            $button = $window.FindName([string] $pair.Name)
            if ($null -eq $button) { continue }

            $answer = [string] $pair.Answer

            # GetNewClosure snapshots $answer per iteration; without it every
            # handler would report whatever the loop variable held last.
            $button.Add_Click({
                    $wizardHost.Answer = $answer

                    # AND IT STOPS FIGHTING FOR THE FRONT. Every button here
                    # closes the window, and a closing window still raises
                    # Deactivated - so without this the summary would force
                    # itself back over the command prompt Open CMD had just
                    # launched, on its way out. Set for every answer, because
                    # a window that has been answered has no front to defend.
                    $foreground['Suppressed'] = $true

                    # READ BEFORE IT CLOSES, and read for EVERY answer rather
                    # than only for Next: a technician who typed the right share
                    # and then pressed Open CMD has still told us the right
                    # share. What any of it MEANS is Show-HDTWizard's business
                    # and the payload's; this only reads the named property off
                    # the named control, which is why it may stay untested.
                    foreach ($wanted in @($Collect)) {
                        $control = $window.FindName([string] $wanted.Name)
                        if ($null -eq $control) { continue }

                        $wizardHost.Value[[string] $wanted.Name] = $control.([string] $wanted.Property)
                    }

                    $window.Close()
                }.GetNewClosure())
        }

        # F8 - see ShowShell below for why this key exists at all. It is here as
        # well because the Welcome screen is the window shown when the SHARE
        # CANNOT BE REACHED, which is the single most likely moment in a
        # deployment for a technician to want a prompt.
        if ($null -ne $CommandPrompt) {
            $window.Add_PreviewKeyDown({
                    if ($_.Key -ne [System.Windows.Input.Key]::F8) { return }

                    $_.Handled = $true

                    # THE PROMPT WINS FROM HERE ON, AND WITHOUT THIS LINE THE
                    # WINDOW WOULD NOT LET IT. F8 opens a command prompt and
                    # LEAVES THIS WINDOW UP - the deployment summary stays on
                    # screen behind it by design. The Deactivated handler below
                    # exists to take the front back from the Start menu, and it
                    # cannot tell that flyout apart from the prompt a technician
                    # deliberately opened. So the technician says so here: from
                    # this keypress on nothing re-forces, and the summary is an
                    # ordinary window they can click back to.
                    $foreground['Suppressed'] = $true

                    & $CommandPrompt
                }.GetNewClosure())
        }

        # AND IT COMES TO THE FRONT AS IT APPEARS - BUT ONLY WHEN ASKED.
        #
        # ASKED, AND NOT ALWAYS, BECAUSE THIS RAISE TYPES. Forcing the
        # foreground injects a real Escape and a real Alt (see
        # Get-HDTWindowForegroundSource: without the Alt the request is silently
        # ignored, and without the Escape an already-open Start menu stays open
        # over the window). Those keystrokes go to whatever has focus at that
        # instant, and this same host draws the WinPE wizard - the screens a
        # technician TYPES a computer name and a credential into. A page that
        # has nothing to be behind does not need raising and should not be
        # sending keys, so the caller decides: Show-HDTDeploymentFailure asks
        # for it, the wizard does not.
        #
        # The Deployment Summary is
        # drawn in the FULL OS, on a desktop, under an autologon - and a
        # deployed machine showed the taskbar and the Start menu sitting over
        # it. Topmost is not the fix and is forbidden here: this window's Open
        # CMD button hands the machine to a command prompt, and a topmost window
        # outranks the prompt it just launched
        # (tests/contract/WinPeWindowReach.Contract.Tests.ps1, and the header of
        # HDTFailure.xaml). Forcing the foreground has neither problem - nothing
        # stays raised, so the prompt this window opens takes the front the
        # moment it appears.
        #
        # ContentRendered, NOT Loaded: the handle exists only once the window
        # has been sourced, and Set-HDTWindowForeground reports false rather
        # than acting on a zero. ONCE, never on a timer.
        #
        # -DismissStartMenu because an ALREADY OPEN Start menu is the reported
        # symptom, and nothing but an Escape closes one.
        #
        # SWALLOWED. A window that could not be raised is a window slightly in
        # the wrong place; an exception here would be no window at all, on the
        # screen that exists to tell a technician what happened.
        if ($Foreground) {
            $window.Add_ContentRendered({
                    try {
                        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
                        [void] (Set-HDTWindowForeground -Handle $hwnd -DismissStartMenu)
                        $foreground['LastUtc'] = [datetime]::UtcNow
                    } catch {
                        Write-Verbose ("the window could not be brought to the front: {0}" -f [string] $_.Exception.Message)
                    }
                }.GetNewClosure())

            # AND AGAIN WHENEVER SOMETHING TAKES THE FRONT AWAY.
            #
            # ONCE WAS NOT ENOUGH, AND A PHOTOGRAPH OF A DEPLOYED MACHINE IS WHY.
            # After a successful run the Windows Start menu was drawn straight
            # over this window - heading, log path and Open CMD button all
            # occluded. The taskbar was not the problem and never had been.
            #
            # HWND_TOPMOST CANNOT REACH IT. The Start menu is an
            # ApplicationFrameWindow / XAML host surface that sits ABOVE the
            # topmost band, so re-asserting topmost - the mechanism the progress
            # board uses - loses to it by construction. The only thing that
            # closes one is the Escape that Force already taps.
            #
            # SO THE FIX IS PURELY WHEN. ContentRendered above forces once, as
            # the window appears; a Start menu opened one second later won,
            # because nothing ran again. Deactivated IS that moment: the flyout
            # taking the foreground is exactly what raises it.
            #
            # WHAT MDT DOES INSTEAD, AND WHY HDT DOES NOT. LiteTouch removes the
            # competitor rather than out-ordering it - it re-registers itself
            # under HKLM RunOnce with AsyncRunOnce=0, so Explorer draws NO SHELL
            # AT ALL until the leg finishes, and LTICleanup puts it back. That
            # wins outright, and it was declined deliberately: it also takes the
            # taskbar, which nobody complained about, and a restore that fails
            # leaves a machine with no shell - a far worse outcome than a summary
            # behind a flyout.
            #
            # DEACTIVATED + Force, NOT DEACTIVATED + Raise. Raise is what the
            # progress board gets, and it would be wrong here: this window's Open
            # CMD button and its F8 hand the machine to a command prompt, and a
            # topmost summary outranks the prompt it just launched - the defect
            # HDTFailure.xaml lost its Topmost attribute over. Force leaves
            # nothing raised, so the prompt keeps the front the moment it appears.
            #
            # THREE GUARDS, AND EACH ONE IS A LOOP THAT WOULD OTHERWISE HAPPEN.
            #
            #   Suppressed  the technician opened a prompt or answered a button.
            #               F8 leaves this window UP, so without this the summary
            #               would snatch the foreground back off the prompt it
            #               was asked to open. That is a blocker, not a polish
            #               item, and it is why the flag exists at all.
            #   Busy        Force injects an Alt, and an Alt is itself an
            #               activation change - so the handler that sends one can
            #               be the reason it is entered again. Cleared in a
            #               finally, because a flag left set by a throw would
            #               disable the fix silently for the rest of the run.
            #   LastUtc     the cooldown, and the Busy flag alone does not cover
            #               this: a ping-pong between the shell and this window
            #               happens across SEPARATE message-pump turns, where
            #               nothing is in flight. Three quarters of a second is
            #               far below a person reopening a Start menu on purpose
            #               and far above anything two windows can fight over.
            #
            # SWALLOWED, LIKE THE FORCE ABOVE. A window that could not be raised
            # is slightly in the wrong place; an exception on this thread would
            # be no summary at all, on the screen that exists to say what
            # happened.
            $window.Add_Deactivated({
                    try {
                        if ($foreground['Suppressed']) { return }
                        if ($foreground['Busy']) { return }

                        $now = [datetime]::UtcNow
                        if (($now - $foreground['LastUtc']).TotalMilliseconds -lt 750) { return }

                        $foreground['Busy'] = $true

                        try {
                            $foreground['LastUtc'] = $now
                            $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
                            [void] (Set-HDTWindowForeground -Handle $hwnd -DismissStartMenu)
                        } finally {
                            $foreground['Busy'] = $false
                        }
                    } catch {
                        Write-Verbose ("the window could not be brought back to the front: {0}" -f [string] $_.Exception.Message)
                    }
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
            [scriptblock] $Navigator,
            [scriptblock] $CommandPrompt,
            [hashtable] $String)

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $ShellXaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        # The shell's own text. See Show for why it is applied here and nowhere
        # else.
        if ($null -ne $String -and $String.Count -gt 0) {
            [void] (Set-HDTWindowText -Root $window -String $String)
        }

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

            # THE CURSOR GOES IN THE FIRST BOX. Nothing here ever called Focus()
            # and it showed: an STA probe walking MoveFocus found focus on the
            # WINDOW, with the rail and the page host taking Tab 1 and Tab 2
            # before a field saw Tab 3. Those two are IsTabStop="False" in the
            # markup now; this is the other half.
            #
            # THE ORDER IS Get-HDTWizardFocus'S, NOT THIS METHOD'S. All that
            # happens here is taking the first name that answers, is enabled and
            # will accept focus - Computer Details disables half of itself, so
            # the first candidate is regularly one that cannot have it.
            #
            # ON THE DISPATCHER, AT Loaded PRIORITY. The page has only just been
            # put into the tree; Focus() before WPF has loaded it silently does
            # nothing, which is the same screen as never calling it.
            foreach ($wanted in @(Get-HDTWizardFocus -Page $Current.Page)) {

                $candidate = $pageRoot.FindName([string] $wanted)
                if ($null -eq $candidate) { continue }
                if (-not $candidate.IsEnabled) { continue }
                if (-not $candidate.Focusable) { continue }

                [void] $candidate.Dispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::Loaded,
                    [action] { [void] $candidate.Focus() }.GetNewClosure())

                break
            }

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

            # A PasswordBox DOES NOT HAVE .Text, AND READING IT UNDER STRICT
            # MODE THROWS. The administrator password page is the first one to
            # watch a box that is not a TextBox, and a missing property here
            # would kill the page rather than fail to validate it.
            $readControl = {
                param($Control)

                if ($null -eq $Control) { return '' }
                if ($Control -is [System.Windows.Controls.PasswordBox]) { return [string] $Control.Password }

                # A LIST ANSWERS WITH WHICHEVER ROW IS LIT, AND IT HAS NO .Text
                # AT ALL. Reading one under Set-StrictMode is an exception, not
                # an empty string, so the task sequence page would have died on
                # load rather than failed to validate - the same shape as the
                # PasswordBox line above it, found the same way.
                #
                # SelectedValue AND NOT SelectedItem, because that is what the
                # page collects: SelectedValuePath="Id" makes it the sequence
                # id, which is the thing being judged.
                if ($Control -is [System.Windows.Controls.Primitives.Selector]) {
                    return [string] $Control.SelectedValue
                }

                return [string] $Control.Text
            }

            # THE SECOND BOX, WHERE THERE IS ONE. Only a rule that compares two
            # controls declares it; for every other page this stays null and
            # the validator is called with one argument exactly as before.
            $confirmed = $null
            $confirmName = ''
            if ($null -ne $Current.Page.Validate.PSObject.Properties['Confirm']) {
                $confirmName = [string] $Current.Page.Validate.Confirm
            }
            if (-not [string]::IsNullOrWhiteSpace($confirmName)) {
                $confirmed = $pageRoot.FindName($confirmName)
            }

            # THE TWO CONTROLS THE VERDICT IS PAINTED ON, TAKEN AS LOCALS OF
            # THIS SCOPE FIRST - AND EVERY VALIDATE RULE THIS ENGINE HAS WAS
            # DECORATIVE UNTIL THEY WERE. $judge below is a closure created
            # INSIDE $render, which is itself a closure, and GetNewClosure
            # copies the variables of the scope it is created in - $render's -
            # and NOT the ones $render closed over from the method around it. So
            # $messageText and $nextButton arrived at $judge as $null, both
            # writes were skipped by their own null guards, and the verdict went
            # nowhere: an empty computer name, two administrator passwords that
            # did not match and a task sequence nobody had chosen all left Next
            # open and the message line blank.
            #
            # FOUND BY PHOTOGRAPHING THE PAGE, not by a test. Every unit test
            # passes: they assert the validator SHOW-HDTWIZARDSHELL resolves,
            # which is right, and this window is the only place the two halves
            # ever meet.
            $judgeMessage = $messageText
            $judgeNext = $nextButton

            $judge = {
                $judgement = & $validator (& $readControl $watched) (& $readControl $confirmed)

                if ($null -ne $judgeMessage) {
                    # THE SEVERITY GOES IN Tag AND THE MARKUP PAINTS IT. A
                    # warning is not a refusal and must not be the same red;
                    # deciding that here would put the palette back in the
                    # engine, which is the thing the rail template exists to
                    # avoid.
                    $judgeMessage.Tag = [string] $judgement.Severity
                    $judgeMessage.Text = [string] $judgement.Reason
                }

                # NEXT IS THE GATE, AND ONLY A REFUSAL CLOSES IT. IsValid is
                # false only for a real refusal - a name DNS cannot carry is
                # still a legal computer name, and blocking it here would stop a
                # deployment over something Windows itself permits.
                if ($null -ne $judgeNext) { $judgeNext.IsEnabled = [bool] $judgement.IsValid }
            }.GetNewClosure()

            # A PasswordBox RAISES PasswordChanged, NOT TextChanged, and asking
            # it for TextChanged is not a no-op - it throws:
            #
            #   [System.Windows.Controls.PasswordBox] does not contain a method
            #   named 'Add_TextChanged'
            #
            # which took the whole wizard down the moment the administrator
            # password page was wired, on a real machine, one click after the
            # page before it. Reading the value was already type-aware here and
            # the subscription was not, which is the half a change that looks
            # finished.
            $subscribe = {
                param($Control)

                if ($null -eq $Control) { return }

                if ($Control -is [System.Windows.Controls.PasswordBox]) {
                    $Control.Add_PasswordChanged($judge)
                    return
                }

                # A ListBox RAISES SelectionChanged AND HAS NO Add_TextChanged
                # EITHER, so this is the same trap one control type further on.
                # It is what gates the task sequence page: nothing is
                # preselected any more, so Next opens only when a row is lit -
                # and it has to reopen the moment one is, or the technician is
                # left looking at a choice they have already made under a button
                # that still refuses them.
                if ($Control -is [System.Windows.Controls.Primitives.Selector]) {
                    $Control.Add_SelectionChanged($judge)
                    return
                }

                $Control.Add_TextChanged($judge)
            }

            & $subscribe $watched

            # THE CONFIRM BOX TOO, OR THE PAGE JUDGES HALF OF ITSELF. Typing
            # the password and then correcting the confirmation would leave the
            # Next button reading a verdict from two keystrokes ago.
            & $subscribe $confirmed

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

                # A PAGE OF TICKS, WHICH IS NOT ONE PROPERTY ON ONE CONTROL.
                # Every declaration below reads a single value; the Applications
                # page answers with a column, and it shipped collecting NOTHING
                # rather than have that answer quietly dropped. The join, the
                # order and what to do with a row carrying no id are decided by
                # Get-HDTWizardSelection - this reads the rows and assigns.
                #
                # ItemsSource, NOT THE VISUAL TREE. The markup binds each
                # CheckBox TwoWay to its row's IsSelected, so the ticks are on
                # the objects the host handed over and no walk is needed.
                if ($null -ne $declaration.PSObject.Properties['Select'] -and
                    ([string] $declaration.Select) -eq 'many') {

                    $trip.Value[[string] $declaration.Variable] =
                        Get-HDTWizardSelection -Row @($control.ItemsSource)

                    continue
                }

                $property = 'Text'
                if (-not [string]::IsNullOrWhiteSpace([string] $declaration.Property)) { $property = [string] $declaration.Property }

                $raw = [string] $control.$property

                # A RULE SHOWN BACK IS NOT AN ANSWER. The box may have been
                # seeded from the resolved variables (Get-HDTWizardSeed); if it
                # comes back exactly as it went in, the technician read it and
                # moved on, and collecting it would re-enter the value as the
                # WIZARD source and overwrite the rule's own provenance. The
                # deployment would be identical and the report would say the
                # value was typed at the bench. Edit the box - including
                # clearing it - and it is an answer.
                $seeded = $null
                if ($wizardHost.Seed.ContainsKey([string] $declaration.Control)) {
                    $seeded = [string] $wizardHost.Seed[[string] $declaration.Control]
                }

                if (-not (Test-HDTWizardAnswerChanged -Seeded $seeded -Answered $raw)) { continue }

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

        # F8, AND IT IS NOT A BUTTON. MDT's boot image has "Enable command
        # support (testing only)" and F8 is what it buys: a command prompt ON
        # TOP of what is running. Nothing in WinPE provides that key - ConfigMgr's
        # boot shell implements it and so does MDT's, so this one does too.
        #
        # PreviewKeyDown ON THE WINDOW, so it fires wherever the focus is. A
        # technician who needs a prompt is halfway through typing in a box, and
        # a handler on the page would never see the key.
        #
        # HANDLED, SO NOTHING ELSE SEES IT. Left unhandled, F8 keeps travelling
        # and a control that has its own meaning for it acts as well.
        #
        # THE WINDOW DOES NOT CLOSE, which is the whole difference from the Open
        # CMD button below. F8 opens a prompt beside the wizard; the technician
        # closes the prompt and is still on the same page with everything they
        # had typed. A key that ended the deployment would be a trap.
        if ($null -ne $CommandPrompt) {
            $window.Add_PreviewKeyDown({
                    if ($_.Key -ne [System.Windows.Input.Key]::F8) { return }

                    $_.Handled = $true
                    & $CommandPrompt
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

        # THE LAST PAGE IS HARVESTED ON THE WAY OUT. Cancel and Open CMD close
        # the window without navigating, and Deploy closes it from inside the
        # Next handler - so without this, whatever was typed on the page the
        # technician was standing on when they left is read off a control that
        # is about to stop existing, or not at all.
        & $harvest

        $this.Value = $trip.Value

        return [string] $this.Answer
    }

    return $service
}
