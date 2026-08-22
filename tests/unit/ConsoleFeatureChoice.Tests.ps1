# MDT's Install Roles and Features dialog, which is a TICK LIST.
#
# WHAT IT REPLACES. The generic sheet drew 'features' as
# '0 entries - a table, not a value', read-only - so the one key the step
# refuses to run without was the one key the console could not set. Making it a
# comma line fixed the reachability and not the shape: a technician still had to
# know that the IIS role is spelled 'Web-Server' and not 'IIS', type it
# correctly, and find out at the machine if they had not.
#
# THE LIST IS AN OFFER AND THE ENGINE IS THE AUTHORITY. The console is not
# running on the target and has no session to it - Get-WindowsFeature would have
# to run there - so Get-HDTFeatureCatalog ships a table, exactly as MDT ships one
# per operating system. Invoke-HDTInstallRolesStep still asks the target for its
# own list and refuses an unknown name before it installs anything.
#
# A NAME THE DOCUMENT HAS AND THE CATALOGUE DOES NOT IS STILL SHOWN, ticked. Same
# bargain as the Operating System page makes with an image the share no longer
# holds: dropping it would lose it the first time anybody ticked a box.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DEMO\sequence.yaml'

    $script:text = @'
schemaVersion: 1
id: DEMO
name: Server build
steps:
  - name: Install Roles and Features
    type: InstallRoles
    features: [Web-Server, Web-Mgmt-Console]
    includeManagementTools: true
    source: \\host\share\sxs

  - name: Bare roles
    type: InstallRoles
    features: []

  - name: Something else
    type: NoOp
'@

    $script:line = $script:text -split "`r?`n"
}

