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
        # TWO APPLICATIONS THAT NEED EACH OTHER, which is an authoring error
        # Resolve-HDTApplicationOrder refuses rather than hangs on. The step's
        # job here is to log how far the resolution got before it did.
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Ouroboros\app.yaml') = @'
schemaVersion: 1
id: Contoso-Ouroboros
name: Contoso thing that needs the other one
install: ouroboros.msi /qn
dependencies: [Contoso-Serpent]
'@
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Serpent\app.yaml')   = @'
schemaVersion: 1
id: Contoso-Serpent
name: Contoso thing that needs the first one
install: serpent.msi /qn
dependencies: [Contoso-Ouroboros]
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
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Licensed\app.yaml') = @'
schemaVersion: 1
id: Contoso-Licensed
name: Contoso thing with a licence key
install: licensed.exe /passive /PASSWORD=hunter2 VALUE_OF_PASSWORD=hunter2 /qn
'@

        # AN INSTALLER THAT TALKS. A silent MSI prints nothing, which is why
        # throwing its output away looked harmless for so long; a setup.exe
        # wrapper prints the reason it gave up, and that is the one HDT was
        # discarding.
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Chatty\app.yaml')   = @'
schemaVersion: 1
id: Contoso-Chatty
name: Contoso thing that talks
install: chatty.exe /S
'@

        # AN INSTALLER THAT ECHOES ITS OWN ARGUMENTS BACK, which is how a
        # credential reaches the log by a route the command-line redaction never
        # sees.
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Echo\app.yaml')     = @'
schemaVersion: 1
id: Contoso-Echo
name: Contoso thing that echoes its arguments
install: echo.exe /S
'@

        # AN INSTALLER WITH A PROGRESS BAR. Three hundred lines of it, which is
        # what the cap exists for.
        (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Loud\app.yaml')     = @'
schemaVersion: 1
id: Contoso-Loud
name: Contoso thing that never stops talking
install: loud.exe /S
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
        param($Process, [hashtable] $ExtraFile, [System.Collections.IDictionary] $Variable, [string] $Level = 'Info',
            [object] $Progress)

        $file = @{}
        foreach ($key in @($script:catalogFile.Keys)) { $file[$key] = $script:catalogFile[$key] }
        if ($null -ne $ExtraFile) {
            foreach ($key in @($ExtraFile.Keys)) { $file[$key] = $ExtraFile[$key] }
        }

        $script:fileSystem = New-HDTFakeFileSystem -File $file
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 16, 9, 0, 0, [System.DateTimeKind]::Utc))
        $script:environment = New-HDTFakeEnvironmentProvider -Variable @{ ComSpec = 'cmd.exe' }

        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
            -Process $Process -Environment $script:environment -Progress $Progress

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
            'cmd.exe /c licensed.exe /passive /PASSWORD=hunter2 VALUE_OF_PASSWORD=hunter2 /qn' = @{ ExitCode = 0 }

            # THE ACROBAT-1603 CASE, WHICH IS THE WHOLE POINT. The installer
            # says why on its way out and HDT recorded only the number.
            'cmd.exe /c broken.msi /qn'   = @{
                ExitCode       = 1603
                StandardOutput = "starting setup`r`nfatal error 1603: another installation is in progress"
                StandardError  = 'MSI (s) returned 1603'
            }

            'cmd.exe /c chatty.exe /S'    = @{
                ExitCode       = 0
                StandardOutput = "unpacking`r`ninstalling`r`ndone"
                StandardError  = 'a note on stderr'
            }

            'cmd.exe /c echo.exe /S'      = @{
                ExitCode       = 0
                StandardOutput = 'running: echo.exe /S VALUE_OF_PASSWORD=hunter2'
            }

            'cmd.exe /c loud.exe /S'      = @{
                ExitCode       = 0
                StandardOutput = ((1..300 | ForEach-Object { 'progress line {0}' -f $_ }) -join "`r`n")
            }
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

    Context 'what it says while it is installing' {

        # THE STEP WAS SILENT FOR THE WHOLE OF ITS RUN, and on this lab it is
        # one of the two longest steps there is. Measured on LT-7FJ45S2,
        # run-20260829-172208: two applications, an Acrobat Reader MSI carrying
        # a 687 MB patch and TightVNC, both installed over SMB, and the step
        # wrote exactly four lines - the plan, then nothing for minutes, then
        # one line per application after each had finished, then a total.
        #
        # EVERY ONE OF THOSE IS A BOUNDARY LINE. Nothing at all is written
        # between starting an installer and it returning, so the progress card
        # showed "Install Applications" and a motionless bar, and - because
        # elapsed on that card is derived from the FIRST and LAST record in the
        # log - the clock stopped too. A working machine and a hung one look
        # identical.
        #
        # THE FACT WAS ALREADY IN HAND AND WAS SIMPLY NOT SAID. The step
        # resolves the whole ordered plan before it starts and logs it; from
        # that it knows it is on application 1 of 2 and which one. So this needs
        # no output capture from msiexec, no new service and no second channel -
        # only a record written where there was none, and the nudge that makes
        # the window re-read it, exactly as ApplyImage and ApplyDrivers do.

        It 'says which application it is starting, before it starts it' {
            # BEFORE, NOT AFTER, and that is the whole point: a line written
            # after Acrobat returns is a line four minutes too late to tell
            # anybody what the machine was doing.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem)

            $startIndex = [array]::IndexOf(@($record | ForEach-Object {
                        ($_.event -eq 'step.progress') -and ([string] $_.data.application -eq 'Contoso-Agent') }), $true)
            $doneIndex = [array]::IndexOf(@($record | ForEach-Object {
                        [string] $_.message -like "installed 'Contoso agent'*" }), $true)

            $startIndex | Should -BeGreaterOrEqual 0
            $doneIndex | Should -BeGreaterThan $startIndex
        }

        It 'counts the applications, so the line says one of two' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            # THE ANNOUNCEMENTS, not every progress record. Each application
            # produces two - one when it starts and one when it is banked - and
            # the count a technician reads is on the first of each pair.
            $progress = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.event -eq 'step.progress' -and [string] $_.message -like 'installing *' })

            $progress.Count | Should -Be 2
            [int] $progress[0].data.done | Should -Be 1
            [int] $progress[0].data.total | Should -Be 2
            [int] $progress[1].data.done | Should -Be 2
            [int] $progress[1].data.total | Should -Be 2
        }

        It 'names the application in the message a technician reads' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $progress = @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.event -eq 'step.progress' })

            [string] $progress[0].message | Should -BeLike '*1 of 2*'
            [string] $progress[0].message | Should -BeLike '*Contoso agent*'
        }

        It 'reports a percentage the step bar can draw' {
            # ONE OF TWO IS NOT FIFTY PER CENT DONE, it is nought per cent done
            # and fifty per cent through the list. The bar is asked to show how
            # far through the LIST the step is, which is the only measure the
            # step has - msiexec does not tell it how far through a 687 MB patch
            # it is.
            #
            # SO EACH APPLICATION IS ANNOUNCED AND THEN BANKED, and the bar has
            # to do both. Announcing only, at (n-1)/total, was what shipped, and
            # measured on LT-7FJ45S2 run-20260829-190105 it produced exactly two
            # numbers for a two-application list: 0 and 50. The bar opened
            # empty, moved once, and the step finished at half - which on a
            # screen is indistinguishable from a step that never reported at
            # all, and is the defect this pair of records fixes.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $percent = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.event -eq 'step.progress' } | ForEach-Object { [int] $_.data.percent })

            $percent | Should -Be @(0, 50, 50, 100)
        }

        It 'reaches a hundred per cent when the last application is done' {
            # THE LAST THING A STEP SAYS ABOUT ITSELF SHOULD BE THAT IT
            # FINISHED - ApplyImage's rule, and the reason its meter is always
            # allowed through at a hundred. A step bar whose highest value is
            # 50 tells a technician the step stopped half way.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $percent = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.event -eq 'step.progress' } | ForEach-Object { [int] $_.data.percent })

            @($percent)[-1] | Should -Be 100
        }

        It 'credits an application that was already installed' {
            # A SKIP IS A POSITION IN THE LIST GOT PAST. A plan whose every
            # application is already present would otherwise leave the bar at
            # nought for the whole step and finish there, which reads as a step
            # that did nothing - and it did exactly what it was asked to.
            $context = & $script:newContext $script:process -ExtraFile @{
                'C:\Program Files\Contoso\Agent\agent.exe' = 'binary'
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Agent') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $percent = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.event -eq 'step.progress' } | ForEach-Object { [int] $_.data.percent })

            @($percent)[-1] | Should -Be 100
        }

        It 'credits an application installed on an earlier leg of this run' {
            # THE RESUMED LEG IS THE ONE A TECHNICIAN IS MOST LIKELY WATCHING,
            # because it is the one after the reboot. Restarting its bar from
            # nought would say the applications already installed had not been.
            $context = & $script:newContext $script:process -Variable @{
                _HDTApplicationInstalled = [string[]] @('Contoso-Agent')
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $percent = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.event -eq 'step.progress' } | ForEach-Object { [int] $_.data.percent })

            $percent | Should -Be @(50, 50, 100)
        }

        It 'credits an application that returned a reboot code' {
            # 3010 IS "INSTALLED, REBOOT REQUIRED", and the step already
            # checkpoints it as installed for that reason. The bar has to agree
            # with the checkpoint, or the leg after the reboot starts behind
            # where the leg before it ended.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Reboot') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'RebootRequested'

            $percent = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.event -eq 'step.progress' } | ForEach-Object { [int] $_.data.percent })

            $percent | Should -Be @(0, 100)
        }

        It 'drives the progress display while the installs are still running' {
            # END TO END, AND NOTHING HERE IS A SECOND CHANNEL (DESIGN 11.1):
            # the step logs, the display re-reads the log, and what lands on the
            # screen is what the log says.
            $display = New-HDTFakeProgressHost
            $context = & $script:newContext $script:process $null $null 'Info' $display
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($display.Operations | Where-Object { $_ -eq 'Update' }).Count | Should -BeGreaterThan 1
        }

        It 'installs the same applications it always did' {
            # The progress channel is an addition, not a change.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:process.Operations).Count | Should -Be 2
        }
    }

    # THE SUMMARY MUST AGREE WITH THE LINES ABOVE IT (CLAUDE.md, logging).
    #
    # Steps\013-Install-Applications-second-pass-idempot.log, run-20260830-221934,
    # verbatim:
    #
    #   skipped 1 of 2: Acrobat Acrobat Reader DC ..., installed on an earlier leg of this run.
    #   skipped 2 of 2: TightVNC Software Tightvnc ..., installed on an earlier leg of this run.
    #   installed 2 application(s), skipped 0 already present.
    #
    # Both were skipped and the summary claimed two installs and no skips. The
    # counter was $installed, which is SEEDED from _HDTApplicationInstalled at
    # the top of the step - so on a resumed leg it starts non-empty and counts
    # work an earlier leg did as work this one did.
    #
    # AND THERE ARE TWO KINDS OF SKIP, which the old summary could not express
    # with one number. "A detect rule found it already on the machine" and "this
    # run installed it before the reboot" are the difference between an
    # application that was there before HDT arrived and idempotency working, and
    # an admin reading whether the second pass did what it was supposed to needs
    # them apart.
    Context 'the summary, and whether it agrees with its own detail' {

        It 'counts nothing as installed when every application was done on an earlier leg' {
            $context = & $script:newContext $script:process -Variable @{
                _HDTApplicationInstalled = [string[]] @('Contoso-Agent', 'Contoso-Suite')
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            [string] $result.Status | Should -BeExactly 'Completed'
            @($script:process.Operations).Count | Should -Be 0

            [string] $result.Message | Should -BeLike 'installed 0 of 2 *'
        }

        It 'counts the two kinds of skip separately, and says which is which' {
            $context = & $script:newContext $script:process -Variable @{
                _HDTApplicationInstalled = [string[]] @('Contoso-Agent', 'Contoso-Suite')
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            [string] $result.Message | Should -BeLike '*0 that a detect rule found already present*'
            [string] $result.Message | Should -BeLike '*2 that an earlier leg of this run installed*'
        }

        It 'puts both kinds of skip on the step result, under names that cannot be confused' {
            $context = & $script:newContext $script:process -Variable @{
                _HDTApplicationInstalled = [string[]] @('Contoso-Agent', 'Contoso-Suite')
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($result.Data.installedThisLeg).Count | Should -Be 0
            @($result.Data.skippedAlreadyPresent).Count | Should -Be 0
            @($result.Data.skippedEarlierLeg) | Should -Be @('Contoso-Agent', 'Contoso-Suite')

            # AND THE CHECKPOINT IS UNCHANGED. installed stays what the RUN has
            # installed across every leg, because that is what
            # _HDTApplicationInstalled is and what the next leg resumes from.
            @($result.Data.installed) | Should -Be @('Contoso-Agent', 'Contoso-Suite')
            @($context.Variable['_HDTApplicationInstalled']) | Should -Be @('Contoso-Agent', 'Contoso-Suite')
        }

        It 'still counts a detect-rule skip as one, and names it as one' {
            # The other kind, on a leg that carries no progress at all: Agent's
            # detect rule finds its file, Suite declares no rule and installs.
            $context = & $script:newContext $script:process -ExtraFile @{
                'C:\Program Files\Contoso\Agent\agent.exe' = 'binary'
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            [string] $result.Message | Should -BeLike 'installed 1 of 2 *'
            [string] $result.Message | Should -BeLike '*1 that a detect rule found already present*'
            [string] $result.Message | Should -BeLike '*0 that an earlier leg of this run installed*'

            @($result.Data.skippedAlreadyPresent) | Should -Be @('Contoso-Agent')
            @($result.Data.skippedEarlierLeg).Count | Should -Be 0
            @($result.Data.installedThisLeg) | Should -Be @('Contoso-Suite')
        }

        It 'counts an ordinary first pass as installs and nothing else' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            [string] $result.Message | Should -BeLike 'installed 2 of 2 *'
            [string] $result.Message | Should -BeLike '*0 that a detect rule found already present*'
            [string] $result.Message | Should -BeLike '*0 that an earlier leg of this run installed*'
        }

        It 'writes the same summary to the log as it returns' {
            $context = & $script:newContext $script:process -Variable @{
                _HDTApplicationInstalled = [string[]] @('Contoso-Agent', 'Contoso-Suite')
            }
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $summary = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.component -eq 'InstallApplications' -and
                        ([string] $_.message).StartsWith('installed ') -and
                        ([string] $_.message) -like '*detect rule*' })

            @($summary).Count | Should -Be 1
            [string] $summary[0].message | Should -BeExactly ([string] $result.Message)
        }
    }

    Context 'what an admin can reconstruct from the log' {

        # THE TEST IS AN ADMIN AT A CUSTOMER SITE WITH THIS LOG AND NOTHING
        # ELSE. Measured on LT-7FJ45S2, run-20260829-190105: the whole step was
        # eight lines, every one of them Info, and the run around it had 36
        # Debug records. Three questions it could not answer, and all three are
        # the ordinary ones:
        #
        #   Acrobat returned 1603     no command line, no switches, no source
        #                             and no working directory, so it cannot be
        #                             reproduced by hand without going and
        #                             reading the task sequence on the share
        #   an app did not install    'skipped 1 already present' never says
        #                             what the rule looked for or what it found,
        #                             so a wrong detection rule and a machine
        #                             that genuinely had the app read the same
        #   Acrobat hung              the last line is 'installing 1 of 2'
        #
        # THE STEP ABOVE IT IN THE SAME RUN GETS THIS RIGHT: ApplyDrivers names
        # its source UNC and prints its own elapsed. This step named neither.
        #
        # AND THE SPLIT IS DELIBERATE. Info stays a short summary a technician
        # standing at the machine reads at a glance; the forensics go to Debug,
        # which is what a support case turns on and nobody watches. Promoting
        # them all would answer the complaint by making the step louder rather
        # than more useful.

        It 'records the source it is installing from at Info, the way MDT does' {
            # THE SINGLE MOST VALUABLE MISSING LINE. On a real deployment this
            # is the UNC the content provider resolved, and it is also the
            # working directory cmd.exe is given - the two are the same value
            # here, and both are what an admin needs to go and look at the
            # media by hand.
            #
            # INFO, AND THAT IS A REVERSAL OF WHAT THIS FILE ASSERTED FIRST.
            # ZTIApplications.wsf line 412 writes "Change directory: " with
            # LogTypeInfo, so an admin reading a DEFAULT MDT log sees it. HDT is
            # a homage to MDT; where a fresh idea and MDT disagree about what a
            # technician sees, MDT wins.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*change directory*' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].level | Should -BeExactly 'Info'
            [string] $record[0].message | Should -BeLike '*C:\Deploy\Applications\Corp-Baseline*'
        }

        It 'records the command line at Info, in a form an admin can paste into a prompt' {
            # THE ONE LINE THAT MAKES A FAILURE REPRODUCIBLE BY HAND, and an
            # admin must not have to re-run a deployment at a raised level to
            # get it. ZTIApplications.wsf line 441: "Run Command: " at
            # LogTypeInfo. The context this runs in is the DEFAULT Info one on
            # purpose - a Debug context would pass whatever the severity was.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*run command*' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].level | Should -BeExactly 'Info'
            [string] $record[0].message | Should -BeLike '*cmd.exe /c baseline.cmd*'
        }

        It 'redacts a secret in the command line' {
            # A VENDOR'S OWN SILENT INSTALL CARRIES CREDENTIALS, and this log
            # gets attached to a support case. The switch NAME survives, because
            # the admin still has to know the argument was passed; the value
            # does not.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Licensed') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            # PARSED, NOT GREPPED: the JSONL escapes the angle brackets, so a
            # raw-text match for <redacted> looks like a redaction that never
            # happened.
            $text = [string] $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl']
            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*run command*' })

            $text | Should -Not -BeLike '*hunter2*'
            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].message | Should -BeLike '*PASSWORD=<redacted>*'
        }

        It 'redacts a bare installer property, not only a switch' {
            # TIGHTVNC'S OWN DOCUMENTED SILENT INSTALL IS
            # 'msiexec /i ... SET_PASSWORD=1 VALUE_OF_PASSWORD=<secret>', and
            # it is on this lab's share. An MSI property carries no leading
            # slash, so a redactor that only recognises switches would have
            # written that password into the log of every machine that installs
            # it - which is exactly what the first version of this did.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Licensed') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*run command*' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].message | Should -BeLike '*VALUE_OF_PASSWORD=<redacted>*'
        }

        It 'leaves the switches that are not secrets alone' {
            # A REDACTOR THAT EATS THE COMMAND LINE IS WORSE THAN NO REDACTOR.
            # '/passive' begins with the letters of 'pass', and a word list that
            # matched it would swallow whatever followed - so the line an admin
            # is meant to paste into a prompt would be missing the argument that
            # mattered.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Licensed') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*run command*' })

            [string] $record[0].message | Should -BeLike '*/passive*'
            [string] $record[0].message | Should -BeLike '*/qn*'
            [string] $record[0].message | Should -BeLike '*licensed.exe*'
        }

        It 'leaves an empty detection field out of the summary' {
            # THE PROJECTION FILLS EVERY OPTIONAL KEY, so a file rule that
            # declares no version still carries one. Printing 'version=' with
            # nothing after it puts a field on the line that says only that the
            # renderer does not read what it prints.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Agent') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*detection*' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].message | Should -Not -BeLike '*version=)*'
            [string] $record[0].message | Should -Not -BeLike '*version=,*'
        }

        It 'says what detection looked for and that it found it' {
            $context = & $script:newContext $script:process -ExtraFile @{
                'C:\Program Files\Contoso\Agent\agent.exe' = 'binary'
            } -Level 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Agent') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*detection*' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].level | Should -BeExactly 'Debug'
            [string] $record[0].message | Should -BeLike '*file*'
            [string] $record[0].message | Should -BeLike '*agent.exe*'
            [string] $record[0].message | Should -BeLike '*found it*'
        }

        It 'says what detection looked for when it did NOT find it' {
            # THE HALF THAT WAS MISSING. A step that logs only its skips leaves
            # a wrong rule invisible: the application installs, the rule never
            # matched, and nothing in the log says the rule was even evaluated.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Agent') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*detection*' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].message | Should -BeLike '*agent.exe*'
            [string] $record[0].message | Should -BeLike '*did not find it*'
        }

        It 'says when an application declares no rule at all' {
            # DESIGN 8's documented behaviour, and the one an admin mistakes for
            # a broken rule: Corp-Baseline installs on every run because it asks
            # to, not because detection failed.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*no detect rule*' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].level | Should -BeExactly 'Debug'
        }

        It 'records the codes it was configured to accept and which one matched' {
            # rebootCodes IS CONFIGURED ON BOTH APPLICATIONS IN THE REAL RUN and
            # nothing recorded that it had even been considered. An admin
            # chasing an installer that returned 3010 and did not reboot has no
            # way to tell a missing rebootCodes entry from an engine defect.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*successCodes*' -and [string] $_.level -eq 'Debug' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].message | Should -BeLike '*rebootCodes*'
            [string] $record[0].message | Should -BeLike '*success code*'
        }

        It 'labels the exit code and says how long the install took' {
            # THE HOUSE STYLE, not a fourth one: ApplyDrivers ends 'in 48078
            # ms.' and ApplyImage 'in 131203 ms.', and the CommandLine step says
            # "'X' returned N". The bare '(0)' this line used to end with was an
            # unlabelled number.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like "installed 'Corporate baseline'*" })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].message | Should -BeLike '*exit code 0*'
            [string] $record[0].message | Should -Match 'in \d+ ms'
        }

        It 'keeps the forensics off the Info log' {
            # THE INFO SECTION STAYS PROPORTIONATE. A technician watching the
            # screen gets the plan, MDT's two lines per application, and a
            # total; the forensics - which rule was evaluated, which configured
            # code matched - are what a support case turns on a week later and
            # nobody watches, so they stay at Debug.
            #
            # WHAT IS NOT ON THIS LIST ANY MORE is 'run command' and 'change
            # directory'. They were here, and MDT writes both at LogTypeInfo:
            # the command line is the one line that makes a failure
            # reproducible by hand.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $text = [string] $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl']

            $text | Should -Not -BeLike '*detection*'
            $text | Should -Not -BeLike '*successCodes*'
        }

        It 'keeps the install plan line exactly as it was' {
            # THE ONE GENUINELY GOOD LINE IN THE STEP. MDT makes an admin
            # reconstruct the order from what ran; this says it up front, and
            # nothing here is allowed to reword it.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like 'install plan, in order:*' })

            $record.Count | Should -Be 1
            [string] $record[0].message | Should -BeExactly 'install plan, in order: Contoso-Agent, Contoso-Suite'
        }

        # AN ADMINISTRATOR ASKED FOR ONE APPLICATION AND GOT TWO. In
        # run-20260830-204613 HDTApplications named TightVNC alone; TightVNC's
        # app.yaml declares a dependency on Acrobat, so the plan installed
        # Acrobat first. The entire log record of that was Acrobat's id in the
        # plan line - no statement that nothing had requested it, and no name of
        # what had. These are the lines that answer it.

        It 'says which application pulled in one the selection never named' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like "'Contoso-Agent' is in the plan*" })

            @($record).Count | Should -Be 1
            [string] $record[0].message | Should -BeExactly ("'Contoso-Agent' is in the plan because " +
                "'Contoso-Suite' depends on it. Nothing asked for it by name; the chain that pulled " +
                "it in is Contoso-Suite -> Contoso-Agent.")
            [string] $record[0].level | Should -BeExactly 'Info'
        }

        It 'carries the reason as data, so a fleet of logs can be queried for it' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like "'Contoso-Agent' is in the plan*" })

            $record[0].data.requested | Should -BeFalse
            @($record[0].data.requiredBy) | Should -Be @('Contoso-Suite')
            @($record[0].data.path) | Should -Be @('Contoso-Suite', 'Contoso-Agent')
        }

        It 'names the step selection as the source when the step named a fixed list' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like "'Corp-Baseline' is in the plan*" })

            [string] $record[0].message | Should -BeExactly `
                "'Corp-Baseline' is in the plan because the step's selection asked for it."
        }

        It 'names HDTApplications when the variable is what supplied the selection' {
            # THE SOURCE THE REAL RUN HAD AND THE LOG DID NOT REPEAT. rules.yaml
            # already logged "HDTApplications = '...' (Rule)"; this is the line
            # that ties the plan back to it.
            $context = & $script:newContext $script:process -Variable @{ HDTApplications = 'Corp-Baseline' }
            $step = & $script:newStep 'Install applications' $null

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like "'Corp-Baseline' is in the plan*" })

            [string] $record[0].message | Should -BeExactly `
                "'Corp-Baseline' is in the plan because HDTApplications asked for it."
        }

        It 'names HDTMandatoryApplications for one the site does not let anybody opt out of' {
            $context = & $script:newContext $script:process -Variable @{
                HDTApplications          = 'Contoso-Agent'
                HDTMandatoryApplications = 'Corp-Baseline'
            }
            $step = & $script:newStep 'Install applications' $null

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like "'Corp-Baseline' is in the plan*" })

            [string] $record[0].message | Should -BeExactly `
                "'Corp-Baseline' is in the plan because HDTMandatoryApplications asked for it."
        }

        It 'says where each application sits and what it waited for' {
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like 'plan position *' })

            @($record).Count | Should -Be 2
            [string] $record[1].message | Should -BeExactly ("plan position 2 of 2: 'Contoso-Suite' was " +
                "ready once 'Contoso-Agent' had installed, which it depends on.")
        }

        It 'leaves the order the plan installs in exactly as it was' {
            # THE REASON LINES ARE COMMENTARY. If one of them could move an
            # install, the fix would be worse than the defect.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Suite') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            @($result.Data.planned) | Should -Be @('Contoso-Agent', 'Contoso-Suite')
            @($script:process.Operations)[0].Arguments[1] | Should -BeExactly '/c agent.msi /qn'
            @($script:process.Operations)[1].Arguments[1] | Should -BeExactly '/c suite.msi /qn'
        }

        It 'writes how far the resolution got when the plan cannot be ordered' {
            # THE RUN WHERE THE RESOLUTION MATTERS MOST is the one that failed,
            # and it used to be the one with no record of it at all. The trace
            # collections belong to the step, so a partial trace survives the
            # terminating error the resolver throws.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Ouroboros') })

            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like 'sort round 1 found nothing ready*' })

            @($record).Count | Should -Be 1
            @($record[0].data.stuck) | Should -Be @('Contoso-Ouroboros', 'Contoso-Serpent')
        }

    }

    Context 'what the installer itself said' {

        # THE OUTPUT WAS BEING CAPTURED AND THROWN AWAY. IProcessService.Start
        # has returned StandardOutput and StandardError since it was written -
        # the contract asserts both properties on both implementations - and
        # this step read ExitCode and dropped the rest. So an installer that
        # failed with 1603 AND PRINTED THE REASON left a log with the number and
        # nothing else.
        #
        # MDT'S SHAPE. StandardConsoleProcessing (ZTIUtility.vbs 2255-2299)
        # writes one entry per line, "  Console > " for stdout and
        # "  Console # " for stderr - separate markers, not a merged stream, so
        # a reader can tell which pipe a line came out of.

        It 'writes the output the installer printed into the log' {
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Chatty') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*console >*' })

            @($record).Count | Should -Be 3
            [string] $record[0].message | Should -BeLike '*unpacking*'
            [string] $record[2].message | Should -BeLike '*done*'
        }

        It 'marks a stderr line apart from a stdout line, the way MDT does' {
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Chatty') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*console #*' })

            @($record).Count | Should -Be 1
            [string] $record[0].message | Should -BeLike '*a note on stderr*'
        }

        It 'keeps the output of a successful install off the Info log' {
            # OUTPUT ON SUCCESS IS NOISE, and this log is written to the share
            # over SMB and read in CMTrace. A chatty installer that succeeded
            # must not cost a technician a screen of scrollback.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Chatty') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $text = [string] $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl']

            $text | Should -Not -BeLike '*unpacking*'
            $text | Should -Not -BeLike '*a note on stderr*'
        }

        It 'names how much the installer wrote even when it keeps the lines back' {
            # OTHERWISE THE CAPTURE IS INVISIBLE. A technician who cannot see
            # that output exists has no reason to go and raise the level for it.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Chatty') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*line(s) to stdout*' })

            @($record).Count | Should -Be 1
            [string] $record[0].level | Should -BeExactly 'Info'
            [string] $record[0].message | Should -BeLike '*3 line(s) to stdout*'
            [string] $record[0].message | Should -BeLike '*1 to stderr*'
        }

        It 'says nothing at all when the installer printed nothing' {
            # A SILENT MSI IS THE COMMON CASE. A step that wrote 'console
            # output: 0 lines' after every application would be paying for the
            # feature on every deployment that does not need it.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Corp-Baseline') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $text = [string] $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl']

            $text | Should -Not -BeLike '*console >*'
            $text | Should -Not -BeLike '*line(s) to stdout*'
        }

        It 'raises the output of a failed install so it is readable at Info' {
            # THE WHOLE REASON THIS EXISTS. Acrobat returns 1603 and prints why;
            # an admin must not have to re-run the deployment at a raised level
            # to read it. The context here is the DEFAULT Info one.
            $context = & $script:newContext $script:process
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Broken') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $out = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*console >*' })
            $err = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*console #*' })

            @($out).Count | Should -Be 2
            [string] $out[1].level | Should -BeExactly 'Warning'
            [string] $out[1].message | Should -BeLike '*another installation is in progress*'

            @($err).Count | Should -Be 1
            [string] $err[0].level | Should -BeExactly 'Error'
            [string] $err[0].message | Should -BeLike '*MSI (s) returned 1603*'
        }

        It 'redacts a credential the installer echoed back' {
            # AN INSTALLER CAN PRINT ITS OWN ARGUMENTS, so redacting the command
            # line and not the output would leak the same secret one line later.
            # It goes through the SAME redactor - a second one would drift.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Echo') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $text = [string] $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl']
            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*console >*' })

            $text | Should -Not -BeLike '*hunter2*'
            @($record).Count | Should -Be 1
            [string] $record[0].message | Should -BeLike '*VALUE_OF_PASSWORD=*redacted*'
        }

        It 'caps a chatty installer and says how many lines it dropped' {
            # NEVER SILENTLY. A truncation nobody is told about reads as an
            # installer that stopped talking, which is a different fault
            # entirely.
            $context = & $script:newContext $script:process $null $null 'Debug'
            $step = & $script:newStep 'Install applications' ([ordered] @{ selection = @('Contoso-Loud') })

            $null = Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            $line = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*console >*' })
            $marker = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*not shown*' })

            @($line).Count | Should -Be 40
            @($marker).Count | Should -Be 1
            [string] $marker[0].message | Should -BeLike '*300 line(s)*'
            [string] $marker[0].message | Should -BeLike '*first 260*'

            # THE TAIL IS WHAT IS KEPT, because the reason an installer gave up
            # is the last thing it says, not the first.
            [string] $line[39].message | Should -BeLike '*progress line 300*'
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

            # skippedAlreadyPresent, not 'skipped': the two kinds of skip are
            # counted and named apart, and a detect-rule skip is this one.
            @($result.Data['skippedAlreadyPresent']) | Should -Contain 'Contoso-Agent'
            @($result.Data['skippedEarlierLeg']).Count | Should -Be 0
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
