# EVERY WINDOW THIS PRODUCT DRAWS CAN BE MOVED, AND NONE OF THEM SITS ON TOP OF
# THE ONE ESCAPE HATCH A TECHNICIAN HAS.
#
# WHY THIS IS A CONTRACT AND NOT A NOTE ON ONE FILE. Both halves below were
# found on a bench, in real WinPE, on HDTFailure.xaml - the screen a technician
# only ever sees when something has already gone wrong:
#
#   1. The window could not be moved. WindowStyle="None" is right for a
#      deployment screen (an X is a third way out of a wizard), but it also
#      removes the thing you grab. New-HDTWizardHost gives that back to any
#      window declaring an x:Name of HDTDragBanner and to no other - and the
#      failure screen declared none, so the one screen a technician needs to
#      read alongside something else was nailed to the middle of the display.
#
#   2. Pressing "Open CMD" opened the command prompt BEHIND the window. The
#      launch was correct; Topmost="True" in the markup was not. A topmost
#      window outranks any non-topmost foreground window, so the prompt was not
#      merely unfocused - it was unreachable, on the screen whose entire purpose
#      is to hand the machine back to a human being.
#
# Both are properties of a SET, not of a file. A test naming HDTFailure.xaml
# would pass for it and fail nobody after it (CLAUDE.md rule 8), so both rules
# below are driven off a glob of src\Hephaestus\UI and judge every window they
# find.

# DISCOVERY AND RUN DO NOT SHARE A SCOPE (SPIKES S9.15), so the file names the
# -ForEach below expands are built here, in discovery, and the objects the It
# bodies read are built again in BeforeAll. Reading one from the other is the
# exact cross-boundary read tests/contract/SlowSuiteSkip.Contract.Tests.ps1
# exists to catch: under StrictMode it throws and takes the whole container
# down; without it, it is $null and the run passes having checked nothing.
BeforeDiscovery {
    $script:discoveredWindowName = @(
        Get-ChildItem -LiteralPath ([IO.Path]::Combine(
                (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)), 'src', 'Hephaestus', 'UI')) -Recurse -File -Filter '*.xaml' |
            Where-Object { ([xml] [System.IO.File]::ReadAllText($_.FullName)).DocumentElement.LocalName -eq 'Window' } |
            ForEach-Object { $_.Name })
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:uiRoot = [IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'UI')

    # A GLOB, NEVER A LIST. The next window somebody adds is in scope the moment
    # it is saved, which is the only reason this file catches anything.
    $script:markup = @(Get-ChildItem -LiteralPath $script:uiRoot -Recurse -File -Filter '*.xaml' |
            ForEach-Object {
                $text = [System.IO.File]::ReadAllText($_.FullName)
                [pscustomobject] @{
                    Name     = $_.Name
                    Relative = $_.FullName.Substring($script:repoRoot.Length).TrimStart('\', '/')
                    Text     = $text

                    # MARKUP WITHOUT ITS PROSE. These files explain a rule by
                    # naming the thing it forbids - HDTProgress.xaml's header
                    # says the word Topmost three times in one paragraph - and a
                    # raw scan convicts the file that documented it. Same trap
                    # tests/contract/WinPeUiStack.Contract.Tests.ps1 already
                    # records, same fix: judge the markup, not the comment.
                    Code     = [regex]::Replace($text, '(?s)<!--.*?-->', '')
                }
            })

    # A WINDOW IS A FILE WHOSE ROOT IS Window. HDTTheme.xaml is a
    # ResourceDictionary: it has no chrome, no z-order and no business being
    # asked about either.
    $script:window = @($script:markup |
            Where-Object { ([xml] $_.Text).DocumentElement.LocalName -eq 'Window' })
}