Describe 'Get-HDTFeatureCatalog' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTFeatureCatalog' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'has comment-based help' {
        (Get-Help -Name 'Get-HDTFeatureCatalog').Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'uses the Install-WindowsFeature names, which are what the step installs by' {
        # Get-WindowsOptionalFeature calls this 'IIS-WebServer'. The step runs
        # Install-WindowsFeature, which calls it 'Web-Server', and a catalogue
        # in the other naming would offer names the step cannot use.
        @(Get-HDTFeatureCatalog | ForEach-Object { $_.Name }) | Should -Contain 'Web-Server'
        @(Get-HDTFeatureCatalog | ForEach-Object { $_.Name }) | Should -Not -Contain 'IIS-WebServer'
    }

    It 'names each one the way Server Manager does, because that is what a person recognises' {
        $row = @(Get-HDTFeatureCatalog | Where-Object { $_.Name -eq 'Web-Server' })[0]

        $row.DisplayName | Should -BeExactly 'Web Server (IIS)'
    }

    It 'groups them, because a flat list of a hundred is not a list anybody reads' {
        @(Get-HDTFeatureCatalog | ForEach-Object { $_.Category } | Sort-Object -Unique).Count |
            Should -BeGreaterThan 1
    }

    It 'can be asked for one group' {
        @(Get-HDTFeatureCatalog -Category 'Roles' | Where-Object { $_.Category -ne 'Roles' }) |
            Should -BeNullOrEmpty
    }

    It 'carries no duplicate names, because a list would then tick two rows at once' {
        $name = @(Get-HDTFeatureCatalog | ForEach-Object { [string] $_.Name })

        ($name | Sort-Object -Unique).Count | Should -Be $name.Count
    }

    It 'says which one needs a payload source, since that is the failure people meet' {
        $row = @(Get-HDTFeatureCatalog | Where-Object { $_.Name -eq 'NET-Framework-Core' })[0]

        $row.Note | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-HDTConsoleFeatureChoice' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTConsoleFeatureChoice' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Get-HDTConsoleFeatureChoice').Synopsis | Should -Not -BeNullOrEmpty
        }

        It 'shows the cmdlet that produced the page' {
            $page = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Install Roles and Features'

            $page.Command | Should -Match 'Get-HDTConsoleFeatureChoice'
        }
    }

    Context 'which steps have this page' {

        It 'claims an InstallRoles step' {
            $page = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Install Roles and Features'

            $page.IsRolesStep | Should -BeTrue
        }

        It 'leaves every other step alone' {
            $page = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Something else'

            $page.IsRolesStep | Should -BeFalse
        }

        It 'comes back with the same shape for a step that is not there' {
            $page = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'No such step'

            $page.IsRolesStep | Should -BeFalse
            $page.Command | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the tick list' {

        BeforeAll {
            $script:page = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Install Roles and Features'
        }

        It 'offers the whole catalogue, not only what the document names' {
            @($script:page.Feature).Count | Should -BeGreaterThan 20
        }

        It 'ticks the ones the document names' {
            $web = @($script:page.Feature | Where-Object { $_.Name -eq 'Web-Server' })[0]

            $web.Selected | Should -BeTrue
        }

        It 'leaves the rest unticked' {
            $dns = @($script:page.Feature | Where-Object { $_.Name -eq 'DNS' })[0]

            $dns.Selected | Should -BeFalse
        }

        It 'ticks nothing at all for a step that names nothing' {
            $bare = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Bare roles'

            @($bare.Feature | Where-Object { $_.Selected }) | Should -BeNullOrEmpty
        }

        It 'carries the display name, so the list reads as Server Manager reads' {
            $web = @($script:page.Feature | Where-Object { $_.Name -eq 'Web-Server' })[0]

            $web.DisplayName | Should -BeExactly 'Web Server (IIS)'
        }
    }

    Context 'a feature the catalogue has never heard of' {

        It 'shows it, ticked, rather than dropping it' {
            # A sequence naming something unfamiliar was written that way on
            # purpose - a newer Server, or a name this table simply omits. A page
            # that hid it would delete it the first time anybody ticked a box.
            $written = @'
schemaVersion: 1
id: DEMO
name: Server build
steps:
  - name: Install Roles and Features
    type: InstallRoles
    features: [Web-Server, Acme-Widget-Server]
'@ -split "`r?`n"

            $page = Get-HDTConsoleFeatureChoice -Line $written -Path $script:path -Name 'Install Roles and Features'
            $acme = @($page.Feature | Where-Object { $_.Name -eq 'Acme-Widget-Server' })

            $acme | Should -Not -BeNullOrEmpty
            $acme[0].Selected | Should -BeTrue
        }

        It 'says the catalogue does not know it, so it does not look like a typo that will work' {
            $written = @'
schemaVersion: 1
id: DEMO
name: Server build
steps:
  - name: Install Roles and Features
    type: InstallRoles
    features: [Acme-Widget-Server]
'@ -split "`r?`n"

            $page = Get-HDTConsoleFeatureChoice -Line $written -Path $script:path -Name 'Install Roles and Features'
            $acme = @($page.Feature | Where-Object { $_.Name -eq 'Acme-Widget-Server' })[0]

            $acme.Known | Should -BeFalse
        }

        It 'marks a catalogue entry as known' {
            $web = @($script:page.Feature | Where-Object { $_.Name -eq 'Web-Server' })[0]

            $web.Known | Should -BeTrue
        }
    }

    Context 'the two settings beside the list' {

        It 'reads the management tools switch' {
            $page = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Install Roles and Features'

            $page.IncludeManagementTools | Should -BeTrue
        }

        It 'defaults it to off, which is what the step does' {
            $bare = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Bare roles'

            $bare.IncludeManagementTools | Should -BeFalse
        }

        It 'reads the payload source, the setting nothing in the console could reach' {
            $page = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Install Roles and Features'

            $page.Source | Should -BeExactly '\\host\share\sxs'
        }
    }

    Context 'a step that would not run' {

        It 'says so, because the engine refuses an empty feature list' {
            $bare = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Bare roles'

            $bare.Note | Should -Not -BeNullOrEmpty
        }

        It 'says nothing when the step names something' {
            $page = Get-HDTConsoleFeatureChoice -Line $script:line -Path $script:path -Name 'Install Roles and Features'

            $page.Note | Should -BeExactly ''
        }
    }
}
