# THE UI STACK THAT SHIPS INTO THE BOOT IMAGE IS WPF, AND ONLY WPF.
#
# WHY THIS IS A CONTRACT. WinPE carries what WinPE-NetFx puts there. WPF -
# PresentationFramework, PresentationCore, WindowsBase - is present because that
# component is one of the six Get-HDTBootImageComponent always injects, and the
# PSD reference implementation proves the stack works there - NOTICE.md carries
# that attribution, and this file derives no code, so it must not name the
# project in a way that reads as one. System.Windows.Forms is NOT
# guaranteed by it. A window that mixes the two builds and unit-tests perfectly
# on a developer machine, where both are installed, and then fails on the one
# machine that matters - in WinPE, on a bench, with a technician watching.
#
# It is easy to reach for by accident: DoEvents is the reflex answer to "pump
# the message loop", and it is a WinForms call. The first draft of
# tests/e2e/payload/Start-HDTWizardProbe.ps1 used exactly that, and it would
# have failed in WinPE rather than on the machine that wrote it.
#
# SCOPED TO src/, DELIBERATELY. tests/helpers runs on the DEVELOPER'S machine -
# Save-HDTLabVmScreen turns Hyper-V thumbnail bytes into a PNG with
# System.Drawing and never goes near a boot image - so scanning the whole
# repository would fail on code that is already correct, and a contract that
# cries wolf is one somebody deletes.
#
# ANTI-VACUITY. "No file references X" is trivially true of no files, which is
# the shape SPIKES S9.15b records, so the scan asserts a floor on what it read
# before it asserts what it did not find.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # SCOPED TO THE ENGINE, NOT ALL OF src.
    $script:sourceRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'

    # THE BUNDLE IS NOT SOURCE. Hephaestus.bundle.ps1 is every other file under
    # src\Hephaestus concatenated - a build artefact - so scanning it reports
    # every FindName in the module a second time, naming a file nobody edits.
    # Get-HDTSourceFile excludes it for the same reason; this sweep has its own
    # because it wants .xaml too.
    $script:sourceFile = @(Get-ChildItem -LiteralPath $script:sourceRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.xaml' |
            Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })

    # THE ADMIN CONSOLE IS IN THIS MODULE AND NOT IN THE BOOT IMAGE, and after
    # the two modules were folded into one those are no longer the same
    # statement. The console is a DESKTOP app: it never enters a boot image, so
    # WinPE's constraints do not apply to it and it has no Next/Cancel buttons to
    # name. Scanning it under those two rules made this contract fail on
    # perfectly correct files, which is exactly how a contract earns its own
    # deletion.
    #
    # SPLIT BY FOLDER, NOT BY FILE NAME. Naming the exception by file is the trap
    # this file's own header warns about - the next console page would inherit
    # the WinPE rules simply by being new, and the next wizard page could escape
    # them by being named something else. Markup that ships to the RAM disk lives
    # in UI\; markup the console draws on an administrator's desktop lives in
    # UI\Console\, and only the two WinPE-specific rules below consult this.
    # EVERY OTHER RULE IN THIS FILE STILL SEES THE CONSOLE - the FindName sweep
    # and the dead-button sweep are as true of a desktop window as of a WinPE
    # one, and the console gained them by moving in here.
    $script:desktopMarkup = '[\\/]UI[\\/]Console[\\/]'

    $script:scanned = @($script:sourceFile | ForEach-Object {
            [pscustomobject] @{
                Relative = $_.FullName.Substring($script:repoRoot.Length).TrimStart('\', '/')
                Text     = [System.IO.File]::ReadAllText($_.FullName)
            }
        })

    $script:totalLength = 0
    foreach ($row in $script:scanned) { $script:totalLength += $row.Text.Length }
}