Describe 'the windows a technician meets' {

    Context 'it scanned something' {

        It 'found the markup directory' {
            Test-Path -LiteralPath $script:uiRoot | Should -BeTrue
        }

        It 'found several windows' {
            # Anti-vacuity: every rule below is trivially true of no files.
            @($script:window).Count | Should -BeGreaterThan 4 -Because (
                'the assertions below say nothing about an empty set')
        }

        It 'found the failure screen among them' {
            @($script:window | Where-Object { $_.Name -eq 'HDTFailure.xaml' }).Count |
                Should -Be 1 -Because 'the screen that forced both rules must be inside the set they judge'
        }
    }

    Context 'a window a technician answers can be moved' {

        # WHICH WINDOWS THIS ASKS OF, AND WHY THE LINE IS DRAWN AT A BUTTON.
        # This repository already names the distinction in its own markup -
        # HDTBootStatus.xaml: "NO BUTTONS, NO TITLE BAR, NO X. It is an account
        # of what is happening, not a dialog - the same thing HDTProgress.xaml
        # is". A status board reports; a technician reads it and waits. A window
        # carrying buttons is one they stand in front of and ANSWER, and to
        # answer it they may have to see something behind it - a command prompt,
        # a second screen, the machine's own wallpaper carrying its serial.
        #
        # So the rule is derived from the markup rather than from a list of
        # names: WindowStyle="None" took the title bar away, and a window with a
        # button has to give the grab handle back. A new dialog is caught by
        # having buttons, and cannot escape by being new.

        BeforeAll {
            $script:chromeless = @($script:window |
                    Where-Object { ([xml] $_.Text).DocumentElement.GetAttribute('WindowStyle') -eq 'None' })

            $script:answerable = @($script:chromeless | Where-Object { $_.Code -match '<Button[\s>]' })
        }

        It 'found windows with no title bar of their own' {
            @($script:chromeless).Count | Should -BeGreaterThan 4 -Because (
                'WindowStyle=None is what makes a drag banner necessary at all')
        }

        It 'found more than one window carrying buttons' {
            @($script:answerable).Count | Should -BeGreaterThan 1 -Because (
                'a rule that judges a single file is the defect this file exists to prevent')
        }

        It 'gives every one of them a drag banner' {
            # New-HDTWizardHost looks the name up with FindName and wires
            # DragMove onto it. The lookup is null-guarded, so a window without
            # one does not fail, log, or warn - it is simply immovable, which is
            # exactly how the failure screen shipped that way.
            $offender = @($script:answerable |
                    Where-Object { $_.Code -notmatch 'x:Name\s*=\s*"HDTDragBanner"' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'WindowStyle=None removes the title bar, and New-HDTWizardHost gives the grab handle back only ' +
                'to a window declaring an x:Name of HDTDragBanner. Without one it cannot be moved at all. Found: {0}' -f
                    ($offender -join ', '))
        }
    }

    Context 'nothing sits on top of the command prompt' {

        # THE ALLOW-LIST IS ONE FILE AND IT NAMES ITS REASON.
        #
        # HDTProgress.xaml is topmost because it OUTLIVES WinPE. In WinPE there
        # is no shell to compete with - cmd.exe is it - but the full-OS leg
        # draws that board on a real DESKTOP, where a deployed machine showed
        # the taskbar and the Start menu opening straight over it. It is also
        # closed by Start-HDTDeployment before any command prompt can be opened,
        # so it never stands between a technician and one.
        #
        # NOTHING ELSE QUALIFIES. Topmost is state, not markup: a window that
        # hands the machine to another process has to stop outranking it, and
        # markup cannot.
        #
        # DERIVED FROM friendsOfMDT/PSD - MIT licensed, attributed in NOTICE.md.
        # PSD reached this conclusion from the same bench and left it in the
        # code: it assigns Topmost = $False on the line before EVERY ShowDialog,
        # under the comment "always force windows on bottom"
        # (Scripts/PSDWizardNew.psm1:760 and :2995,
        # Scripts/PSDStartLoader.psm1:2780); it binds Esc to lower the window
        # (PSDWizardNew.psm1:2764-2767); and where it does raise a window it
        # reads a runtime flag rather than markup (PSDStartLoader.psm1:2352).
        # What was taken is that MECHANISM and nothing else - HDT forbids the
        # attribute outright instead of assigning the property back, so there
        # is no window here with a Topmost to undo.
        #
        # DO NOT ADD A NAME HERE TO MAKE A RUN GREEN. The correct fix for a new
        # topmost window is to take the attribute out.
        BeforeAll {
            $script:topmostAllowed = @('HDTProgress.xaml')
        }

        It 'allows only windows that are on the list, and the list is short' {
            @($script:topmostAllowed).Count | Should -BeLessThan 2 -Because (
                'each name here is a window that can cover another process, and it must earn it in a comment')
        }

        It 'still finds the one allowed window, so the rule is not passing by accident' {
            $allowed = @($script:window |
                    Where-Object { $script:topmostAllowed -contains $_.Name } |
                    Where-Object { ([xml] $_.Text).DocumentElement.GetAttribute('Topmost') -eq 'True' })

            @($allowed).Count | Should -Be 1 -Because (
                'HDTProgress.xaml is topmost on purpose - if it stopped being so, this allow-list is stale')
        }

        It 'sets Topmost nowhere else' {
            $offender = @($script:window |
                    Where-Object { $script:topmostAllowed -notcontains $_.Name } |
                    Where-Object { ([xml] $_.Text).DocumentElement.GetAttribute('Topmost') -eq 'True' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'a topmost window outranks the command prompt a technician opens from it, so the prompt is ' +
                'unreachable rather than merely unfocused. Found: {0}' -f ($offender -join ', '))
        }

        It 'raises no window above the prompt at runtime either' {
            # THE SAME RULE, FROM THE OTHER SIDE. Taking the attribute out of the
            # markup buys nothing if a host puts it back on the object, and the
            # host is the harder place to notice it.
            $sourceRoot = [IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus')
            $code = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Include '*.ps1', '*.psm1' |
                    Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })

            @($code).Count | Should -BeGreaterThan 50 -Because 'an empty scan proves nothing'

            $offender = @($code |
                    Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match '\.Topmost\s*=\s*\$true' } |
                    ForEach-Object { $_.FullName.Substring($script:repoRoot.Length).TrimStart('\', '/') })

            @($offender).Count | Should -Be 0 -Because (
                'a window raised above the command prompt at runtime is the same defect the markup rule forbids. Found: {0}' -f
                    ($offender -join ', '))
        }
    }

    Context 'every window is markup WinPE can actually load' {

        BeforeAll {
            Add-Type -AssemblyName PresentationFramework
            Add-Type -AssemblyName PresentationCore
            Add-Type -AssemblyName WindowsBase
        }

        It 'declares both XAML namespaces: <_>' -ForEach $script:discoveredWindowName {
            # $PSItem IS COPIED OUT FIRST, and it is not a style choice.
            # $PSItem is an alias for $_, so inside a Where-Object scriptblock it
            # is the PIPELINE object and not the test case - the lookup silently
            # matches nothing and every row fails on a null.
            $name = $PSItem
            $row = @($script:window | Where-Object { $_.Name -eq $name })[0]
            $root = ([xml] $row.Text).DocumentElement

            # THE x: PREFIX IS NOT DECORATION. Every name the host looks up with
            # FindName - HDTDragBanner included - is an x:Name, so a window
            # missing the prefix declaration is a window whose controls the host
            # cannot find.
            $root.GetAttribute('xmlns') | Should -Be 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
            $root.GetAttribute('xmlns:x') | Should -Be 'http://schemas.microsoft.com/winfx/2006/xaml'
        }

        It 'parses under XamlReader: <_>' -ForEach $script:discoveredWindowName {
            # [xml] only proves the angle brackets balance. XamlReader is what
            # WinPE runs, and it is the only thing that resolves a member name.
            $name = $PSItem
            $row = @($script:window | Where-Object { $_.Name -eq $name })[0]
            $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $row.Text)

            { [System.Windows.Markup.XamlReader]::Load($reader) } | Should -Not -Throw
        }
    }
}
