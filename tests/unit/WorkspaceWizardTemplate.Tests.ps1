# A NEW SHARE COMES WITH A WIZARD, the way MDT's does.
#
# Deployment Workbench's New Deployment Share populates Scripts\ with the
# LiteTouch panes, so a share created five minutes ago can already ask a
# technician for a computer name. HDT's New-HDTWorkspace made Scripts\ and left
# it empty - and Start-HDTDeployment, finding no Scripts\UI\wizard.yaml, says
# "nothing is asked and nothing waits" and deploys unattended.
#
# THAT IS A WORSE DIVERGENCE THAN IT LOOKS. The wizard is not an extra: it is
# how a technician chooses a task sequence and names the machine. A share that
# silently has none is a share whose first deployment does something nobody was
# asked about.
#
# THE PAGES ARE SAMPLES, AND THEY ARE MEANT TO BE EDITED. They land on the share
# rather than staying in the module for exactly that reason - DESIGN 11.2 puts
# the wizard on the share, so an administrator changes a page without touching
# the toolkit.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:templateRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/Wizard'
}

Describe 'the wizard a share is created with' {

    Context 'what the module ships' {

        It 'ships the definition' {
            Test-Path -LiteralPath (Join-Path -Path $script:templateRoot -ChildPath 'wizard.yaml') |
                Should -BeTrue
        }

        It 'ships every page the definition names, and a definition the engine accepts' {
            # A DEFINITION NAMING A PAGE THAT IS NOT THERE is a wizard that dies
            # at the first screen, in WinPE, on the machine in front of somebody.
            #
            # PARSED AND VALIDATED BY THE ENGINE'S OWN PAIR. Import-HDTWizardDocument
            # takes a content PROVIDER and always looks for Scripts\UI\wizard.yaml,
            # which a template folder is not - so the reader is exercised in the
            # test below, against a share this command actually created.
            $document = InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Root = $script:templateRoot } {
                param($Root)

                $path = Join-Path -Path $Root -ChildPath 'wizard.yaml'
                $parsed = ConvertFrom-HDTYaml -Yaml ([System.IO.File]::ReadAllText($path)) -Path $path

                Assert-HDTWizardDocument -Document $parsed -Path $path
                $parsed
            }

            foreach ($page in @($document['pages'])) {
                Test-Path -LiteralPath (Join-Path -Path $script:templateRoot -ChildPath ([string] $page['reference'])) |
                    Should -BeTrue -Because ('{0} is named by wizard.yaml' -f $page['reference'])
            }
        }

        It 'is read by the payload''s own reader once it is on a share' {
            # THE TEST THAT MATTERS: a share created by the command, read the way
            # Start-HDTDeployment reads one.
            $scratch = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('hdt-wizard-{0}' -f [guid]::NewGuid())

            try {
                [void] (New-HDTWorkspace -Path $scratch -Id 'HDT-WIZ' -Confirm:$false)

                $wizard = Import-HDTWizardDocument -Provider (New-HDTLocalContentProvider -Root $scratch)

                @($wizard.Page).Count | Should -BeGreaterThan 0
            } finally {
                # A directory this test created, removed by the code that made it.
                if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
            }
        }
    }

    Context 'what a new share gets' {

        BeforeAll {
            $script:fileSystem = New-HDTFakeFileSystem
            [void] (New-HDTWorkspace -Path 'C:\ws' -Id 'HDT-NEW' -FileSystem $script:fileSystem -Confirm:$false)
        }

        It 'gets the definition' {
            $script:fileSystem.TestPath('C:\ws\Scripts\UI\wizard.yaml') | Should -BeTrue
        }

        It 'gets the pages it names' {
            $script:fileSystem.TestPath('C:\ws\Scripts\UI\TaskSequence.xaml') | Should -BeTrue
            $script:fileSystem.TestPath('C:\ws\Scripts\UI\Summary.xaml') | Should -BeTrue
        }

        It 'gets them as files it can read back' {
            [string] $script:fileSystem.ReadAllText('C:\ws\Scripts\UI\wizard.yaml') |
                Should -BeLike '*pages:*'
        }
    }

    Context 'a share that already has one' {

        It 'is left alone, because those pages are somebody''s edits' {
            # THE PAGES ARE MEANT TO BE EDITED, so writing over them is writing
            # over the work. A share being created has none of this; a folder
            # that somehow does keeps what it has.
            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\ws2\Scripts\UI\wizard.yaml' = "schemaVersion: 1`npages:`n  - id: Mine`n    reference: Mine.xaml`n"
            }

            [void] (New-HDTWorkspace -Path 'C:\ws2' -Id 'HDT-NEW' -FileSystem $fileSystem -Confirm:$false)

            [string] $fileSystem.ReadAllText('C:\ws2\Scripts\UI\wizard.yaml') | Should -BeLike '*Mine.xaml*'
        }
    }
}
