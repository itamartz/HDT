# THE APPLICATIONS PAGE, AND THE COMMAND THAT FILLS IT.
#
# DESIGN 11.2 lists this page and HDT drew it before it could fill it:
# Scripts\UI\Applications.xaml carried three hand-typed CheckBoxes and said so
# in its own comment, exactly as TaskSequence.xaml did before W3. A share with
# eleven applications offered three, and two of those did not exist.
#
# THE LIST IS THE CATALOG. Applications\<Id>\app.yaml is what
# Resolve-HDTApplicationOrder matches a selection against, so the id this offers
# is the id off the projected catalog entry and never the folder name it was
# read from. They are meant to be the same - Assert-HDTApplicationDocument says
# "the id is the folder name under Applications\" - but nothing makes them
# agree, and a picker that trusted the folder while the engine trusts the
# document would put a technician's tick somewhere the installer cannot find.
#
# IT IS PURE, so it is tested here rather than on a VM: an IFileSystem, a
# variable bag, and rows out.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = 'Z:\Deploy'

    $script:document = {
        param([string] $Id, [string] $Name, [string] $Publisher, [string] $Version)

        $text = "schemaVersion: 1`nid: $Id`nname: $Name`n"
        if (-not [string]::IsNullOrWhiteSpace($Publisher)) { $text += "publisher: $Publisher`n" }
        if (-not [string]::IsNullOrWhiteSpace($Version)) { $text += "version: $Version`n" }

        return ($text + "install:`n  command: setup.exe /S`n")
    }

    # A share with three applications, deliberately not in alphabetical order on
    # disk, and one folder that is not an application at all.
    $script:share = @{
        'Z:\Deploy\Applications\VSCode-1.96\app.yaml'       = (& $script:document 'VSCode-1.96' 'Visual Studio Code' 'Microsoft' '1.96')
        'Z:\Deploy\Applications\7Zip-24.09\app.yaml'        = (& $script:document '7Zip-24.09' '7-Zip' 'Igor Pavlov' '24.09')
        'Z:\Deploy\Applications\Firefox-ESR-128\app.yaml'   = (& $script:document 'Firefox-ESR-128' 'Mozilla Firefox ESR' 'Mozilla' '128')
        'Z:\Deploy\Applications\NotAnApplication\readme.txt' = 'left here by somebody'
    }

    $script:newFileSystem = { New-HDTFakeFileSystem -File $script:share }

    $script:bag = {
        param([System.Collections.IDictionary] $Value)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $live[[string] $key] = $Value[$key] }
        }

        return $live
    }
}

