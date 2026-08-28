# Every wizard page, against every surface that has to know about it.
#
# CLAUDE.md RULE 8, AS A TEST. A page is not added by writing its markup. It is
# added when the definition names it, the file it names exists, a new share is
# seeded with both, the engine's reader accepts it, and something downstream
# actually reads what it collects. Miss one and the page ships as decoration.
#
# EVERY MISS BELOW IS ONE THAT HAPPENED:
#
#   the markup            AdminPassword was named in the definition before the
#                         file existed; the wizard refuses to open at all
#   the seeding           New-HDTWorkspace copies the whole Templates\Wizard
#                         directory, and could not be PROVED to because the
#                         copy used Join-Path and threw on a fake drive
#   the consumer          BitLocker collected three variables that no shipped
#                         template read, so ticking the box did nothing
#   the variable map      the same three were absent from Get-HDTVariableMap,
#                         so Get-Help and the console's own name table did not
#                         know they existed
#
# IT IS WRITTEN AGAINST THE SET. A test naming AdminPassword would have passed
# for AdminPassword and failed nobody afterwards - which is the whole point of
# the rule.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name powershell-yaml -ErrorAction Stop

    # The page markup is parsed here as well as read, so WPF has to be loaded
    # whether or not the module happened to bring it in.
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $script:wizardRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/Wizard'
    $script:templateRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates'

    $script:document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText((Join-Path $script:wizardRoot 'wizard.yaml'))) -Ordered
    $script:page = @($script:document['pages'])

    # Everything a shipped sequence template says, as one string - so a
    # variable referenced as %HDTFoo% or $HDTFoo is found however it is written.
    $script:templateText = (@(Get-ChildItem -LiteralPath $script:templateRoot -Filter '*.yaml' -File) |
            ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"

    $script:mappedName = @(Get-HDTVariableMap | ForEach-Object { [string] $_.HDTName })

    # EVERY MARKUP FILE THAT SHIPS, not the ones the definition happens to
    # name. A page authored and not yet wired still has to parse, and a file
    # left behind after a page was renamed is exactly the one nobody looks at.
    $script:pageFile = @(Get-ChildItem -LiteralPath $script:wizardRoot -Filter '*.xaml' -File)

    # EVERY NAME THE DEFINITION SAYS A PAGE MUST ANSWER TO, gathered by the
    # SHAPE OF THE KEY rather than a list written here.
    #
    # A LIST WOULD HAVE MISSED THE ONE THAT SHIPPED BROKEN. The Summary page
    # declared summary.rowControl: HDTSummaryList against markup carrying no
    # such control, and the assertion that existed walked collect entries only,
    # so nothing said so - see the It below. That declaration has since been
    # removed from wizard.yaml, which is precisely why this walk must not be a
    # list of key names: the next one will be called something else again.
    # Anything the definition calls control, snippetControl or whatever comes
    # after is caught by the same rule, which is rule 8's "written against the
    # set" applied to the keys as well as the pages.
    #
    # ITERATIVE, OVER A STACK. A page is a dictionary of lists of
    # dictionaries, and the depth is not fixed - validate is one level down,
    # collect is a level down inside a list.
    $script:controlDeclaration = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in $script:page) {

        $stack = New-Object -TypeName System.Collections.Stack
        $stack.Push($current)

        while ($stack.Count -gt 0) {

            $node = $stack.Pop()

            if ($node -is [System.Collections.IDictionary]) {

                foreach ($key in @($node.Keys)) {

                    $value = $node[$key]

                    if ($value -is [System.Collections.IDictionary] -or
                        ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) {

                        $stack.Push($value)
                        continue
                    }

                    if ([string] $key -notmatch 'control$') { continue }
                    if ([string]::IsNullOrWhiteSpace([string] $value)) { continue }

                    [void] $script:controlDeclaration.Add([pscustomobject] @{
                            Page      = [string] $current['id']
                            Key       = [string] $key
                            Control   = [string] $value
                            Reference = [string] $current['reference']
                        })
                }

                continue
            }

            if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
                foreach ($item in $node) {
                    if ($null -ne $item) { $stack.Push($item) }
                }
            }
        }
    }
}