Describe 'the WinPE UI stack' {

    Context 'it scanned something' {

        It 'found the engine source' {
            @($script:scanned).Count | Should -BeGreaterThan 50 -Because (
                'every assertion below is vacuously true of an empty scan')
        }

        It 'read a meaningful volume of it' {
            $script:totalLength | Should -BeGreaterThan 100000
        }

        It 'included the wizard window and its command' {
            @($script:scanned | Where-Object { $_.Relative -like '*HDTWizard.xaml' }).Count | Should -Be 1
            @($script:scanned | Where-Object { $_.Relative -like '*Show-HDTWizard.ps1' }).Count | Should -Be 1
        }
    }

    Context 'nothing that ships into the image reaches for WinForms' {

        BeforeAll {
            # CODE WITHOUT ITS COMMENTS, and the same lesson this file already
            # learned for markup one context down: several of these files
            # explain a rule by NAMING THE THING IT FORBIDS, which under a raw
            # scan convicts the one file that had to say it.
            #
            # It happened here too. Start-HDTDeployment.ps1's header explains
            # which assemblies it may not name - and naming them failed this
            # rule, on a file that was correct.
            #
            # TOKENISED, NOT REGEXED. A '#' inside a string is not a comment, and
            # a line-based stripper would eat half of one.
            $script:codeOnly = @($script:scanned |
                    Where-Object { $_.Relative -like '*.ps1' -or $_.Relative -like '*.psm1' } |
                    ForEach-Object {
                        $token = $null
                        $parseError = $null
                        [void] [System.Management.Automation.Language.Parser]::ParseInput(
                            $_.Text, [ref] $token, [ref] $parseError)

                        $text = $_.Text
                        foreach ($comment in @($token | Where-Object { $_.Kind -eq 'Comment' } |
                                    Sort-Object { $_.Extent.StartOffset } -Descending)) {

                            $text = $text.Remove($comment.Extent.StartOffset,
                                $comment.Extent.EndOffset - $comment.Extent.StartOffset)
                        }

                        [pscustomobject] @{ Relative = $_.Relative; Text = $text }
                    })
        }

        It 'stripped something, so the assertions below are not reading nothing' {
            @($script:codeOnly).Count | Should -BeGreaterThan 50
        }

        It 'references no <_>' -ForEach @('System.Windows.Forms', 'WindowsFormsIntegration') {
            $name = $PSItem
            $offender = @($script:codeOnly |
                    Where-Object { $_.Text -match [regex]::Escape($name) } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                "{0} is not guaranteed by WinPE-NetFx, so a window using it works on a developer machine and fails in WinPE. Found in: {1}. Use the WPF dispatcher instead" -f
                    $name, (($offender -join ', ')))
        }

        It 'pumps the message loop with the WPF dispatcher, not DoEvents' {
            $offender = @($script:codeOnly |
                    Where-Object { $_.Text -match 'DoEvents' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'DoEvents is a WinForms call. Found in: {0}. Dispatcher.Invoke with DispatcherPriority::Background is the WPF equivalent' -f (($offender -join ', ')))
        }
    }

    Context 'every wizard window is loadable by XamlReader in WinPE' {

        # ITERATED, NOT NAMED. The first version of this contract checked
        # HDTWizard.xaml by name, so the second page - HDTWizardCredential.xaml
        # - would have escaped every assertion below simply by being new. Each
        # increment of the WPF-first direction adds a page; none of them may opt
        # out of the rules by existing.

        BeforeAll {
            # MARKUP WITHOUT ITS COMMENTS, for every rule below. These files
            # explain themselves at length, and several of them explain a rule
            # by naming the thing it forbids - HDTTheme.xaml's header says why
            # it is not merged with `ResourceDictionary Source=`, which under a
            # raw scan convicts the one file that had to say it. Same trap the
            # no-keystroke contract hit, same fix: judge the markup, not the
            # prose.
            $script:markup = @($script:scanned |
                    Where-Object { $_.Relative -like '*.xaml' } |
                    ForEach-Object {
                        [pscustomobject] @{
                            Relative = $_.Relative
                            Text     = $_.Text
                            Code     = [regex]::Replace($_.Text, '(?s)<!--.*?-->', '')
                        }
                    })

            # A WINDOW IS A FILE WHOSE ROOT IS <Window>, and the difference now
            # matters: HDTTheme.xaml is a ResourceDictionary, so it has no Next
            # button, no Cancel button and no business being asked for them. It
            # is still markup that ships into the image, so every OTHER rule
            # still applies to it.
            $script:window = @($script:markup |
                    Where-Object { ([xml] $_.Text).DocumentElement.LocalName -eq 'Window' })

            $script:dictionary = @($script:markup |
                    Where-Object { ([xml] $_.Text).DocumentElement.LocalName -eq 'ResourceDictionary' })
        }

        It 'found at least one window' {
            @($script:window).Count | Should -BeGreaterThan 0 -Because (
                'the assertions below are vacuous with nothing to check')
        }

        It 'found the theme dictionary' {
            # Anti-vacuity for the split above: if the root-element test ever
            # stopped recognising a dictionary, every dictionary would silently
            # become a window and the button rule would start failing them -
            # or worse, the split would quietly classify a real window as a
            # dictionary and excuse it from the button rule entirely.
            @($script:dictionary).Count | Should -BeGreaterThan 0 -Because (
                'HDTTheme.xaml is a ResourceDictionary and the split must see it as one')
        }

        It 'declares no code-behind class in any window' {
            # There is no compiler in WinPE to build a partial class against, so
            # XamlReader::Load - which parses markup only - is the only way in.
            $offender = @()
            foreach ($row in $script:markup) {
                $document = [xml] $row.Text
                if (-not [string]::IsNullOrEmpty($document.DocumentElement.GetAttribute('Class', 'http://schemas.microsoft.com/winfx/2006/xaml'))) {
                    $offender += $row.Relative
                }
            }

            @($offender).Count | Should -Be 0 -Because ('code-behind in: {0}' -f ($offender -join ', '))
        }

        It 'references no external resource dictionary in any window' {
            # Another file that would have to reach the RAM disk intact. Every
            # increment that adds one has to add it to the image as well, and
            # this is where that gets noticed.
            # EVERY .xaml, not only the windows: a dictionary that merged
            # another dictionary would put the same second file on the RAM disk
            # by a longer route.
            $offender = @($script:markup |
                    Where-Object { $_.Code -match 'ResourceDictionary\s+Source=' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because ('external resources in: {0}' -f ($offender -join ', '))
        }

        It 'parses as XML' {
            foreach ($row in $script:markup) {
                { [xml] $row.Text } | Should -Not -Throw -Because $row.Relative
            }
        }

        It 'names its buttons so the backend can find them' {
            # FindName is how handlers are attached with no code-behind, so a
            # page whose buttons are anonymous cannot be wired at all.
            # WINDOWS ONLY. A ResourceDictionary has no buttons to name.
            #
            # A WINDOW THAT ASKS SOMETHING NEEDS BOTH ANSWERS. A window that
            # asks nothing needs neither: HDTProgress.xaml is a STATUS BOARD,
            # shown while a deployment runs, and there is nothing on it to
            # approve or cancel. Giving it a Next would be giving a technician a
            # button that does nothing, and a Cancel would be a corner that
            # makes a running deployment's only screen disappear.
            #
            # THE TEST IS "DOES IT HAVE BUTTONS AT ALL", NOT "IS IT THE PROGRESS
            # WINDOW". Naming the exception by file is the trap this context's
            # own header warns about - the next status board would inherit the
            # rule by being new. This way, the moment anything is given a
            # button, it must have both of the ones the host wires.
            #
            # THE BOOT IMAGE'S WINDOWS ONLY. The console's windows are a desktop
            # app's - see $script:desktopMarkup - and a Deployment Workbench does
            # not have a Next button.
            $asking = @($script:window |
                    Where-Object { $_.Relative -notmatch $script:desktopMarkup -and $_.Code -match '<Button' })

            @($asking).Count | Should -BeGreaterThan 0 -Because (
                'the assertion below is vacuous if no window has any buttons')

            foreach ($row in $asking) {
                $row.Code | Should -BeLike '*HDTNextButton*' -Because $row.Relative
                $row.Code | Should -BeLike '*HDTCancelButton*' -Because $row.Relative
            }
        }

        It 'has at least one window that asks nothing, and it declares no buttons' {
            # The other side of the rule above, so "no buttons" cannot quietly
            # become the way every window opts out of it.
            $silent = @($script:window | Where-Object { $_.Code -notmatch '<Button' })

            @($silent).Count | Should -BeGreaterThan 0 -Because (
                'HDTProgress.xaml is a status board and must stay one')

            foreach ($row in $silent) {
                $row.Code | Should -Not -BeLike '*HDTNextButton*' -Because $row.Relative
                $row.Code | Should -Not -BeLike '*HDTCancelButton*' -Because $row.Relative
            }
        }
    }

    Context 'every name the engine reaches for is a name a window answers to' {

        # THE FAILURE THIS CATCHES, AND WHY IT IS HERE RATHER THAN IN A UNIT
        # TEST. New-HDTWizardHost is exempt from TDD as a thin WPF adapter
        # (CLAUDE.md rule 1), so nothing executes its FindName calls until a
        # machine in WinPE does. FindName does not throw on a name nothing
        # answers to - it returns null - so a renamed control does not fail, it
        # SILENTLY DOES NOTHING, on the one machine with no debugger attached.
        #
        # Comparing the two sides of that name is the part that needs no display,
        # so it is the part that can be automated.

        BeforeAll {
            $script:declaredName = @($script:scanned |
                    Where-Object { $_.Relative -like '*.xaml' } |
                    ForEach-Object {
                        [regex]::Matches($_.Text, 'x:Name\s*=\s*"([^"]+)"') |
                            ForEach-Object { $_.Groups[1].Value }
                        } |
                    Sort-Object -Unique)

            # Only HDT-prefixed names: a template part like HDTButtonSurface is
            # declared inside a ControlTemplate and is not addressable from the
            # window, but everything the engine looks up is.
            $script:requestedName = @($script:scanned |
                    Where-Object { $_.Relative -like '*.ps1' } |
                    ForEach-Object {
                        $relative = $_.Relative
                        [regex]::Matches($_.Text, "FindName\(\s*'(HDT[A-Za-z0-9]+)'\s*\)") |
                            ForEach-Object {
                                [pscustomobject] @{ Name = $_.Groups[1].Value; Relative = $relative }
                            }
                        })
        }

        It 'found the names on both sides' {
            @($script:declaredName).Count | Should -BeGreaterThan 5 -Because (
                'the assertion below is vacuous with nothing declared')
            @($script:requestedName).Count | Should -BeGreaterThan 0 -Because (
                'the assertion below is vacuous with nothing requested')
        }

        It 'looks up no control that no window declares' {
            $offender = @($script:requestedName |
                    Where-Object { $script:declaredName -notcontains $_.Name } |
                    ForEach-Object { '{0} ({1})' -f $_.Name, $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'FindName returns null rather than throwing, so this is a control that silently does nothing in WinPE. Found: {0}' -f
                    ($offender -join ', '))
        }
    }

    Context 'every button a window offers is a button the engine wires' {

        # THE OTHER DIRECTION, AND IT IS THE ONE THAT WAS ACTUALLY WRONG.
        # The context above catches a name the engine reaches for and no window
        # answers to. THIS catches the mirror image: a button a technician can
        # SEE AND PRESS that no engine code mentions at all.
        #
        # HDTWizardShell.xaml shipped an "Open CMD" button named
        # HDTCommandPromptButton while New-HDTWizardHost wired HDTOpenCmdButton.
        # Both files were internally consistent and every existing assertion
        # passed. The button was simply dead - it did not open a prompt, and it
        # did not even close the window. The one place that failure is visible
        # is in front of the machine, which is the one place there is no test.
        #
        # A DEAD BUTTON IS WORSE THAN A MISSING ONE. A wizard with no escape
        # hatch tells a technician to find another way; a wizard with one that
        # does nothing tells them the machine is hung.
        #
        # MATCHED ON MENTION, NOT ON FindName. The host reaches for its buttons
        # through a table - FindName([string] $pair.Name) - so a scan for
        # FindName('literal') sees none of them. What is being asserted is
        # weaker and honest: the engine names this control SOMEWHERE. A name
        # nothing in src/ even mentions cannot be wired by any route.

        BeforeAll {
            # COMPUTED HERE, NOT BORROWED. $script:window is built by another
            # Context's BeforeAll, and a Context that only works because an
            # earlier one ran is a Context that breaks the day someone runs this
            # file with -FullNameFilter.
            $script:buttonWindow = @($script:scanned |
                    Where-Object { $_.Relative -like '*.xaml' } |
                    ForEach-Object {
                        [pscustomobject] @{
                            Relative = $_.Relative
                            Code     = [regex]::Replace($_.Text, '(?s)<!--.*?-->', '')
                        }
                    } |
                    Where-Object { ([xml] $_.Code).DocumentElement.LocalName -eq 'Window' })

            $script:declaredButton = @($script:buttonWindow | ForEach-Object {
                    $relative = $_.Relative
                    $document = [xml] $_.Code

                    @($document.SelectNodes('//*')) |
                        Where-Object { $_.LocalName -eq 'Button' } |
                        ForEach-Object {
                            $name = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
                            if (-not [string]::IsNullOrEmpty($name)) {
                                [pscustomobject] @{ Name = $name; Relative = $relative }
                            }
                        }
                    })

            $script:engineText = @($script:scanned |
                    Where-Object { $_.Relative -like '*.ps1' } |
                    ForEach-Object { $_.Text })
        }

        It 'found buttons to judge' {
            @($script:declaredButton).Count | Should -BeGreaterThan 3 -Because (
                'the assertion below is vacuous with no buttons found, and every window ships at least Next and Cancel')
        }

        It 'names no button the engine never mentions' {
            $offender = @($script:declaredButton | Where-Object {
                    $name = $_.Name
                    -not @($script:engineText | Where-Object { $_ -match [regex]::Escape($name) })
                } | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'a button no engine code names is one a technician can press and nothing happens. Found: {0}' -f
                    ($offender -join ', '))
        }
    }

    Context 'F8 opens a command prompt from every window in the image' {

        # MDT's boot image has "Enable command support (testing only)" and every
        # technician who has debugged a deployment knows what F8 does. Nothing in
        # WinPE provides that key - ConfigMgr's boot shell implements it, MDT's
        # implements it, and so does this - so it has to be wired once per host,
        # and a host that forgot is a key that silently does nothing.
        #
        # A KEY THAT WORKS ON TWO WINDOWS OUT OF THREE IS A KEY NOBODY TRUSTS,
        # which is why this is a rule and not three separate assertions written
        # when each window happened to be built.

        It 'wires F8 in <_>' -ForEach @(
            'New-HDTWizardHost.ps1',      # the Welcome screen AND the shell
            'New-HDTProgressHost.ps1') {  # the status board, where it matters most

            $path = Join-Path -Path $script:sourceRoot -ChildPath ('Public/{0}' -f $PSItem)

            Test-Path -LiteralPath $path | Should -BeTrue
            (Get-Content -LiteralPath $path -Raw) | Should -Match 'Key\]::F8' -Because (
                '{0} draws a window a technician looks at in WinPE' -f $PSItem)
        }

        It 'hands the progress window a path rather than making it resolve one' {
            # That window runs in its own runspace with no Hephaestus module in
            # it, so it cannot call Start-HDTCommandPrompt. Importing a module on
            # a RAM disk to answer a keypress is not the fix.
            $path = Join-Path -Path $script:sourceRoot -ChildPath 'Public/New-HDTProgressHost.ps1'

            (Get-Content -LiteralPath $path -Raw) | Should -Match 'HDTCommandPromptPath'
        }

        It 'never lets a keystroke take a window down with it' {
            # Both handlers run on a UI thread the engine cannot see. An
            # exception in one would leave a machine deploying behind a dead
            # screen, which is strictly worse than a key that did nothing.
            $progress = Get-Content -LiteralPath (
                Join-Path -Path $script:sourceRoot -ChildPath 'Public/New-HDTProgressHost.ps1') -Raw

            $progress | Should -Match '(?s)Key\]::F8.*?try\s*\{'
        }
    }

    Context 'no page sets a member the theme has already claimed for a style' {

        # FOUND ON A LIVE MACHINE, AND ONLY THERE. A WinPE VM reached the Ready
        # to Deploy page and died with
        #
        #     Cannot set unknown member 'System.Windows.Controls.TextBox.IsReadOnly'
        #
        # on a page that loads perfectly well on a desktop, and perfectly well in
        # WinPE ON ITS OWN. Bisecting the theme inside WinPE found the cause:
        # once HDTTheme.xaml's `<Style x:Key="HDTAddressBox" TargetType="TextBox">`
        # has been parsed, WPF's XAML schema context stops recognising
        # TextBox.IsReadOnly AS AN ATTRIBUTE for every later XamlReader::Load in
        # the process. The theme is merged before every page, so every page
        # afterwards is in the poisoned process.
        #
        # THE .NET VERSION IS NOT THE DIFFERENCE - WinPE carries the same
        # PresentationFramework 4.8 the host does. LOAD ORDER is: a desktop probe
        # that loads one page in a fresh runspace never sees it, which is exactly
        # why this reached a booted machine.
        #
        # SO THE MEMBER LIVES IN THE THEME, where a Setter still resolves it, and
        # a page asks for the style by name. That is where the wizard's look
        # belongs anyway; this is the reason it is not merely a preference.
        #
        # THE SAMPLE PAGES ARE SCANNED TOO. The offending file was
        # samples/workspace/Scripts/UI/Summary.xaml - a SHARE page, outside
        # src/Hephaestus, and therefore outside every other rule in this file.
        # A rule that could not see the file that broke a deployment is not a
        # rule.

        BeforeAll {
            $script:pageRoot = Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/Scripts/UI'

            $script:everyMarkup = @($script:scanned | Where-Object { $_.Relative -like '*.xaml' })

            if (Test-Path -LiteralPath $script:pageRoot) {
                $script:everyMarkup += @(Get-ChildItem -LiteralPath $script:pageRoot -Recurse -File -Filter '*.xaml' |
                        ForEach-Object {
                            [pscustomobject] @{
                                Relative = $_.FullName.Substring($script:repoRoot.Length).TrimStart('\', '/')
                                Text     = [System.IO.File]::ReadAllText($_.FullName)
                            }
                        })
            }

            # COMMENTS STRIPPED, for the reason the whole file already knows: the
            # markup below explains the trap in prose, and a raw scan convicts
            # the file that documented it.
            $script:everyCode = @($script:everyMarkup | ForEach-Object {
                        [pscustomobject] @{
                            Relative = $_.Relative
                            Code     = [regex]::Replace($_.Text, '(?s)<!--.*?-->', '')
                        }
                    })
        }

        It 'scanned the share pages as well as the module markup' {
            # Anti-vacuity, and it is the point of the whole context: the file
            # that broke a live deployment lives under samples/, not src/.
            @($script:everyCode | Where-Object { $_.Relative -like '*samples*' }).Count |
                Should -BeGreaterThan 0 -Because 'the wizard pages on the share are markup this rule must see'
        }

        It 'sets IsReadOnly nowhere as a direct attribute' {
            # THE POISONING IS A WinPE LOAD-ORDER FACT, so this asks it of the
            # markup that reaches WinPE: the wizard's pages and the share's. The
            # console's windows never load HDTTheme.xaml and never run in that
            # process - see $script:desktopMarkup.
            $offender = @($script:everyCode |
                    Where-Object { $_.Relative -notmatch $script:desktopMarkup -and $_.Code -match '<[A-Za-z][^>]*\sIsReadOnly\s*=' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'HDTTheme.xaml poisons TextBox.IsReadOnly as an attribute for every later XamlReader::Load in WinPE - ' +
                'ask the theme for a style instead. Found: {0}' -f ($offender -join ', '))
        }

        It 'asks the theme for nothing with StaticResource on a share page' {
            # A SHARE PAGE IS PARSED ON ITS OWN. New-HDTWizardHost loads the page
            # and only then puts it inside the shell, so at parse time there is
            # no dictionary above it: a StaticResource throws "Provide value on
            # 'System.Windows.StaticResourceExtension' threw an exception" and
            # the page never appears. A DynamicResource is resolved once the page
            # is attached, which is the only form that can work here.
            #
            # THE MODULE'S OWN MARKUP IS EXEMPT - the shell and the theme are
            # loaded as whole documents and may resolve their own keys.
            $offender = @($script:everyCode |
                    Where-Object { $_.Relative -like '*samples*' -and $_.Code -match '\{\s*StaticResource' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'a share page is parsed detached, so StaticResource cannot resolve. Found: {0}' -f ($offender -join ', '))
        }

        It 'still offers a style that carries it, so the rule above is not a ban on read-only boxes' {
            $theme = @($script:everyCode | Where-Object { $_.Relative -like '*HDTTheme.xaml' })

            @($theme).Count | Should -Be 1
            $theme[0].Code | Should -Match 'x:Key="HDTSnippetBox"' -Because (
                'the Ready to Deploy page needs a selectable read-only box and may no longer say so itself')
        }
    }
}
