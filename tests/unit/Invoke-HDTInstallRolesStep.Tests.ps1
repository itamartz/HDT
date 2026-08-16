# The InstallRoles step (DESIGN 10.2). Install-WindowsFeature behind
# IFeatureService, so the whole step runs under Pester with no server.
#
# A TYPO'D FEATURE NAME FAILS BEFORE ANYTHING IS INSTALLED, and the message
# offers the names it might have meant. DESIGN 10.2: "a typo'd feature name
# should fail fast with the list of valid names, not halfway through a server
# build". Halfway through is the expensive place to find out - the machine is
# then neither the old thing nor the new one.
#
# ALREADY-INSTALLED FEATURES ARE NOT REINSTALLED. Install-WindowsFeature would
# tolerate it, but the step's job is to be re-runnable across the reboot a role
# asks for, and reinstalling a role that is already there on every leg is how a
# build takes an hour longer than it needs to.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index          = 1
            Name           = $Name
            Type           = 'InstallRoles'
            TimeoutMinutes = 0
            Log            = $null
            Property       = $bag
        }
    }

    $script:newContext = {
        param($Feature, $Content, [System.Collections.IDictionary] $Variable)

        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 16, 9, 0, 0, [System.DateTimeKind]::Utc))

        $argument = @{
            FileSystem = $script:fileSystem
            Clock      = $script:clock
            Feature    = $Feature
        }
        if ($null -ne $Content) { $argument['Content'] = $Content }

        $catalog = New-HDTServiceCatalog @argument

        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock -Level 'Info'

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $bag[[string] $key] = $Variable[$key] }
        }

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
            -Variable $bag -Service $catalog -Log $log
        $context.SetStep(1, 'Install roles', 'InstallRoles', 'C:\HDT\Logs\Steps\001-Roles.log')

        return $context
    }
}

