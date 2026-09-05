function Invoke-HDTWindowsUpdateStep {
    <#
        .SYNOPSIS
            Patches the running operating system online, in as many passes as it
            takes.

        .DESCRIPTION
            DESIGN 10.1, wrapping the Windows Update Agent behind
            IUpdateSessionService so the whole step runs under Pester with no
            agent, no server and no update installed.

              - name: Windows Update
                type: WindowsUpdate
                server: "%HDTWSUSServer%"
                categories: [SecurityUpdates, CriticalUpdates, UpdateRollups]
                exclude: ["*Preview*", "KB5001234"]
                maxPasses: 3
                continueOnError: true

            MULTIPLE PASSES ARE THE POINT, AND A SINGLE-PASS STEP IS THE CLASSIC
            MISTAKE. Installing one update supersedes or reveals another - a
            servicing stack update makes the cumulative one applicable, a
            cumulative update reveals the .NET one behind it - so the step
            searches, installs, restarts if it has to, and SEARCHES AGAIN, until
            a pass finds nothing applicable or maxPasses is reached. A step that
            searched once would leave machines half-patched and report success,
            which is what makes it the mistake that survives: nothing about the
            deployment looks wrong. PSD's own PSDWindowsUpdate.ps1 is
            single-pass; it was read for the COM mechanism and not for the shape.

            IT IS FULL-OS ONLY, BY DEFINITION. The Windows Update Agent COM
            server is not present in a WinPE image at all, so
            Import-HDTSequenceDocument refuses this type in a WinPE group at
            authoring time (Get-HDTFullOsOnlyStepType). Offline .msu injection
            while WinPE is running is a different step: ApplyUpdates, DESIGN 7.5.

            THE PASS COUNTER IS CHECKPOINTED, NOT HELD IN A LOCAL. Installing
            updates asks for a restart, and a restart ends this leg. Two
            variables survive it in state.json:

              _HDTWindowsUpdatePass       passes COMPLETED by this run
              _HDTWindowsUpdateInstalled  the KB numbers put on, across every leg

            Without the first, the step restarts at pass one on every leg and
            maxPasses bounds nothing at all - a machine could loop through the
            reboot ceremony indefinitely while every individual leg looked
            correct. maxPasses bounds the STEP, across legs, and that is what
            the checkpoint buys. Invoke-HDTInstallApplicationsStep checkpoints
            _HDTApplicationInstalled for the same reason and in the same way.

            AND -Reenter IS NOT OPTIONAL ON THE REBOOT. The loop records a plain
            RebootRequested step as Completed and advances stepIndex past it -
            right for a Restart step, and wrong here, because every remaining
            pass would be silently skipped while the run reported success.
            New-HDTStepResult -Reenter makes the loop record the step Pending
            instead, so the next leg runs it again and it resumes from the
            checkpoint.

            IT ASKS THE MACHINE AS WELL AS THE INSTALL RESULT. An install result
            says "THIS BATCH asked for a restart"; GetRebootRequired() reads
            ISystemInformation and says "there is a restart pending from
            anything at all". A servicing stack update that goes in first
            frequently leaves the second kind without setting the first, and the
            next search then returns stale results - so both are checked, and
            either one ends the leg.

            A FAILED UPDATE DOES NOT STOP THE PASS. It is recorded, with its
            result code and its HResult, and the step goes on to the next one.
            The step fails only when EVERY update in a pass failed, because at
            that point another pass would do exactly the same thing.
            continueOnError then decides whether that failure scraps the build,
            and DESIGN 10.1 recommends true: "Windows Update is the least
            predictable thing in a sequence, and a failed optional update should
            not scrap an otherwise good build."

            REACHING maxPasses WITH WORK OUTSTANDING IS A WARNING, NOT A
            FAILURE. The machine is more patched than it was. It is logged
            loudly, at Info and naming what is still applicable, so an
            administrator sees the bound was hit here rather than discovering it
            from a patch report a month later.

            WHAT IT REPORTS, AND THE ONE THING IT CANNOT. The step resolves the
            whole ordered list before it installs anything, so it writes a
            step.progress frame naming which update of how many, in which pass,
            before each install. It cannot report DURING an install, and that is
            a fact about the agent rather than an omission: the only WUA form
            that carries a percentage is IUpdateInstaller.BeginInstall with an
            IInstallationCompletedCallback, a COM interface PowerShell cannot
            implement. Measured on this machine, BeginInstall($null, $null,
            $null) fails with "Object reference not set to an instance of an
            object" BEFORE it looks at the update collection, while Install() on
            the same empty collection reaches the collection and reports "Value
            does not fall within the expected range". So Install() is the only
            call available, it blocks, and it says nothing - which is why the
            frame written before it is the last thing the screen gets until it
            returns, and why StepProgress.Contract classifies this step the way
            it classifies InstallRoles.

            THE LOG EVENT IS update.apply, ONE RECORD PER UPDATE. Read its
            comment in Write-HDTLog.ps1: twenty outcomes an administrator has to
            be able to filter, and a single summary line at the end of the step
            answers none of them. native.exec is for a process a step shelled out
            to, and this step shells out to nothing - using it would put a COM
            call into the stream a technician filters for command lines.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry an
            UpdateSession service, which Start-HDTResume builds for the full-OS
            leg.

        .OUTPUTS
            A New-HDTStepResult. Data carries pass, maxPasses, server, searched,
            applicable, installed, installedThisPass, skippedExcluded,
            skippedCategory, failed, rebootRequired and elapsedSecond.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -UpdateSession (New-HDTUpdateSessionService)
            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\STD-CLIENT\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'WindowsUpdate' })[0]

            Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            One step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context
            $result.Data.installed

            The KB numbers this run has installed, across every leg - not only
            the ones this leg put on.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $component = 'WindowsUpdate'
    $passVariable = '_HDTWindowsUpdatePass'
    $installedVariable = '_HDTWindowsUpdateInstalled'
    $searchCriteria = 'IsInstalled = 0'

    $fail = {
        param([string] $Message, [System.Collections.IDictionary] $Data)

        $payload = $Data
        if ($null -eq $payload) { $payload = [ordered] @{} }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component $component -Data $payload

        return (New-HDTStepResult -Status Failed -Message $Message -Data $payload)
    }

    $clock = $Context.Service.Clock
    $startedUtc = $clock.GetUtcNow()

    # -- what the step was told -----------------------------------------------

    $property = $Step.Property

    # A LIST EXPANDS ELEMENT BY ELEMENT, and the flat form expands too. Both
    # shapes are legal YAML and both are written by real sequences; a list
    # handled only in its flat form makes exclude: ['%HDTExcludePattern%'] search
    # for an update whose title is a percent sign. InstallRoles carries the same
    # comment over `features` and InstallApplications over `selection`, and both
    # of them got it wrong first.
    $readList = {
        param([string] $Name)

        if ($null -eq $property -or -not $property.Contains($Name)) { return [string[]] @() }

        $raw = $property[$Name]

        if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
            return [string[]] @(@($raw) |
                    ForEach-Object { ([string] (Expand-HDTVariableToken -Value ([string] $_) -Scope $Context.Variable)).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        $written = [string] (Expand-HDTVariableToken -Value ([string] $raw) -Scope $Context.Variable)

        return [string[]] @(@($written -split '[,;\r\n]') | ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $category = [string[]] @(& $readList 'categories')
    $exclude = [string[]] @(& $readList 'exclude')

    try {
        $maxPasses = [int] (Get-HDTStepProperty -Step $Step -Name 'maxPasses' -Default 3 -Context $Context -Expand -As Int)
    } catch {
        return (& $fail ([string] $_.Exception.Message) ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    # REFUSED BEFORE ANYTHING IS SEARCHED FOR. maxPasses 0 is a sequence that
    # says "patch this machine" and means "do nothing", and a step that quietly
    # did nothing would be indistinguishable from a machine that was already up
    # to date.
    if ($maxPasses -lt 1) {
        return (& $fail ("step '{0}': maxPasses is {1}, and a WindowsUpdate step runs at least one pass. Remove the key to take the default of 3, or name a number of 1 or more." -f
                $Step.Name, $maxPasses) ([ordered] @{ errorId = 'HDTConfigurationError'; maxPasses = $maxPasses }))
    }

    try {
        $wua = $Context.Service.GetRequired('UpdateSession', 'WindowsUpdate')
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null)
    }

    # -- where the client is pointed ------------------------------------------

    $server = ''
    if ($null -ne $property -and $property.Contains('server')) {
        try {
            $server = ([string] (Get-HDTStepProperty -Step $Step -Name 'server' -Context $Context -Expand -As String)).Trim()
        } catch {
            return (& $fail ([string] $_.Exception.Message) ([ordered] @{ errorId = 'HDTConfigurationError' }))
        }
    }

    # AN UNRESOLVED TOKEN IS NOT A URL, AND POINTING THE AGENT AT ONE IS WORSE
    # THAN REFUSING. Expand-HDTVariableToken leaves a token nothing supplied
    # LITERAL, deliberately (02-03), so a rule that never set HDTWSUSServer
    # arrives here as the text '%HDTWSUSServer%' - and writing that into the
    # WUServer policy value takes the machine off Windows Update without putting
    # it onto anything.
    if ($server -like '*%*%*') {
        return (& $fail ("step '{0}': server is '{1}', which is a variable token nothing resolved. Set the variable in rules.yaml or the sequence, or remove the server key to use the machine's own policy." -f
                $Step.Name, $server) ([ordered] @{ errorId = 'HDTConfigurationError'; server = $server }))
    }

    if (-not [string]::IsNullOrWhiteSpace($server)) {
        try {
            $wua.SetServer($server)
        } catch {
            return (& $fail ("the update client could not be pointed at '{0}': {1}" -f
                    $server, [string] $_.Exception.Message) ([ordered] @{ server = $server }))
        }

        Write-HDTLog -Context $Context.Log -Component $component `
            -Message ("the update client is pointed at the server this step names: {0} (from the step's server property)." -f $server) `
            -Data ([ordered] @{ server = $server; source = 'step property server' })
    } else {
        # DESIGN 10.1: omit server for Windows Update, or for whatever the
        # machine's policy already names. Writing a server nobody asked for
        # would take a domain-joined machine off its own WSUS for good.
        Write-HDTLog -Context $Context.Log -Component $component `
            -Message 'the step names no server, so the machine keeps whatever Windows Update or its own policy already points at. Nothing was written to the WindowsUpdate policy key.' `
            -Data ([ordered] @{ server = ''; source = 'machine policy' })
    }

    # -- what earlier legs of this run already did ----------------------------

    $pass = 0
    if ($Context.Variable.Contains($passVariable)) {
        $pass = [int] $Context.Variable[$passVariable]
    }

    $installed = New-Object -TypeName System.Collections.ArrayList
    if ($Context.Variable.Contains($installedVariable)) {
        foreach ($current in @($Context.Variable[$installedVariable])) {
            if (-not [string]::IsNullOrWhiteSpace([string] $current)) { [void] $installed.Add([string] $current) }
        }
    }

    if ($pass -gt 0) {
        Write-HDTLog -Context $Context.Log -Component $component `
            -Message ("resuming after a restart: {0} pass(es) of at most {1} are already done and {2} update(s) are already on this machine ({3})." -f
                $pass, $maxPasses, @($installed).Count, $(if (@($installed).Count -gt 0) { @($installed) -join ', ' } else { 'none' })) `
            -Data ([ordered] @{ pass = $pass; maxPasses = $maxPasses; installed = [string[]] @($installed) })
    }

    $checkpoint = {
        # The live variable dictionary is copied into the state document on every
        # save, so writing progress here is what makes it survive the reboot.
        $Context.Variable[$passVariable] = $pass
        $Context.Variable[$installedVariable] = [string[]] @($installed)
    }

    $searched = 0
    $applicableCount = 0
    $installedThisPass = New-Object -TypeName System.Collections.ArrayList
    $skippedExcluded = New-Object -TypeName System.Collections.ArrayList
    $skippedCategory = New-Object -TypeName System.Collections.ArrayList
    $failedUpdate = New-Object -TypeName System.Collections.ArrayList
    $outstanding = [string[]] @()
    $rebootRequired = $false

    $newData = {
        return [ordered] @{
            pass              = $pass
            maxPasses         = $maxPasses
            server            = $server
            searched          = $searched
            applicable        = $applicableCount
            installed         = [string[]] @($installed)
            installedThisPass = [string[]] @($installedThisPass)
            skippedExcluded   = [string[]] @($skippedExcluded)
            skippedCategory   = [string[]] @($skippedCategory)
            failed            = [object[]] @($failedUpdate)
            rebootRequired    = $rebootRequired
            elapsedSecond     = [long] (($clock.GetUtcNow()) - $startedUtc).TotalSeconds
        }
    }

    # -- the loop -------------------------------------------------------------

    while ($pass -lt $maxPasses) {
        $pass++
        $passStartedUtc = $clock.GetUtcNow()
        $installedThisPass.Clear()

        try {
            $found = @($wua.SearchUpdate($searchCriteria))
        } catch {
            return (& $fail ("pass {0}: the search for updates ('{1}') failed and the step cannot decide what to install: {2}" -f
                    $pass, $searchCriteria, [string] $_.Exception.Message) (& $newData))
        }

        $searched = @($found).Count

        $decided = @(Select-HDTApplicableUpdate -Update ([object[]] @($found)) -Category $category -Exclude $exclude)
        $applicable = @($decided | Where-Object { $_.Applicable })
        $applicableCount = @($applicable).Count

        # EVERY ROW, KEPT OR DROPPED, WITH THE REASON. "0 updates applicable" is
        # not something an administrator can act on; naming the pattern that
        # excluded an update, or the categories list that left it out of scope,
        # is the difference between a log they can use and one they have to ask
        # about.
        foreach ($row in $decided) {
            $kbOf = [string[]] @(Get-HDTUpdateKbNumber -Update $row.Update)
            $kbText = 'no KB number'
            if (@($kbOf).Count -gt 0) { $kbText = @($kbOf) -join ', ' }

            $verdict = 'will be installed'
            if (-not $row.Applicable) {
                $verdict = 'will be skipped'

                if ([string] $row.Reason -like 'excluded by*') {
                    [void] $skippedExcluded.Add($kbText)
                } else {
                    [void] $skippedCategory.Add($kbText)
                }
            }

            Write-HDTLog -Context $Context.Log -Component $component `
                -Message ("pass {0}: {1} - '{2}' [{3}] {4}: {5}." -f
                    $pass, $kbText, [string] $row.Update.Title,
                    (@($row.Update.Category) -join ', '), $verdict, [string] $row.Reason) `
                -Data ([ordered] @{
                    pass           = $pass
                    kb             = $kbText
                    title          = [string] $row.Update.Title
                    classification = [string[]] @($row.Update.Category)
                    applicable     = [bool] $row.Applicable
                    reason         = [string] $row.Reason
                    sizeByte       = [long] $row.Update.SizeByte
                })
        }

        # THE PLAN, WRITTEN BEFORE ANYTHING IS INSTALLED. A log that only says
        # what happened cannot be compared with what was meant to happen.
        Write-HDTLog -Context $Context.Log -Component $component `
            -Message ("pass {0} of at most {1}: the search returned {2} update(s); {3} applicable, {4} excluded by a pattern, {5} outside the categories this step names." -f
                $pass, $maxPasses, $searched, $applicableCount,
                @($decided | Where-Object { [string] $_.Reason -like 'excluded by*' }).Count,
                @($decided | Where-Object { [string] $_.Reason -eq 'no category matched' }).Count) `
            -Data ([ordered] @{
                pass       = $pass
                maxPasses  = $maxPasses
                searched   = $searched
                applicable = $applicableCount
                categories = $category
                exclude    = $exclude
            })

        if ($applicableCount -eq 0) {
            & $checkpoint

            $message = ("pass {0} found nothing applicable, so this machine is as patched as this step can make it. {1} update(s) installed by this run in all{2}." -f
                $pass, @($installed).Count,
                $(if (@($installed).Count -gt 0) { ': ' + (@($installed) -join ', ') } else { '' }))

            $data = & $newData

            Write-HDTLog -Context $Context.Log -Component $component -Message $message -Data $data

            return (New-HDTStepResult -Status Completed -Message $message -Data $data)
        }

        $total = $applicableCount
        $position = 0
        $passFailed = 0

        # WHAT THIS PASS WAS WORKING THROUGH, kept for the maxPasses line below
        # so it can name them without searching the server a further time.
        $outstanding = [string[]] @(@($applicable) | ForEach-Object {
                $kb = [string[]] @(Get-HDTUpdateKbNumber -Update $_.Update)
                if (@($kb).Count -gt 0) { @($kb) -join ', ' } else { [string] $_.Update.Title }
            })

        foreach ($row in $applicable) {
            $update = $row.Update
            $position++

            $kbOf = [string[]] @(Get-HDTUpdateKbNumber -Update $update)
            $kbText = 'no KB number'
            if (@($kbOf).Count -gt 0) { $kbText = @($kbOf) -join ', ' }

            $classification = @($update.Category) -join ', '

            # THE LAST THING THE SCREEN GETS UNTIL THE INSTALL RETURNS, and one
            # update can be twenty minutes. InstallUpdate is a single blocking
            # COM call that reports nothing while it runs - see the DESCRIPTION
            # for the measurement behind that - so this frame has to say WHICH
            # update as well as how far through, or a technician in front of a
            # motionless bar cannot tell a long update from a hung one.
            $percent = [int] [System.Math]::Floor((($position - 1) * 100) / $total)

            Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component $component `
                -Message ("pass {0}: installing {1} of {2}: {3} - {4}" -f
                    $pass, $position, $total, $kbText, [string] $update.Title) `
                -Data ([ordered] @{
                    percent = $percent
                    pass    = $pass
                    update  = $kbText
                    title   = [string] $update.Title
                    done    = $position - 1
                    total   = $total
                })

            # AND THEN TELL THE WINDOW TO LOOK. Update-HDTProgressDisplay
            # re-reads the log and hands the host a new snapshot; without this
            # the record above is written and never drawn. It is documented
            # never to fail a deployment.
            Update-HDTProgressDisplay -Context $Context

            $updateStartedUtc = $clock.GetUtcNow()

            try {
                # THE EULA FIRST, BECAUSE AN UNACCEPTED ONE FAILS THE INSTALL
                # RATHER THAN PROMPTING. There is nobody at the machine to
                # accept it and no window for it to appear in.
                $wua.AcceptEula([string] $update.UpdateId)

                if (-not [bool] $update.IsDownloaded) {
                    $download = $wua.DownloadUpdate([string[]] @([string] $update.UpdateId))

                    Write-HDTLog -Context $Context.Log -Component $component `
                        -Message ("pass {0}: downloaded {1} ({2:N0} byte(s)); the agent reported result code {3} ({4})." -f
                            $pass, $kbText, [long] $update.SizeByte, [int] $download.ResultCode,
                            (Get-HDTUpdateResultName -ResultCode ([int] $download.ResultCode))) `
                        -Data ([ordered] @{
                            pass       = $pass
                            kb         = $kbText
                            resultCode = [int] $download.ResultCode
                            hresult    = [int] $download.HResult
                            sizeByte   = [long] $update.SizeByte
                        })
                } else {
                    # Fifteen minutes somebody does not have to wait through
                    # twice, and the log has to say the step CHOSE that rather
                    # than forgetting to download.
                    Write-HDTLog -Context $Context.Log -Severity Debug -Component $component `
                        -Message ("pass {0}: {1} is already in the agent's download cache, so it was not downloaded again." -f $pass, $kbText) `
                        -Data ([ordered] @{ pass = $pass; kb = $kbText })
                }

                $install = $wua.InstallUpdate([string[]] @([string] $update.UpdateId))
            } catch {
                $passFailed++

                [void] $failedUpdate.Add([pscustomobject] @{
                        kb         = $kbText
                        title      = [string] $update.Title
                        resultCode = 4
                        hresult    = 0
                        message    = [string] $_.Exception.Message
                    })

                Write-HDTLog -Context $Context.Log -Severity Error -Event 'update.apply' -Component $component `
                    -Message ("pass {0}: {1} of {2}: {3} - '{4}' was refused by the Windows Update Agent: {5}" -f
                        $pass, $position, $total, $kbText, [string] $update.Title, [string] $_.Exception.Message) `
                    -Data ([ordered] @{
                        pass           = $pass
                        kb             = $kbText
                        title          = [string] $update.Title
                        classification = $classification
                        outcome        = 'failed'
                        resultCode     = 4
                        hresult        = 0
                        durationMs     = [long] (($clock.GetUtcNow()) - $updateStartedUtc).TotalMilliseconds
                        sizeByte       = [long] $update.SizeByte
                        message        = [string] $_.Exception.Message
                    })

                continue
            }

            $durationMs = [long] (($clock.GetUtcNow()) - $updateStartedUtc).TotalMilliseconds
            $resultName = Get-HDTUpdateResultName -ResultCode ([int] $install.ResultCode)

            if ([bool] $install.Success) {
                # DEDUPED, BECAUSE A PASS THAT REACHED maxPasses MAY HAVE SEEN
                # THE SAME UPDATE TWICE. An installed list naming one KB twice
                # reads as two updates in every report that renders it.
                if (-not (@($installed) -contains $kbText)) { [void] $installed.Add($kbText) }
                [void] $installedThisPass.Add($kbText)

                if ([bool] $install.RebootRequired) { $rebootRequired = $true }

                Write-HDTLog -Context $Context.Log -Event 'update.apply' -Component $component `
                    -Message ("pass {0}: {1} of {2}: installed {3} - '{4}' [{5}] in {6} ms; result code {7} ({8}){9}." -f
                        $pass, $position, $total, $kbText, [string] $update.Title, $classification,
                        $durationMs, [int] $install.ResultCode, $resultName,
                        $(if ([bool] $install.RebootRequired) { ', and it asked for a restart' } else { '' })) `
                    -Data ([ordered] @{
                        pass           = $pass
                        kb             = $kbText
                        title          = [string] $update.Title
                        classification = $classification
                        outcome        = 'installed'
                        resultCode     = [int] $install.ResultCode
                        resultName     = $resultName
                        hresult        = [int] $install.HResult
                        rebootRequired = [bool] $install.RebootRequired
                        durationMs     = $durationMs
                        sizeByte       = [long] $update.SizeByte
                    })

                & $checkpoint

                continue
            }

            $passFailed++

            [void] $failedUpdate.Add([pscustomobject] @{
                    kb         = $kbText
                    title      = [string] $update.Title
                    resultCode = [int] $install.ResultCode
                    hresult    = [int] $install.HResult
                    message    = $resultName
                })

            # THE HRESULT, NOT ONLY THAT IT FAILED. 0x80240017 and 0x800F0922
            # are two entirely different problems and an administrator looks
            # both of them up by number.
            Write-HDTLog -Context $Context.Log -Severity Error -Event 'update.apply' -Component $component `
                -Message ("pass {0}: {1} of {2}: {3} - '{4}' [{5}] FAILED after {6} ms; result code {7} ({8}), HResult 0x{9:X8}." -f
                    $pass, $position, $total, $kbText, [string] $update.Title, $classification,
                    $durationMs, [int] $install.ResultCode, $resultName, [int] $install.HResult) `
                -Data ([ordered] @{
                    pass           = $pass
                    kb             = $kbText
                    title          = [string] $update.Title
                    classification = $classification
                    outcome        = 'failed'
                    resultCode     = [int] $install.ResultCode
                    resultName     = $resultName
                    hresult        = [int] $install.HResult
                    durationMs     = $durationMs
                    sizeByte       = [long] $update.SizeByte
                })
        }

        & $checkpoint

        $passSecond = [long] (($clock.GetUtcNow()) - $passStartedUtc).TotalSeconds

        Write-HDTLog -Context $Context.Log -Component $component `
            -Message ("pass {0} finished in {1} second(s): {2} installed, {3} failed." -f
                $pass, $passSecond, @($installedThisPass).Count, $passFailed) `
            -Data (& $newData)

        # EVERY UPDATE IN THE PASS FAILED, SO ANOTHER PASS WOULD DO THE SAME
        # THING. Anything less than that is recorded and walked past: one
        # optional update refusing itself is not a reason to abandon a build.
        if (@($installedThisPass).Count -eq 0 -and $passFailed -gt 0) {
            return (& $fail ("pass {0}: every one of the {1} applicable update(s) failed to install, so a further pass would do the same. The first failure was {2} ({3})." -f
                    $pass, $total, [string] @($failedUpdate)[-1].kb, [string] @($failedUpdate)[-1].message) (& $newData))
        }

        # BOTH QUESTIONS, AND EITHER ONE ENDS THE LEG. The install result speaks
        # for its own batch; the machine speaks for everything, including the
        # servicing stack update that went in first and the restart that was
        # pending before HDT ever ran.
        $machineReboot = $false
        try {
            $machineReboot = [bool] $wua.GetRebootRequired()
        } catch {
            Write-HDTLog -Context $Context.Log -Severity Warning -Component $component `
                -Message ("pass {0}: the agent could not be asked whether a restart is pending, so only the install results decide: {1}" -f
                    $pass, [string] $_.Exception.Message) -Data ([ordered] @{ pass = $pass })
        }

        if ($rebootRequired -or $machineReboot) {
            $rebootRequired = $true
            & $checkpoint

            $data = & $newData

            $message = ("pass {0} of at most {1} installed {2} update(s) and the machine must restart before the next pass can see what they revealed. {3}" -f
                $pass, $maxPasses, @($installedThisPass).Count,
                $(if ($machineReboot -and -not @($installedThisPass).Count) { 'The machine reported a restart pending of its own.' } else { 'The step resumes at the next pass after the restart.' }))

            Write-HDTLog -Context $Context.Log -Component $component `
                -Message $message -Data $data

            return (New-HDTStepResult -Status RebootRequested -Reenter -Message $message -Data $data)
        }
    }

    # -- the bound was reached ------------------------------------------------
    #
    # A WARNING AND NOT A FAILURE: the machine is more patched than it was, and
    # a step that failed here would scrap a build over a bound the author chose.
    # Logged at Info, naming what the last pass was still working through, so an
    # administrator sees it here rather than in a patch report next month.
    #
    # AND IT DOES NOT SEARCH AGAIN TO FIND OUT. A fresh search after the last
    # install would be a further pass in everything but name - minutes against a
    # WSUS server, on a step that has just been told to stop - and its answer
    # would still be provisional, because installing what it found could reveal
    # more again. What IS known for certain is what the last pass found
    # applicable, so that is what the line reports, and it says which pass it is
    # talking about.

    & $checkpoint

    $data = & $newData

    $message = ("reached maxPasses ({0}) while pass {0} still had {1} applicable update(s){2}, so the step stopped rather than looping. {3} update(s) were installed by this run in all{4}. The machine is patched further than it was; the rest need another run or a higher maxPasses." -f
        $maxPasses, @($outstanding).Count,
        $(if (@($outstanding).Count -gt 0) { ': ' + (@($outstanding) -join ', ') } else { '' }),
        @($installed).Count,
        $(if (@($installed).Count -gt 0) { ': ' + (@($installed) -join ', ') } else { '' }))

    Write-HDTLog -Context $Context.Log -Component $component -Message $message -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
