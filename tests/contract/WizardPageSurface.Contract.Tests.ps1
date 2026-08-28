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

    $script:wizardRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/Wizard'
    $script:templateRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates'

    $script:document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText((Join-Path $script:wizardRoot 'wizard.yaml'))) -Ordered
    $script:page = @($script:document['pages'])

    # Everything a shipped sequence template says, as one string - so a
    # variable referenced as %HDTFoo% or $HDTFoo is found however it is written.
    $script:templateText = (@(Get-ChildItem -LiteralPath $script:templateRoot -Filter '*.yaml' -File) |
            ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"

    $script:mappedName = @(Get-HDTVariableMap | ForEach-Object { [string] $_.HDTName })
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
}
