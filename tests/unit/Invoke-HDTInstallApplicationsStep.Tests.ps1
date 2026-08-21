# The InstallApplications step (DESIGN 8, DESIGN 4.2). MDT's Install
# Applications, rebuilt on the catalog, the ordering and the detection that
# 07-01 built.
#
# THE PLAN IS LOGGED BEFORE ANYTHING RUNS. DESIGN 8: "both resolve to the same
# ordered install plan, which is logged before execution". A technician reading
# the log of a build that went wrong needs to know what the step INTENDED, not
# only what it got through - and the plan is also the thing that proves the
# selection and the dependency closure were what the author expected.
#
# A 3010 REBOOTS AND COMES BACK. The step returns RebootRequested -Reenter and
# checkpoints what it has installed, so the next leg resumes at the NEXT
# application rather than restarting the list. A step that restarted the list
# would reinstall everything before the reboot on every leg; a step that did not
# come back at all would silently skip everything after it. Both are the classic
# way this feature is got wrong, and both are tested here.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'C:\Deploy'
    $script:appRoot = 'C:\Deploy\Applications'

    # A catalog with a real dependency edge: Suite needs Agent, Agent needs
    # nothing. Baseline declares no detection rule, which is DESIGN 8's
    # "installs every time".
    $script:catalogFile = @{
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Agent\app.yaml')    = @'
schemaVersion: 1
id: Contoso-Agent
name: Contoso agent
install: agent.msi /qn
detect:
  type: file
  path: C:\Program Files\Contoso\Agent\agent.exe
'@
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Suite\app.yaml')    = @'
schemaVersion: 1
id: Contoso-Suite
name: Contoso suite
install: suite.msi /qn
dependencies: [Contoso-Agent]
'@
        (Join-Path -Path $script:appRoot -ChildPath 'Corp-Baseline\app.yaml')    = @'
schemaVersion: 1
id: Corp-Baseline
name: Corporate baseline
install: baseline.cmd
'@
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Reboot\app.yaml')   = @'
schemaVersion: 1
id: Contoso-Reboot
name: Contoso thing that wants a restart
install: reboot.msi /qn
'@
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Broken\app.yaml')   = @'
schemaVersion: 1
id: Contoso-Broken
name: Contoso thing that fails
install: broken.msi /qn
'@
    }

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index          = 1
            Name           = $Name
            Type           = 'InstallApplications'
            TimeoutMinutes = 0
            Log            = $null
            Property       = $bag
        }
    }

    $script:newContext = {
        param($Process, [hashtable] $ExtraFile, [System.Collections.IDictionary] $Variable, [string] $Level = 'Info')

        $file = @{}
        foreach ($key in @($script:catalogFile.Keys)) { $file[$key] = $script:catalogFile[$key] }
        if ($null -ne $ExtraFile) {
            foreach ($key in @($ExtraFile.Keys)) { $file[$key] = $ExtraFile[$key] }
        }

        $script:fileSystem = New-HDTFakeFileSystem -File $file
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 16, 9, 0, 0, [System.DateTimeKind]::Utc))
        $script:environment = New-HDTFakeEnvironmentProvider -Variable @{ ComSpec = 'cmd.exe' }

        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
            -Process $Process -Environment $script:environment

        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock -Level $Level

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $bag[[string] $key] = $Variable[$key] }
        }

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot $script:workspaceRoot `
            -Variable $bag -Service $catalog -Log $log
        $context.SetStep(1, 'Install applications', 'InstallApplications', 'C:\HDT\Logs\Steps\001-Install.log')

        return $context
    }

    $script:jsonlRecord = {
        param($FileSystem)

        $text = ''
        if ($FileSystem.File.ContainsKey('C:\HDT\Logs\HDT.jsonl')) {
            $text = [string] $FileSystem.File['C:\HDT\Logs\HDT.jsonl']
        }

        return @(@($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
                ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'Invoke-HDTInstallApplicationsStep' {

    BeforeEach {
        # Keyed the way the CommandLine step keys the fake: the whole command line
        # as the shell would receive it.
        $script:process = New-HDTFakeProcessService -Result @{
            'cmd.exe /c agent.msi /qn'    = @{ ExitCode = 0 }
            'cmd.exe /c suite.msi /qn'    = @{ ExitCode = 0 }
            'cmd.exe /c baseline.cmd'     = @{ ExitCode = 0 }
            'cmd.exe /c reboot.msi /qn'   = @{ ExitCode = 3010 }
            'cmd.exe /c broken.msi /qn'   = @{ ExitCode = 1603 }
        }
    }

    Context 'the selection' {

        It 'installs a fixed list declared on the step' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:process.Operations)[0].Arguments[0] | Should -BeExactly 'cmd.exe'
            @($script:process.Operations)[0].Arguments[1] | Should -BeExactly '/c baseline.cmd'
        }

        It 'expands a token and splits the list it produces' {
            # DESIGN 4.1's own example is selection: "%HDTApplications%", and the
            # variable holds what the wizard or a rule put there.
            $context = & $script:newContext $script:process -Variable @{ HDTApplications = 'Corp-Baseline,Contoso-Agent' }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = '%HDTApplications%' })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:process.Operations).Count | Should -Be 2
        }

        It 'installs HDTMandatoryApplications on top of what was selected' {
            $context = & $script:newContext $script:process -Variable @{
                HDTApplications          = 'Contoso-Agent'
                HDTMandatoryApplications = 'Corp-Baseline'
            }
            $step = & $script:newStep 'Install applications' $null

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($result.Data.planned) | Should -Contain 'Corp-Baseline'
            @($result.Data.planned) | Should -Contain 'Contoso-Agent'
        }

        It 'installs HDTMandatoryApplications when the step pins its own selection' {
            # MANDATORY MEANS MANDATORY. A sequence pinning an exact list is
            # exactly the case a site-wide agent has to survive - if a pinned
            # selection could drop it, the property would mean "mandatory unless
            # a sequence author forgot", which is not a guarantee anybody can
            # build a compliance story on.
            $context = & $script:newContext $script:process -Variable @{ HDTMandatoryApplications = 'Corp-Baseline' }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Agent') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($result.Data.planned) | Should -Contain 'Corp-Baseline'
        }

        It 'installs HDTMandatoryApplications when nothing else was selected' {
            # The unattended machine whose technician picked nothing, and the
            # early return for an empty selection is what would have swallowed
            # the mandatory list.
            $context = & $script:newContext $script:process -Variable @{ HDTMandatoryApplications = 'Corp-Baseline' }
            $step = & $script:newStep 'Install applications' $null

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($result.Data.planned) | Should -Be @('Corp-Baseline')
            @($script:process.Operations).Count | Should -Be 1
        }

        It 'leaves the plan order to the dependency sort, not to which list named it' {
            # MDT installs its mandatory list first. HDT DOES NOT, and the
            # difference is deliberate: Resolve-HDTApplicationOrder emits ready
            # applications smallest id first precisely so the plan does not
            # depend on the order a selection was written in, and a mandatory
            # list that jumped the queue would spend that determinism on a
            # convention MDT only has because it processed two lists in two
            # loops.
            #
            # A SITE THAT NEEDS ITS AGENT FIRST DECLARES A DEPENDENCY, which is
            # the mechanism that already exists and the only one that survives
            # somebody adding a third application next year.
            $context = & $script:newContext $script:process -Variable @{
                HDTApplications          = 'Contoso-Agent'
                HDTMandatoryApplications = 'Corp-Baseline'
            }
            $step = & $script:newStep 'Install applications' $null

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($result.Data.planned) | Should -Be @('Contoso-Agent', 'Corp-Baseline')
        }

        It 'installs an application named by both lists exactly once' {
            $context = & $script:newContext $script:process -Variable @{
                HDTApplications          = 'Corp-Baseline,Contoso-Agent'
                HDTMandatoryApplications = 'Corp-Baseline'
            }
            $step = & $script:newStep 'Install applications' $null

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @(@($result.Data.planned) | Where-Object { $_ -eq 'Corp-Baseline' }).Count | Should -Be 1
            @($script:process.Operations).Count | Should -Be 2
        }

        It 'still reports no applications when neither list names one' {
            $context = & $script:newContext $script:process -Variable @{ HDTMandatoryApplications = '  ' }
            $step = & $script:newStep 'Install applications' $null

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            $result.Message | Should -BeExactly 'no applications were selected.'
            @($script:process.Operations).Count | Should -Be 0
        }

        It 'falls back to HDTApplications when the step declares no selection' {
            $context = & $script:newContext $script:process -Variable @{ HDTApplications = 'Corp-Baseline' }
            $step = & $script:newStep 'Install applications' $null

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:process.Operations).Count | Should -Be 1
        }

        It 'completes without running anything when nothing is selected' {
            # A sequence that offers applications and a technician who picked none
            # is an ordinary deployment, not an error.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' $null

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:process.Operations).Count | Should -Be 0
        }

        It 'installs a dependency the selection did not name, first' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($script:process.Operations)[0].Arguments[1] | Should -BeExactly '/c agent.msi /qn'
            @($script:process.Operations)[1].Arguments[1] | Should -BeExactly '/c suite.msi /qn'
        }

        It 'fails naming an application that is not in the workspace' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Not-Imported') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Not-Imported*'
        }
    }

    Context 'the plan, logged before anything runs' {

        It 'logs the ordered plan' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $plan = @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.message -like '*install plan*' })

            $plan.Count | Should -BeGreaterThan 0
            $plan[0].message | Should -BeLike '*Contoso-Agent*'
            $plan[0].message | Should -BeLike '*Contoso-Suite*'
        }

        It 'logs the plan before the first process starts' {
            # At Debug, because the command line itself is a Debug-only detail
            # (DESIGN 4.4.5) - an install command routinely carries a licence key.
            # The ORDER is what this asserts, so it has to see both lines.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem)
            $planIndex = [array]::IndexOf(@($record | ForEach-Object { $_.message -like '*install plan*' }), $true)
            $execIndex = [array]::IndexOf(@($record | ForEach-Object { $_.message -like '*baseline.cmd*' }), $true)

            $planIndex | Should -BeGreaterOrEqual 0
            $execIndex | Should -BeGreaterThan $planIndex
        }
    }

    Context 'detection' {

        It 'skips an application its rule reports installed' {
            $context = & $script:newContext $script:process -ExtraFile @{
                'C:\Program Files\Contoso\Agent\agent.exe' = 'binary'
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Agent') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:process.Operations).Count | Should -Be 0
        }

        It 'installs an application whose rule reports it absent' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Agent') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($script:process.Operations).Count | Should -Be 1
        }

        It 'installs an application that declares no rule at all' {
            # DESIGN 8's optional detect:. This one has no way to be skipped, and
            # that is the author's stated choice.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($script:process.Operations).Count | Should -Be 1
        }

        It 'reports the skip in the result data' {
            $context = & $script:newContext $script:process -ExtraFile @{
                'C:\Program Files\Contoso\Agent\agent.exe' = 'binary'
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Agent') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($result.Data['skipped']) | Should -Contain 'Contoso-Agent'
        }
    }

    Context 'exit code classification' {

        It 'treats a code outside both lists as a failure, naming the application and the code' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Broken') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Contoso-Broken*'
            $result.Message | Should -BeLike '*1603*'
        }

        It 'stops at the failure rather than installing the rest' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Broken', 'Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($script:process.Operations).Count | Should -Be 1
        }

        It 'treats 3010 as installed-and-restart, not as a failure' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Reboot') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'RebootRequested'
        }
    }

    Context 'the reboot, and coming back to the list' {

        BeforeEach {
            $script:context = & $script:newContext $script:process
            $script:step = & $script:newStep 'Install applications' ([ordered] @{
                    selection = @('Contoso-Reboot', 'Corp-Baseline')
                })
            $script:first = Invoke-HDTInstallApplicationsStep -Step $script:step -Context $script:context
        }

        It 'asks to be re-entered' {
            # Without this the loop advances stepIndex and Corp-Baseline is never
            # installed, while the run reports success.
            $script:first.Reenter | Should -BeTrue
        }

        It 'stops at the application that asked for the restart' {
            @($script:process.Operations).Count | Should -Be 1
        }

        It 'checkpoints the application that asked for the restart as installed' {
            # It IS installed - 3010 means "installed, reboot required" - so the
            # next leg must not run it again.
            @($script:context.Variable['_HDTApplicationInstalled']) | Should -Contain 'Contoso-Reboot'
        }

        It 'resumes at the NEXT application on the second leg' {
            $second = Invoke-HDTInstallApplicationsStep -Step $script:step -Context $script:context

            $second.Status | Should -BeExactly 'Completed'
            @($script:process.Operations).Count | Should -Be 2
            @($script:process.Operations)[1].Arguments[1] | Should -BeExactly '/c baseline.cmd'
        }

        It 'does not restart the list' {
            $null = Invoke-HDTInstallApplicationsStep -Step $script:step -Context $script:context

            @(@($script:process.Operations) | Where-Object { $_.Arguments[1] -eq '/c reboot.msi /qn' }).Count |
                Should -Be 1
        }
    }

    Context 'how it runs an installer' {

        It 'runs the install command through the comspec' {
            # An install command is a SHELL line - quoting, chaining and
            # redirection are routine in what a vendor documents - so it goes
            # through %ComSpec% /c exactly as the CommandLine step's command:
            # does, and the comspec comes from the injected environment provider
            # rather than from $env:.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($script:process.Operations)[0].Arguments[0] | Should -BeExactly 'cmd.exe'
        }

        It 'runs it in the application source folder' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($script:process.Operations)[0].Arguments[2] |
                Should -BeExactly (Join-Path -Path $script:appRoot -ChildPath 'Corp-Baseline\source')
        }
    }
}
