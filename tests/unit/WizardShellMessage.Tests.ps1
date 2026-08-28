# THE STRIP THE WIZARD REFUSES A PAGE IN, MEASURED RATHER THAN LOOKED AT.
#
# WHAT WENT WRONG, IN NUMBERS. The message shared the button row's `*` column,
# and the four buttons ate the row: 120 + 110 + 110 + 130 plus margins left the
# message 64.6px of width, so 'the two passwords do not match. Type the same
# password in both boxes.' wrapped to 167.6px inside a 76px row. A technician
# saw a narrow orange ribbon with its first and last lines cut off - "do not /
# match. / Type the / same / password" - which says something is wrong and not
# what.
#
# AND THE FIX BEFORE THIS ONE MADE IT. The message once carried MaxWidth="300"
# to keep it off the buttons; that CLIPPED it sideways, so the cap was removed -
# which turned a horizontal clip into a vertical one, in a row too short to
# hold what now wrapped. Neither was visible to a test, because nothing here
# had ever measured the thing.
#
# SO THIS FILE MEASURES IT, AND AGAINST THE SET. Nothing below holds a list of
# messages. The rules are read out of Show-HDTWizardShell's own $knownRule
# table with the AST, every validator command it names is followed to its
# source, and the refusals are harvested from there - so a rule added tomorrow
# with a longer sentence fails here rather than at a bench.
#
# TWO SETS, AND THE DIFFERENCE MATTERS.
#
#   EVERY refusal the engine can paint          must never be clipped
#   every refusal a SHIPPED PAGE can produce    must also leave the layout still
#
# They differ by exactly one message today: Test-HDTComputerName's over-15
# complaint runs to three lines, and ComputerDetail.xaml caps that box at
# MaxLength characters - read off the shipped page here, not written down - so
# the shipped wizard cannot produce it. A seeded value from rules.yaml still
# can, which is why the band GROWS rather than clips.

$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

# ---- discovery: the set, read off the engine ---------------------------------
#
# A $script: variable assigned while Pester is DISCOVERING is $null by the time
# a test RUNS, so everything read here reaches an It through -ForEach or not at
# all. See WizardValidateRule.Contract.Tests.ps1, which was bitten by it.

$script:shellCommandPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Show-HDTWizardShell.ps1'

# THE RULE TABLE'S OWN TEXT. $knownRule is a local variable inside the command,
# so it cannot be read by running anything - the AST is the only way to the set
# without keeping a copy of it here.
$script:knownRuleText = ''
$script:shellAst = [System.Management.Automation.Language.Parser]::ParseFile($script:shellCommandPath, [ref] $null, [ref] $null)

foreach ($assignment in @($script:shellAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq 'knownRule'
            }, $true))) {

    $script:knownRuleText = [string] $assignment.Extent.Text
}

# EVERY VALIDATOR THE TABLE CALLS, FOLLOWED TO ITS FILE. A rule with a command
# behind it keeps its sentences there; TaskSequence has none and keeps its one
# in the table, so both are harvested.
$script:validatorSource = @(@([regex]::Matches($script:knownRuleText, '\b(?:Test|Get|Assert|Resolve)-HDT\w+') |
            ForEach-Object { $_.Value } | Sort-Object -Unique |
            ForEach-Object { Join-Path -Path $script:repoRoot -ChildPath ('src/Hephaestus/Public/{0}.ps1' -f $_) } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }))