Describe 'Wizard page surface contract' {

    It 'has pages to check' {
        # A guard on the guard: an empty list passes everything below.
        $script:page.Count | Should -BeGreaterThan 3
    }

    It 'ships the markup every page names' {
        # A definition naming a file that is not there is refused before the
        # wizard opens - in WinPE, on a machine whose console has been hidden.
        $broken = @($script:page | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $script:wizardRoot ([string] $_['reference'])))
            } | ForEach-Object { '{0} -> {1}' -f $_['id'], $_['reference'] })

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'names a control and a variable on every collect entry' {
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:page) {
            if (-not $current.Contains('collect')) { continue }

            foreach ($collect in @($current['collect'])) {
                foreach ($key in @('control', 'variable')) {
                    if (-not $collect.Contains($key) -or [string]::IsNullOrWhiteSpace([string] $collect[$key])) {
                        [void] $broken.Add(('{0}: a collect entry has no {1}' -f $current['id'], $key))
                    }
                }
            }
        }

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'collects only into HDT-prefixed variables' {
        # DESIGN 3: everything the resolution engine carries is HDT-prefixed,
        # and a page on a share must not be able to set anything else.
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:page) {
            if (-not $current.Contains('collect')) { continue }

            foreach ($collect in @($current['collect'])) {
                $name = [string] $collect['variable']
                if ($name -notmatch '^HDT') { [void] $broken.Add(('{0}: {1}' -f $current['id'], $name)) }
            }
        }

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'names the control the markup actually declares, for every collect entry' {
        # A control name that no page declares collects NOTHING, silently: the
        # host looks it up, finds nothing and moves on, and the variable is
        # never set. That is a page that appears to work.
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:page) {
            if (-not $current.Contains('collect')) { continue }

            $markup = [System.IO.File]::ReadAllText((Join-Path $script:wizardRoot ([string] $current['reference'])))

            foreach ($collect in @($current['collect'])) {
                $control = [string] $collect['control']

                if ($markup -notmatch ('x:Name\s*=\s*"{0}"' -f [regex]::Escape($control))) {
                    [void] $broken.Add(('{0}: {1} is named by no control in {2}' -f $current['id'], $control, $current['reference']))
                }
            }
        }

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'names the control a validate rule watches, and the one it confirms against' {
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:page) {
            if (-not $current.Contains('validate') -or $null -eq $current['validate']) { continue }

            $markup = [System.IO.File]::ReadAllText((Join-Path $script:wizardRoot ([string] $current['reference'])))

            foreach ($key in @('control', 'confirm')) {
                if (-not $current['validate'].Contains($key)) { continue }

                $control = [string] $current['validate'][$key]

                if ($markup -notmatch ('x:Name\s*=\s*"{0}"' -f [regex]::Escape($control))) {
                    [void] $broken.Add(('{0}: validate {1} names {2}, which {3} does not declare' -f
                            $current['id'], $key, $control, $current['reference']))
                }
            }
        }

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'is seeded onto a new share, every file of it' {
        # New-HDTWorkspace copies the whole directory rather than a list, which
        # is what makes Templates\Wizard the one place of truth. This is the
        # assertion that keeps it that way.
        $fs = New-HDTFakeFileSystem

        $answer = New-HDTWorkspace -Path 'Z:\SurfaceProof' -Id 'SURFACE' -Name 'Surface proof' -FileSystem $fs -Confirm:$false

        $seeded = @($answer.WizardPage | ForEach-Object { Split-Path $_ -Leaf })
        $shipped = @(Get-ChildItem -LiteralPath $script:wizardRoot -File | ForEach-Object { $_.Name })

        foreach ($name in $shipped) {
            $seeded | Should -Contain $name -Because "$name ships in Templates\Wizard and a new share must get it"
        }
    }

    It 'is read back by the engine''s own reader, with every page present' {
        $fs = New-HDTFakeFileSystem
        $null = New-HDTWorkspace -Path 'Z:\SurfaceProof2' -Id 'SURFACE2' -Name 'Surface proof' -FileSystem $fs -Confirm:$false

        $provider = New-HDTLocalContentProvider -Root 'Z:\SurfaceProof2' -FileSystem $fs
        $read = @((Import-HDTWizardDocument -Provider $provider).Page | ForEach-Object { [string] $_.Id })

        foreach ($current in $script:page) {
            $read | Should -Contain ([string] $current['id'])
        }
    }

    It 'has something that reads what every page collects' {
        # THE HALF-FEATURE TEST. A page that sets a variable nothing consumes
        # is a screen a technician fills in for no effect - which is exactly
        # what the BitLocker page was until client.yaml grew the step.
        #
        # Consumed means: a shipped sequence template mentions it, or the
        # engine's own variable map declares it.
        $orphan = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:page) {
            if (-not $current.Contains('collect')) { continue }

            foreach ($collect in @($current['collect'])) {
                $name = [string] $collect['variable']

                if ($script:templateText -match [regex]::Escape($name)) { continue }
                if ($script:mappedName -contains $name) { continue }

                [void] $orphan.Add(('{0}: {1} is collected and read by nothing' -f $current['id'], $name))
            }
        }

        ($orphan -join ' | ') | Should -BeNullOrEmpty
    }

    It 'gathered the control names off keys of every shape, not only the collect ones' {
        # THE GUARD ON THE RULE BELOW. If the walk only ever reached collect
        # entries, that rule would pass exactly as well as the older one beside
        # it and catch nothing new - so this asserts the two SHAPES that exist,
        # by an example of each: the plain 'control' every other page uses,
        # which appears both one level down in validate and inside the collect
        # list, and a key the walk can only have found by matching the shape of
        # the name rather than the name itself.
        #
        # IT NAMED rowControl UNTIL 2026-08-28 and would now fail for the right
        # reason: that key has been removed from the definition. Asserting a
        # key by name is asserting the definition still says one particular
        # thing, which is the list this walk exists to avoid - so what is
        # asserted is that the walk reached a *control key that is NOT called
        # 'control', and reached the Summary page, whose only declaration is
        # nested under summary and is what a collect-only walk misses.
        $key = @($script:controlDeclaration | ForEach-Object { $_.Key } | Sort-Object -Unique)

        $key | Should -Contain 'control'
        @($key | Where-Object { $_ -ne 'control' }) | Should -Not -BeNullOrEmpty
        @($script:controlDeclaration | ForEach-Object { $_.Page }) | Should -Contain 'Summary'
    }

    It 'names a control the markup declares, for every key in the definition that names one' {
        # THE DEFECT THIS IS THE GENERAL FORM OF. Summary declared
        #
        #     summary:
        #       rowControl: HDTSummaryList
        #
        # and Summary.xaml carried no such control. New-HDTWizardHost does
        #
        #     $rowControl = $pageRoot.FindName($Current.Page.Summary.RowControl)
        #     if ($null -ne $rowControl) { $rowControl.ItemsSource = ... }
        #
        # so the miss was swallowed by the guard and the "Ready to deploy"
        # screen showed the snippet with NOT ONE ROW above it - no task
        # sequence, no computer name, nothing. Get-HDTWizardSummary had
        # computed them all and handed them over.
        #
        # A GUARD THAT SWALLOWS A MISS IS RIGHT AT RUNTIME - a page half a
        # release ahead of a share must still open in WinPE - and it is exactly
        # why the miss has to be caught here instead.
        $broken = @($script:controlDeclaration | Where-Object {

                $markup = [System.IO.File]::ReadAllText((Join-Path $script:wizardRoot $_.Reference))
                $markup -notmatch ('x:Name\s*=\s*"{0}"' -f [regex]::Escape($_.Control))

            } | ForEach-Object { '{0}: {1}: {2} is declared by no control in {3}' -f $_.Page, $_.Key, $_.Control, $_.Reference })

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'gives every control in a page its own grid cell' {
        # THE GENERAL FORM OF THE BITLOCKER DEFECT. The escrow ComboBox was
        # authored at Grid.Row="2" Grid.Column="1" - the PIN box's cell - so
        # WPF drew it ON TOP of the PasswordBox and the PIN could not be
        # clicked or typed at all, while the "Recovery key" label two rows down
        # sat beside an empty cell. It renders as a page that looks finished.
        #
        # THE ONE OVERLAP THAT IS DELIBERATE IS THE REVEAL PAIR, and it is
        # allowed BY THE CONVENTION Get-HDTWizardRevealPair reads rather than
        # by naming AdminPassword: PasswordBox.Password is not a
        # DependencyProperty, so a revealable password is HDTFooBox and
        # HDTFooRevealBox stacked in one cell with the eye swapping which is
        # visible. Anything else in one cell is two controls fighting.
        $xaml = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $broken = New-Object -TypeName System.Collections.ArrayList
        $cellCount = 0

        foreach ($file in $script:pageFile) {

            $document = [xml] [System.IO.File]::ReadAllText($file.FullName)

            foreach ($grid in @($document.SelectNodes('//*'))) {

                if ($grid.LocalName -ne 'Grid') { continue }

                $cell = @{}

                foreach ($child in @($grid.ChildNodes)) {

                    if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }

                    # Grid.RowDefinitions and friends are property elements,
                    # not controls, and they carry the dot in their name.
                    if ($child.LocalName -like '*.*') { continue }

                    $row = $child.GetAttribute('Grid.Row')
                    $column = $child.GetAttribute('Grid.Column')

                    if ([string]::IsNullOrEmpty($row)) { $row = '0' }
                    if ([string]::IsNullOrEmpty($column)) { $column = '0' }

                    $at = '{0},{1}' -f $row, $column
                    if (-not $cell.ContainsKey($at)) { $cell[$at] = New-Object -TypeName System.Collections.ArrayList }

                    [void] $cell[$at].Add([pscustomobject] @{
                            Element = [string] $child.LocalName
                            Name    = [string] $child.GetAttribute('Name', $xaml)
                        })
                }

                foreach ($at in @($cell.Keys)) {

                    $cellCount++

                    $occupant = @($cell[$at])
                    if ($occupant.Count -lt 2) { continue }

                    $name = @($occupant | ForEach-Object { $_.Name } | Sort-Object)

                    $isRevealPair = $false
                    if ($occupant.Count -eq 2 -and ($name -notcontains '')) {

                        $base = @($name | Where-Object { $_ -notmatch 'RevealBox$' })

                        if ($base.Count -eq 1 -and $base[0] -match 'Box$') {
                            $stem = $base[0].Substring(0, $base[0].Length - 3)
                            $isRevealPair = ($name -contains ('{0}RevealBox' -f $stem))
                        }
                    }

                    if ($isRevealPair) { continue }

                    [void] $broken.Add(('{0}: row,column {1} holds {2}' -f
                            $file.Name, $at, (($occupant | ForEach-Object {
                                    if ([string]::IsNullOrEmpty($_.Name)) { $_.Element } else { '{0} {1}' -f $_.Element, $_.Name }
                                }) -join ' and ')))
                }
            }
        }

        $cellCount | Should -BeGreaterThan 20 -Because 'a walk that found no cells passes this without reading anything'
        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'declares both namespaces on every page, and parses' {
        # A FRAGMENT INHERITS NOTHING. XamlReader loads each page on its own,
        # so a page missing xmlns:x throws "'x' is an undeclared prefix" and a
        # page missing xmlns throws before that - which on a bench is a wizard
        # that never opens, with the console already hidden behind it.
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($file in $script:pageFile) {

            $text = [System.IO.File]::ReadAllText($file.FullName)

            if ($text -notmatch 'xmlns\s*=\s*"http://schemas\.microsoft\.com/winfx/2006/xaml/presentation"') {
                [void] $broken.Add(('{0}: no default xmlns' -f $file.Name))
            }

            if ($text -notmatch 'xmlns:x\s*=\s*"http://schemas\.microsoft\.com/winfx/2006/xaml"') {
                [void] $broken.Add(('{0}: no xmlns:x' -f $file.Name))
            }

            try {
                $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $text)
                $null = [System.Windows.Markup.XamlReader]::Load($reader)
            } catch {
                [void] $broken.Add(('{0}: {1}' -f $file.Name, $_.Exception.Message))
            }
        }

        $script:pageFile.Count | Should -BeGreaterThan 5
        ($broken -join ' | ') | Should -BeNullOrEmpty
    }
}