Describe 'Invoke-HDTInstallRolesStep' {

    BeforeEach {
        $script:feature = New-HDTFakeFeatureService -Feature @{
            'Web-Server'            = 'Available'
            'Web-Mgmt-Console'      = 'Available'
            'Web-Asp-Net45'         = 'Available'
            'NET-Framework-45-Core' = 'Installed'
            'NET-Framework-Core'    = 'Removed'
            'DHCP'                  = 'Available'
        }
    }

    Context 'installing' {

        It 'installs the features it was given, in one call' {
            # Install-WindowsFeature takes the whole list and resolves the
            # dependency graph itself. Calling it once per feature would be slower
            # and would report a partial state between calls.
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Web-Server', 'Web-Mgmt-Console') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $install = @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' })
            $install.Count | Should -Be 1
            @($install[0].Arguments[0]) | Should -Be @('Web-Server', 'Web-Mgmt-Console')
        }

        It 'passes includeManagementTools through' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{
                    features               = @('Web-Server')
                    includeManagementTools = $true
                })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' })[0].Arguments[1] |
                Should -BeTrue
        }

        It 'defaults includeManagementTools to false' {
            # MDT does not add tools a sequence did not ask for, and a server
            # build that quietly gained a GUI console is a surprise.
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Web-Server') })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' })[0].Arguments[1] |
                Should -BeFalse
        }

        It 'reports the features it installed in the result data' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Web-Server') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($result.Data['installed']) | Should -Contain 'Web-Server'
        }
    }

    Context 'what it does not reinstall' {

        It 'leaves out a feature that is already installed' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{
                    features = @('Web-Server', 'NET-Framework-45-Core')
                })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @(@($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' })[0].Arguments[0]) |
                Should -Be @('Web-Server')
        }

        It 'installs nothing at all when every feature is already there' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('NET-Framework-45-Core') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' }).Count | Should -Be 0
        }

        It 'still installs a feature whose payload was Removed' {
            # Removed is not Installed. It is the .NET 3.5 case, and it is exactly
            # the one that needs source:.
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('NET-Framework-Core') })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' }).Count | Should -Be 1
        }
    }

    Context 'the side-by-side source' {

        It 'passes a source path through' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{
                    features = @('NET-Framework-Core')
                    source   = 'X:\Sources\SxS'
                })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' })[0].Arguments[2] |
                Should -BeExactly 'X:\Sources\SxS'
        }

        It 'resolves a relative source through the content provider' {
            # DESIGN 10.2: it must work identically from a share and from
            # standalone media, which is what the provider is for.
            $content = New-HDTFakeContentProvider -Root 'C:\Deploy'
            $context = & $script:newContext $script:feature $content
            $step = & $script:newStep 'Install roles' ([ordered] @{
                    features = @('NET-Framework-Core')
                    source   = 'Sources\SxS'
                })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($content.GetOperationName()) | Should -Contain 'ResolveContent'
        }

        It 'expands a token in the source' {
            $context = & $script:newContext $script:feature $null @{ HDTSxSRoot = 'Y:\SxS' }
            $step = & $script:newStep 'Install roles' ([ordered] @{
                    features = @('NET-Framework-Core')
                    source   = '%HDTSxSRoot%'
                })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' })[0].Arguments[2] |
                Should -BeExactly 'Y:\SxS'
        }

        It 'passes an empty source when the step declares none' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Web-Server') })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' })[0].Arguments[2] |
                Should -BeExactly ''
        }
    }

    Context 'a name the target OS does not know' {

        It 'fails naming the feature' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Web-Srever') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Web-Srever*'
        }

        It 'installs nothing at all' {
            # FAIL FAST. Half a server build is worse than none of one.
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Web-Server', 'Web-Srever') })

            $null = Invoke-HDTInstallRolesStep -Step $step -Context $context

            @($script:feature.Operations | Where-Object { $_.Operation -eq 'InstallFeature' }).Count | Should -Be 0
        }

        It 'offers the names it might have meant' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Web-Srever') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            # 'Web-' is the part the typo got right, and every Web feature in the
            # catalog is a candidate an administrator can read and pick from.
            $result.Message | Should -BeLike '*Web-Server*'
        }

        It 'says how many features the OS does know when nothing looks similar' {
            # A name with no near match gets a count rather than three hundred
            # feature names in a log line.
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Nonsense') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*6*'
        }
    }

    Context 'what the OS came back with' {

        It 'asks for a restart when the install wants one' {
            $feature = New-HDTFakeFeatureService -Feature @{ 'DHCP' = 'Available' } `
                -Outcome @{ 'DHCP' = @{ Success = $true; RestartNeeded = $true } }
            $context = & $script:newContext $feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('DHCP') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'RebootRequested'
        }

        It 'does not ask to be re-entered' {
            # Unlike InstallApplications, this step installs its whole list in one
            # call - there is no list position to come back to.
            $feature = New-HDTFakeFeatureService -Feature @{ 'DHCP' = 'Available' } `
                -Outcome @{ 'DHCP' = @{ Success = $true; RestartNeeded = $true } }
            $context = & $script:newContext $feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('DHCP') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Reenter | Should -BeFalse
        }

        It 'fails when the install did not succeed' {
            $feature = New-HDTFakeFeatureService -Feature @{ 'DHCP' = 'Available' } `
                -Outcome @{ 'DHCP' = @{ Success = $false; ExitCode = 1; Message = 'blocked by policy' } }
            $context = & $script:newContext $feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('DHCP') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*DHCP*'
        }
    }

    Context 'what it refuses' {

        It 'fails when the step declares no features' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' $null

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*features*'
        }

        It 'fails when the features list is empty' {
            $context = & $script:newContext $script:feature
            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @() })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
        }

        It 'fails naming the service when no feature service was injected' {
            $fileSystem = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 16, 9, 0, 0, [System.DateTimeKind]::Utc))
            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level 'Info'
            $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
                -Variable $bag -Service $catalog -Log $log
            $context.SetStep(1, 'Install roles', 'InstallRoles', 'C:\HDT\Logs\Steps\001-Roles.log')

            $step = & $script:newStep 'Install roles' ([ordered] @{ features = @('Web-Server') })

            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Feature*'
        }
    }
}