Describe 'Get-HDTWizardApplication' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTWizardApplication' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what the share carries' {

        It 'offers every folder that holds an app.yaml' {
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            @($answer.Choice | ForEach-Object { [string] $_.Id }) |
                Should -Be @('7Zip-24.09', 'Firefox-ESR-128', 'VSCode-1.96')
        }

        It 'offers nothing for a folder without one' {
            # A share people actually use collects readmes and half-copied
            # folders. Offering one is a deployment that dies at its first app.
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            @($answer.Choice | ForEach-Object { [string] $_.Id }) | Should -Not -Contain 'NotAnApplication'
        }

        It 'sorts by id, so the list does not rearrange itself between boots' {
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            $offered = @($answer.Choice | ForEach-Object { [string] $_.Id })

            $offered | Should -Be (@($offered) | Sort-Object)
        }

        It 'puts the name and the version on the row, because a technician reads the name' {
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            [string] (@($answer.Choice | Where-Object { $_.Id -eq '7Zip-24.09' })[0].Text) |
                Should -Be '7-Zip 24.09'
        }

        It 'does not print the version twice when the name already ends with it' {
            # FOUND ON THE LAB SHARE, NOT IN A FIXTURE. Import-HDTApplication
            # builds a name out of the publisher, the product and the version,
            # so the real catalog holds 'Acrobat Acrobat Reader DC 2600121771'
            # with version '2600121771' beside it - and appending gave a row
            # reading '... 2600121771 2600121771'. The version is added because
            # a technician chooses between two builds of one product; a name
            # that already says which build needs no help.
            $file = @{ 'Z:\Deploy\Applications\Reader\app.yaml' = (& $script:document 'Reader' 'Acrobat Reader DC 26.001' 'Adobe' '26.001') }
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (New-HDTFakeFileSystem -File $file)

            [string] (@($answer.Choice)[0].Text) | Should -Be 'Acrobat Reader DC 26.001'
        }

        It 'leaves the version off a row that has none rather than printing a gap' {
            $file = @{ 'Z:\Deploy\Applications\Agent\app.yaml' = (& $script:document 'Agent' 'Site agent' '' '') }
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (New-HDTFakeFileSystem -File $file)

            [string] (@($answer.Choice)[0].Text) | Should -Be 'Site agent'
        }
    }

    Context 'a share that is not ready' {

        It 'says so rather than throwing when there is no Applications folder' {
            # NOT AN EXCEPTION, AND NOT A PROBLEM EITHER. Applications are
            # optional - DESIGN 2.1 - and a workspace that deploys an image and
            # no software is legitimate. This page is skipped on such a share,
            # not complained about.
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (New-HDTFakeFileSystem -File @{})

            @($answer.Choice).Count | Should -Be 0
            @($answer.Problem).Count | Should -Be 0
        }

        It 'excludes an application it cannot read AND names it' {
            # BOTH HALVES MATTER. Offering it means a deployment that dies
            # halfway down the list; dropping it in silence means "why is mine
            # not on the page?" has no answer anywhere.
            $file = $script:share.Clone()
            $file['Z:\Deploy\Applications\Broken\app.yaml'] = "schemaVersion: 1`nid: Broken`nname: Broken`ninstal:`n  command: setup.exe`n"

            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (New-HDTFakeFileSystem -File $file)

            @($answer.Choice | ForEach-Object { [string] $_.Id }) | Should -Not -Contain 'Broken'
            [string] ($answer.Problem -join ' ') | Should -BeLike '*Broken*'
        }
    }

    Context 'what is already ticked' {

        It 'preticks what HDTApplications resolved to' {
            # MDT PREFILLS FROM THE RULES AND SO DOES THIS. A site that selects
            # its standard load in rules.yaml shows the technician what they are
            # about to get rather than an empty page they have to rebuild.
            $variable = & $script:bag @{ HDTApplications = '7Zip-24.09, VSCode-1.96' }

            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) -Variable $variable

            @($answer.Choice | Where-Object { $_.IsSelected } | ForEach-Object { [string] $_.Id }) |
                Should -Be @('7Zip-24.09', 'VSCode-1.96')
        }

        It 'splits the same way the step does, so a semicolon list is not one long id' {
            # Invoke-HDTInstallApplicationsStep splits on [,;\r\n]. A picker that
            # split on the comma alone would leave a semicolon list unticked and
            # the technician would tick it again - or, worse, not.
            $variable = & $script:bag @{ HDTApplications = '7Zip-24.09;Firefox-ESR-128' }

            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) -Variable $variable

            @($answer.Choice | Where-Object { $_.IsSelected } | ForEach-Object { [string] $_.Id }) |
                Should -Be @('7Zip-24.09', 'Firefox-ESR-128')
        }

        It 'ticks nothing when the variable is absent, because ticking nothing is a normal answer' {
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            @($answer.Choice | Where-Object { $_.IsSelected }).Count | Should -Be 0
        }

        It 'names an id the share does not carry rather than dropping it in silence' {
            # The same refusal Get-HDTWizardSequence makes: a rule naming an
            # application this share has never held is a mistake somebody has to
            # be told about, and the page has no row to show its tick on.
            $variable = & $script:bag @{ HDTApplications = '7Zip-24.09, Photoshop' }

            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) -Variable $variable

            [string] ($answer.Problem -join ' ') | Should -BeLike '*Photoshop*'
        }

        It 'leaves HDTMandatoryApplications off the page entirely' {
            # MDT DOES NOT LIST THEM AND NEITHER DOES THIS. The step installs
            # them whatever the technician picked, so a tick beside one would be
            # a control that changes nothing - and one the technician could
            # clear, which is worse. The page says so in a hint instead.
            $variable = & $script:bag @{ HDTMandatoryApplications = 'VSCode-1.96' }

            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) -Variable $variable

            @($answer.Choice | Where-Object { $_.IsSelected }).Count | Should -Be 0
        }
    }

    Context 'the field it hands the host' {

        It 'names the control the shipped page calls its list' {
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            [string] $answer.Field.Name | Should -Be 'HDTApplicationList'
        }

        It 'carries the rows, because the page carries none of its own' {
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            @($answer.Field.Item).Count | Should -Be 3
        }

        It 'carries no Text, because a list of ticks has no single value to write' {
            # THE HOST USED TO DEMAND ONE. Apply wrote $control.$property for
            # every field it was handed, so a rows-only field threw "The
            # property 'Text' cannot be found on this object" while the page was
            # being built - and an ItemsControl has no Text to write to anyway.
            # Found by opening the page, which is the only way it could be.
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem)

            $answer.Field.PSObject.Properties['Text'] | Should -BeNullOrEmpty
        }

        It 'accepts a renamed control, so a site with its own page need not fork this' {
            $answer = Get-HDTWizardApplication -WorkspaceRoot $script:root -FileSystem (& $script:newFileSystem) -Control 'MyAppList'

            [string] $answer.Field.Name | Should -Be 'MyAppList'
        }
    }
}