# THE SHIPPED PAGE'S OWN CAP, so the bound below is the wizard's and not this
# file's opinion of it.
$script:computerNameMaxLength = [int] (@(([xml] ([System.IO.File]::ReadAllText(
                    (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/Wizard/ComputerDetail.xaml')))
            ).GetElementsByTagName('TextBox') |
        Where-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') -eq 'HDTComputerNameBox' } |
        ForEach-Object { $_.GetAttribute('MaxLength') })[0])

function Get-HDTTestStripMessage {
    <#
        .SYNOPSIS
            Every Reason literal in a block of engine source, with its format
            placeholders filled in at the worst length the box allows.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Label,
        [Parameter()] [int] $NameLength = 15
    )

    $found = New-Object -TypeName System.Collections.Generic.List[object]
    $index = 0

    foreach ($match in [regex]::Matches($Text, "Reason[^\r\n=]{0,12}=\s*\(?\s*'((?:[^']|'')*)'")) {

        $literal = $match.Groups[1].Value -replace "''", "'"
        if ([string]::IsNullOrWhiteSpace($literal)) { continue }

        # THE WORST NAME THE BOX WILL HOLD, not a short one. A refusal quoting
        # what was typed is as long as what was typed.
        $filled = $literal -replace '\{0\}', ('W' * $NameLength) -replace '\{1\}', ([string] $NameLength)

        $index++
        $found.Add([pscustomobject] @{ Label = ('{0} refusal {1}' -f $Label, $index); Message = $filled })
    }

    return $found.ToArray()
}

$script:harvested = @(
    @(Get-HDTTestStripMessage -Text $script:knownRuleText -Label 'the rule table' -NameLength $script:computerNameMaxLength)
    @($script:validatorSource | ForEach-Object {
            Get-HDTTestStripMessage -Text ([System.IO.File]::ReadAllText($_)) -Label (Split-Path -Leaf $_) -NameLength $script:computerNameMaxLength
        })
)

$script:harvestedCase = @($script:harvested | ForEach-Object { @{ Label = $_.Label; Message = $_.Message } })

# WHAT A SHIPPED PAGE CAN ACTUALLY PUT THERE, by running the validators the
# rule table names against values the shipped controls permit. The inputs are
# chosen here; the SENTENCES are not, which is the half that matters.
$script:produced = @(
    @(
        (Test-HDTComputerName -Name '')
        (Test-HDTComputerName -Name ('W_' + ('W' * ($script:computerNameMaxLength - 2))))
        (Test-HDTComputerName -Name ('W.' + ('W' * ($script:computerNameMaxLength - 2))))
        (Test-HDTComputerName -Name ('W ' + ('W' * ($script:computerNameMaxLength - 2))))
        (Test-HDTAdminPassword -Password '' -Confirmation '')
        (Test-HDTAdminPassword -Password 'one' -Confirmation 'other')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Reason) } | ForEach-Object {
        [pscustomobject] @{
            Label   = ('a validator refusal of {0} characters' -f $_.Reason.Length)
            Message = [string] $_.Reason
        }
    }

    # THE RULE WITH NO COMMAND BEHIND IT still ships a sentence, and a picker
    # with nothing lit produces it on the first page a technician sees.
    @(Get-HDTTestStripMessage -Text $script:knownRuleText -Label 'the rule table' -NameLength $script:computerNameMaxLength)
)

$script:producedCase = @($script:produced | ForEach-Object { @{ Label = $_.Label; Message = $_.Message } })

$script:setCase = @(@{
        Harvested = @($script:harvested | ForEach-Object { $_.Message })
        Produced  = @($script:produced | ForEach-Object { $_.Message })
        MaxLength = $script:computerNameMaxLength
    })

Describe 'the wizard shell message strip' {

    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        # SOFTWARE RENDERING. Nothing here is shown, but WPF still starts a
        # render thread, and hardware rendering on a headless agent is where
        # blank output comes from.
        [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:uiRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI'

        # THE WINDOW'S REAL SIZE, OFF ITS OWN MARKUP. 900x700 is declared in
        # HDTWizardShell.xaml and ResizeMode="NoResize" keeps it there; reading
        # it means a resize makes this file fail rather than quietly measure a
        # window nobody ships.
        $script:shellXaml = [System.IO.File]::ReadAllText((Join-Path -Path $script:uiRoot -ChildPath 'HDTWizardShell.xaml'))
        $script:shellWidth = [double] ([xml] $script:shellXaml).DocumentElement.GetAttribute('Width')
        $script:shellHeight = [double] ([xml] $script:shellXaml).DocumentElement.GetAttribute('Height')

        function New-HDTTestShellWindow {
            <#
                .SYNOPSIS
                    The shipped shell and the shipped theme, built in memory.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
            [CmdletBinding()]
            [OutputType([object])]
            param()

            $shellReader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $script:shellXaml)
            $window = [System.Windows.Markup.XamlReader]::Load($shellReader)

            # MERGED AT RUNTIME, AS New-HDTWizardHost DOES IT. The shell names
            # no dictionary - WinPeUiStack refuses one - so a shell measured
            # without the theme is a shell with default button metrics.
            $themeReader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList (
                [xml] ([System.IO.File]::ReadAllText((Join-Path -Path $script:uiRoot -ChildPath 'HDTTheme.xaml'))))
            $window.Resources.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Load($themeReader))

            return $window
        }

        function Update-HDTTestShellLayout {
            <#
                .SYNOPSIS
                    Lays the tree out at the window's own size. An element that
                    was never shown has no size, and every number below would
                    otherwise be zero.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Runs a WPF layout pass in memory; it shows nothing and changes no state.')]
            [CmdletBinding()]
            [OutputType([void])]
            param([Parameter(Mandatory = $true)] [object] $Window)

            $content = $Window.Content
            $content.Measure([System.Windows.Size]::new($script:shellWidth, $script:shellHeight))
            $content.Arrange([System.Windows.Rect]::new(0, 0, $script:shellWidth, $script:shellHeight))
            $content.UpdateLayout()
        }

        function Get-HDTTestControlRectangle {
            <#
                .SYNOPSIS
                    Where a named control ended up, in the window's own
                    coordinates - the only frame in which "it overlaps the
                    buttons" or "it hangs off the bottom" means anything.
            #>
            [CmdletBinding()]
            [OutputType([System.Windows.Rect])]
            param(
                [Parameter(Mandatory = $true)] [object] $Window,
                [Parameter(Mandatory = $true)] [string] $Name
            )

            $element = $Window.FindName($Name)
            if ($null -eq $element) { throw ("no control named '{0}' in the shell" -f $Name) }

            $transform = $element.TransformToAncestor($Window.Content)
            return $transform.TransformBounds(
                [System.Windows.Rect]::new(0, 0, $element.ActualWidth, $element.ActualHeight))
        }

        function Measure-HDTTestTextHeight {
            <#
                .SYNOPSIS
                    What the text needs at the width it was given. Comparing
                    this against the height it GOT is the whole test: a message
                    taller than its box has lines nobody can see.
            #>
            [CmdletBinding()]
            [OutputType([double])]
            param(
                [Parameter(Mandatory = $true)] [object] $TextBlock,
                [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Message
            )

            $probe = New-Object -TypeName System.Windows.Controls.TextBlock
            $probe.FontFamily = $TextBlock.FontFamily
            $probe.FontSize = $TextBlock.FontSize
            $probe.FontStyle = $TextBlock.FontStyle
            $probe.FontWeight = $TextBlock.FontWeight
            $probe.TextWrapping = $TextBlock.TextWrapping
            $probe.Text = $Message

            $probe.Measure([System.Windows.Size]::new($TextBlock.ActualWidth, [double]::PositiveInfinity))
            return [double] $probe.DesiredSize.Height
        }

        function New-HDTTestShellMessage {
            <#
                .SYNOPSIS
                    A shell showing one message, laid out and ready to measure.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds and lays out a WPF object graph in memory; it shows nothing.')]
            [CmdletBinding()]
            [OutputType([object])]
            param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Message)

            $window = New-HDTTestShellWindow
            $window.FindName('HDTMessageText').Text = $Message
            Update-HDTTestShellLayout -Window $window

            return $window
        }

        $script:buttonName = @('HDTOpenCmdButton', 'HDTBackButton', 'HDTCancelButton', 'HDTNextButton')
    }

    Context 'the set is enumerable at all' -ForEach $script:setCase {

        # EVERY ASSERTION BELOW IS VACUOUS IF ONE OF THESE IS EMPTY. A rule
        # table that stopped being a hashtable literal, or a refusal that
        # stopped being a single-quoted string, would turn this file green
        # while measuring nothing at all.
        It 'harvests the refusals the engine can paint into the strip' {
            @($Harvested).Count | Should -BeGreaterThan 3
        }

        It 'harvests the refusals a shipped page can produce' {
            @($Produced).Count | Should -BeGreaterThan 3
        }

        It 'reads the shipped page cap that bounds what a technician can type' {
            $MaxLength | Should -BeGreaterThan 0
        }
    }

    Context 'a refusal is readable' {

        It 'gives the whole strip width to <Label>' -ForEach $script:harvestedCase {

            $window = New-HDTTestShellMessage -Message $Message
            $message = $window.FindName('HDTMessageText')

            # 64.6px WAS THE DEFECT. The strip is the window less the rail and
            # its own margins; anything near a button's width means the message
            # is sharing a row with them again.
            $message.ActualWidth | Should -BeGreaterThan 500 -Because $Message
        }

        It 'draws every line of <Label>, clipping none' -ForEach $script:harvestedCase {

            $window = New-HDTTestShellMessage -Message $Message
            $message = $window.FindName('HDTMessageText')

            $needed = Measure-HDTTestTextHeight -TextBlock $message -Message $Message

            # HALF A PIXEL, because layout rounds to device pixels.
            $message.ActualHeight | Should -BeGreaterOrEqual ($needed - 0.5) -Because $Message
        }

        It 'keeps <Label> inside the window and clear of the page above it' -ForEach $script:harvestedCase {

            $window = New-HDTTestShellMessage -Message $Message

            $rectangle = Get-HDTTestControlRectangle -Window $window -Name 'HDTMessageText'
            $page = Get-HDTTestControlRectangle -Window $window -Name 'HDTPageHost'

            $rectangle.Top | Should -BeGreaterOrEqual ($page.Bottom - 0.5) -Because $Message
            $rectangle.Bottom | Should -BeLessOrEqual ($script:shellHeight + 0.5) -Because $Message
            $rectangle.Right | Should -BeLessOrEqual ($script:shellWidth + 0.5) -Because $Message
        }

        It 'never draws <Label> over a button' -ForEach $script:harvestedCase {

            $window = New-HDTTestShellMessage -Message $Message
            $rectangle = Get-HDTTestControlRectangle -Window $window -Name 'HDTMessageText'

            foreach ($name in $script:buttonName) {

                $button = Get-HDTTestControlRectangle -Window $window -Name $name
                $overlap = [System.Windows.Rect]::Intersect($rectangle, $button)

                $overlap.IsEmpty | Should -BeTrue -Because ('{0} sits under: {1}' -f $name, $Message)
            }
        }
    }

    Context 'saying something does not move anything' {

        BeforeAll {
            $silent = New-HDTTestShellMessage -Message ''

            $script:silentButton = @{}
            foreach ($name in $script:buttonName) {
                $script:silentButton[$name] = Get-HDTTestControlRectangle -Window $silent -Name $name
            }

            $script:silentPage = Get-HDTTestControlRectangle -Window $silent -Name 'HDTPageHost'
        }

        # A LAYOUT THAT JUMPS AS YOU TYPE IS WORSE THAN ONE THAT CLIPS. The
        # buttons hold still for EVERY refusal, however long - they are in a row
        # of their own at the bottom and nothing above them can push them.
        It 'leaves every button exactly where it was while showing <Label>' -ForEach $script:harvestedCase {

            $window = New-HDTTestShellMessage -Message $Message

            foreach ($name in $script:buttonName) {

                $shown = Get-HDTTestControlRectangle -Window $window -Name $name
                $was = $script:silentButton[$name]

                [Math]::Abs($shown.Left - $was.Left) | Should -BeLessThan 0.5 -Because ('{0}: {1}' -f $name, $Message)
                [Math]::Abs($shown.Top - $was.Top) | Should -BeLessThan 0.5 -Because ('{0}: {1}' -f $name, $Message)
            }
        }

        # AND THE PAGE HOLDS STILL FOR EVERYTHING A SHIPPED PAGE CAN SAY. The
        # band reserves the room those need, so a refusal appearing costs the
        # page nothing. A refusal only a seeded value can reach may grow it,
        # which is the deliberate trade against clipping one.
        It 'leaves the page host exactly where it was while showing <Label>' -ForEach $script:producedCase {

            $window = New-HDTTestShellMessage -Message $Message
            $shown = Get-HDTTestControlRectangle -Window $window -Name 'HDTPageHost'

            [Math]::Abs($shown.Left - $script:silentPage.Left) | Should -BeLessThan 0.5 -Because $Message
            [Math]::Abs($shown.Top - $script:silentPage.Top) | Should -BeLessThan 0.5 -Because $Message
            [Math]::Abs($shown.Width - $script:silentPage.Width) | Should -BeLessThan 0.5 -Because $Message
            [Math]::Abs($shown.Height - $script:silentPage.Height) | Should -BeLessThan 0.5 -Because $Message
        }
    }
}
