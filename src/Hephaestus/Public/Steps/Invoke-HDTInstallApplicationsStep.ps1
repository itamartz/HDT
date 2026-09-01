function Invoke-HDTInstallApplicationsStep {
    <#
        .SYNOPSIS
            Installs the selected applications, in dependency order, surviving the
            reboots they ask for.

        .DESCRIPTION
            Installs the applications a deployment selected, on the catalog,
            the ordering and the detection of 07-01.

              - name: Install Applications
                type: InstallApplications
                selection: "%HDTApplications%"

            or a fixed list:

                selection: [7Zip-24.09, Contoso-Suite]

            and with neither, the HDTApplications variable is read directly -
            which is what a wizard answer or a rule sets. DESIGN 8: both forms
            "resolve to the same ordered install plan", because both are handed
            to the same Resolve-HDTApplicationOrder.

            THE PLAN IS LOGGED BEFORE ANYTHING RUNS. A technician reading the log
            of a build that went wrong needs to know what the step INTENDED, not
            only what it got through - and the plan is what shows the dependency
            closure pulled in an application the selection never named.

            SELECTING AN APPLICATION SELECTS WHAT IT NEEDS. The plan is the
            selection plus its transitive dependencies, ordered dependencies
            first, deterministically (Resolve-HDTApplicationOrder).

            DETECTION SKIPS, IT DOES NOT FAIL. An application whose rule reports
            it already installed is skipped and recorded as skipped. An
            application that declares no rule installs every time - DESIGN 8's
            documented behaviour, and the author's stated choice rather than an
            engine limitation.

            A 3010 REBOOTS AND COMES BACK. The step returns
            RebootRequested -Reenter and checkpoints what it has installed into
            _HDTApplicationInstalled, which the state document persists across
            legs. The next leg runs the step again and resumes at the NEXT
            application. THE TWO WAYS THIS FEATURE IS USUALLY GOT WRONG:

              no Reenter    the loop advances past the step and every application
                            after the one that rebooted is silently skipped,
                            while the run reports success
              no progress   the step restarts the list on every leg, reinstalling
                            everything ahead of the reboot each time

            The application that asked for the restart is checkpointed as
            INSTALLED, because 3010 means "installed, reboot required" - re-running
            it on the next leg would install it twice.

            AN INSTALL COMMAND IS A SHELL LINE, run through %ComSpec% /c exactly
            as the CommandLine step's command: is. Quoting, chaining and
            redirection are routine in what a vendor documents as their silent
            install. The comspec comes from the injected IEnvironmentProvider,
            never from $env:, and the working directory is the application's
            source folder so a relative installer path resolves.

            THAT FOLDER HAS TO BE ONE cmd.exe CAN STAND IN, which is why the Smb
            provider maps the share to a drive letter (DESIGN 6). Handed a UNC
            working directory, cmd.exe prints "UNC paths are not supported",
            moves itself to %SystemRoot%, and the vendor's own
            'msiexec /i setup.msi' runs in C:\Windows against a file that is not
            there. SourcePath comes from the provider for exactly that reason -
            the mapped drive in a network deployment, the media itself on
            standalone media.

            A FAILURE STOPS THE LIST. An application that returns a code in
            neither its successCodes nor its rebootCodes fails the step naming the
            application and the code, and the applications after it do not run -
            installing software on top of a failed dependency is how a machine
            ends up subtly broken. continueOnError on the step is how a sequence
            says otherwise, and that belongs to the loop rather than here.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry
            FileSystem and Process services; Registry and ScriptInvoker are needed
            only by the detection rules that use them.

        .OUTPUTS
            A New-HDTStepResult. Data carries planned, installed (what the RUN
            has installed, across every leg - the _HDTApplicationInstalled
            checkpoint), installedThisLeg, skippedAlreadyPresent (a detect rule
            found it on the machine), skippedEarlierLeg (this run installed it
            before a reboot) and, on a failure, the application and its exit
            code. The two kinds of skip are never merged: one says the software
            was there before HDT arrived, the other says idempotency worked.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'InstallApplications' })[0]

            Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context
            $result.Data.Installed

            The applications it installed, in the dependency order it worked out. A
            step that asked for a reboot comes back Completed with the engine told
            to restart.
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

    $progressVariable = '_HDTApplicationInstalled'

    $fail = {
        param([string] $Message, [System.Collections.IDictionary] $Data)

        $payload = $Data
        if ($null -eq $payload) { $payload = [ordered] @{} }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'InstallApplications' -Data $payload

        return (New-HDTStepResult -Status Failed -Message $Message -Data $payload)
    }

    # -- the selection --------------------------------------------------------

    # A list in YAML stays a list; a token is expanded and then split, because
    # HDTApplications holds what a wizard or a rule wrote into one string.
    $split = {
        param([string] $Text)

        return @(@($Text -split '[,;\r\n]') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $property = $Step.Property
    $selection = @()

    # WHICH INPUT ASKED FOR WHICH APPLICATION. The resolver knows what pulled an
    # application in; only this function knows what named it in the first place,
    # and "HDTApplications asked for it" is the line that ties a plan back to the
    # "HDTApplications = '...' (Rule)" the variable log already wrote.
    #
    # FIRST WRITER WINS, the way Add-HDTResolvedVariable's precedence works: the
    # lists are read in the order below and an id already accounted for keeps the
    # source that first named it.
    $selectionSource = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    $attribute = {
        param([string[]] $Id, [string] $Name)

        foreach ($current in @($Id)) {
            if (-not $selectionSource.Contains([string] $current)) {
                $selectionSource[[string] $current] = $Name
            }
        }
    }

    if ($null -ne $property -and $property.Contains('selection')) {
        $raw = $property['selection']

        # A LIST EXPANDS ELEMENT BY ELEMENT. The flat form below goes through
        # Get-HDTStepProperty -Expand, so a YAML sequence has to be walked here
        # or the two ways of writing the same selection behave differently -
        # `selection: '%HDTApplications%'` resolved and `selection: ['%HDTApp1%']`
        # looked for an application whose id was a percent sign.
        if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
            $selection = @(@($raw) |
                    ForEach-Object { ([string] (Expand-HDTVariableToken -Value ([string] $_) -Scope $Context.Variable)).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } else {
            try {
                $expanded = Get-HDTStepProperty -Step $Step -Name 'selection' -Context $Context -Expand -As String
            } catch {
                return (& $fail ([string] $_.Exception.Message) ([ordered] @{ errorId = 'HDTConfigurationError' }))
            }

            $selection = & $split ([string] $expanded)
        }

        & $attribute $selection "the step's selection"
    } elseif ($Context.Variable.Contains('HDTApplications')) {
        $selection = & $split ([string] $Context.Variable['HDTApplications'])

        & $attribute $selection 'HDTApplications'
    }

    # -- what the site installs whatever the technician picked ----------------
    #
    # MDT's MandatoryApplications, and it is a SECOND list rather than a default
    # for the first: a default is what you get when nobody chose, and this is
    # what you get when somebody did. The management agent, the antivirus, the
    # certificate deployer - the things a site does not let a person opt out of
    # by clicking past a page.
    #
    # IT SURVIVES A PINNED SELECTION. A sequence naming an exact list is the
    # case this exists for; if a pinned selection could drop it, the property
    # would mean "mandatory unless a sequence author forgot", which is not a
    # guarantee anybody can build a compliance story on.
    #
    # IT DOES NOT JUMP THE QUEUE, and that is where HDT parts company with MDT.
    # MDT installs its mandatory list first, for no better reason than that it
    # processes two lists in two loops. Resolve-HDTApplicationOrder emits ready
    # applications smallest id first precisely so a plan does not depend on the
    # order a selection was written in, and spending that determinism on the
    # convention would be the wrong trade. A site that needs its agent in place
    # before everything else declares a dependency edge - the mechanism that
    # already exists, and the only one that survives somebody adding a third
    # application next year.
    if ($Context.Variable.Contains('HDTMandatoryApplications')) {
        $mandatory = & $split ([string] $Context.Variable['HDTMandatoryApplications'])

        & $attribute $mandatory 'HDTMandatoryApplications'

        if (@($mandatory).Count -gt 0) {
            $merged = New-Object -TypeName System.Collections.ArrayList
            $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($id in (@($mandatory) + @($selection))) {
                if ($seen.Add([string] $id)) {
                    [void] $merged.Add([string] $id)
                }
            }

            $selection = [string[]] @($merged)
        }
    }

    if (@($selection).Count -eq 0) {
        # A sequence that offers applications and a technician who picked none is
        # an ordinary deployment.
        $message = 'no applications were selected.'

        Write-HDTLog -Context $Context.Log -Message $message -Component 'InstallApplications' `
            -Data ([ordered] @{ planned = 0 })

        return (New-HDTStepResult -Status Completed -Message $message -Data ([ordered] @{
                    planned               = [string[]] @()
                    installed             = [string[]] @()
                    installedThisLeg      = [string[]] @()
                    skippedAlreadyPresent = [string[]] @()
                    skippedEarlierLeg     = [string[]] @()
                }))
    }

    # -- the services ---------------------------------------------------------

    try {
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'InstallApplications')
        $process = $Context.Service.GetRequired('Process', 'InstallApplications')
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null)
    }

    # -- the plan -------------------------------------------------------------

    # THE TRACE COLLECTIONS BELONG TO THE STEP, and that is the point of their
    # being parameters rather than a second return value: the resolver fills them
    # as it walks, so a plan that CANNOT be ordered still leaves behind the
    # closure it got through and the cycle that stopped it. The run where the
    # resolution failed used to be the one run with no record of the resolution.
    $provenance = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $planDecision = New-Object -TypeName System.Collections.ArrayList
    $plan = @()

    try {
        $catalog = @(Get-HDTApplication -WorkspaceRoot ([string] $Context.WorkspaceRoot) `
                -FileSystem $fileSystem -Content $Context.Service.Content)

        $plan = @(Resolve-HDTApplicationOrder -Application $catalog -Id $selection `
                -Provenance $provenance -Decision $planDecision)
    } catch {
        Write-HDTApplicationPlanLog -Context $Context.Log -Plan $plan -Provenance $provenance `
            -Decision $planDecision -Source $selectionSource

        return (& $fail ([string] $_.Exception.Message) ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $plannedId = [string[]] @($plan | ForEach-Object { [string] $_.Id })

    # THE PLAN, AND WHY EVERY LINE OF IT IS THERE. The plan line alone said WHAT
    # would install; a real run installed an application nobody had asked for and
    # the log offered no way to tell that from a typo in HDTApplications.
    Write-HDTApplicationPlanLog -Context $Context.Log -Plan $plan -Provenance $provenance `
        -Decision $planDecision -Source $selectionSource

    # -- the progress this run already made -----------------------------------

    $installed = New-Object -TypeName System.Collections.ArrayList

    if ($Context.Variable.Contains($progressVariable)) {
        foreach ($current in @($Context.Variable[$progressVariable])) {
            if (-not [string]::IsNullOrWhiteSpace([string] $current)) {
                [void] $installed.Add([string] $current)
            }
        }
    }

    # WHAT THIS LEG DID, KEPT APART FROM WHAT THE RUN HAS DONE. $installed is
    # SEEDED above from _HDTApplicationInstalled, so on a resumed leg it starts
    # non-empty - it is the run's checkpoint and the next leg resumes from it.
    # Counting it as "installed" is what made the summary contradict its own
    # detail on run-20260830-221934: two applications logged as skipped and a
    # closing line reading "installed 2 application(s), skipped 0 already
    # present."
    $installedThisLeg = New-Object -TypeName System.Collections.ArrayList

    # AND TWO KINDS OF SKIP, NEVER ONE NUMBER. "A detect rule found it already
    # on the machine" and "this run installed it before the reboot" answer
    # different questions - the first is an application that was there before
    # HDT arrived, the second is idempotency working - and an admin reading a
    # second pass needs to tell them apart. $skipped is the detect-rule kind.
    $skipped = New-Object -TypeName System.Collections.ArrayList
    $skippedEarlierLeg = New-Object -TypeName System.Collections.ArrayList

    $comSpec = 'cmd.exe'
    if ($null -ne $Context.Service.Environment) {
        $fromEnvironment = [string] $Context.Service.Environment.GetVariable('ComSpec')
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { $comSpec = $fromEnvironment }
    }

    $timeoutMillisecond = 0
    if ([int] $Step.TimeoutMinutes -gt 0) {
        $timeoutMillisecond = [int] $Step.TimeoutMinutes * 60000
    }

    $checkpoint = {
        # The live variable dictionary is copied into the state document on every
        # save, so writing the progress here is what makes it survive the reboot.
        $Context.Variable[$progressVariable] = [string[]] @($installed)
    }

    $clock = $Context.Service.Clock

    # -- what goes in the log, and what must not ------------------------------
    #
    # THE COMMAND LINE IS THE MOST USEFUL LINE THIS STEP CAN WRITE AND THE ONE
    # MOST LIKELY TO LEAK. An install: line is a vendor's own silent install,
    # copied out of their documentation, and vendors document credentials on it
    # - /PASSWORD=, /pid=, -licenseKey=. The log is written to the share, which
    # every machine being deployed can read (Format-HDTConsoleLogValue makes the
    # same argument about the console log), and it is the file that gets
    # attached to a support case.
    #
    # THE SWITCH NAME SURVIVES, THE VALUE DOES NOT. An admin reproducing the
    # install by hand still has to know the argument was passed; they do not
    # need the secret back out of the log, and if they do they have the app.yaml
    # it came from.
    #
    # A SWITCH IS ONLY HALF OF IT. TightVNC's own documented silent install, on
    # this lab's share, is
    # 'msiexec /i ... SET_PASSWORD=1 VALUE_OF_PASSWORD=<secret>' - an MSI
    # PROPERTY, with no leading slash. A redactor that recognised only switches
    # wrote that password into the log of every machine that installed it, which
    # is what the first version of this did and what the test beside it now
    # refuses.
    #
    # AND A REDACTOR THAT EATS THE COMMAND LINE IS WORSE THAN NO REDACTOR, which
    # is where this deviates from Format-HDTConsoleLogValue on purpose. That one
    # matches a bare 'pass' because it reads PARAMETER NAMES, where redacting
    # one too many costs nothing. Here the subject is a command line an admin is
    # meant to paste into a prompt: '/passive' starts with those four letters,
    # and matching it would swallow the argument after it and hand the admin a
    # line that does not work. So the words are whole - password, passwd, pwd,
    # passphrase, secret, credential, token, key - bounded on both sides by
    # something that is not a letter, which is what keeps 'passive' and 'monkey'
    # out.
    #
    # TWO SHAPES, because a value arrives two ways: NAME=value or NAME:value in
    # one token, and '-Password value' as two. The second refuses to eat a token
    # that begins with / or -, so a flag followed by the next flag survives.
    $secretWord = '(?<![a-z])(?:password|passwd|pwd|passphrase|secret|credential|token|key)(?![a-z])'

    $redact = {
        param([string] $CommandLine)

        $text = [regex]::Replace($CommandLine,
            ('(?i)((?:[/-]{{1,2}})?[\w.-]*{0}[\w.-]*)([=:])(\S+)' -f $secretWord),
            '$1$2<redacted>')

        return [regex]::Replace($text,
            ('(?i)([/-]{{1,2}}[\w.-]*{0}[\w.-]*)(\s+)(?![/-])(\S+)' -f $secretWord),
            '$1$2<redacted>')
    }

    # A DETECTION RULE, ON ONE LINE. Get-HDTApplicationDetectText renders the
    # app.yaml block, which is several lines and is meant for a file; a log line
    # is read, so this is the same facts flattened.
    $describeDetect = {
        param([object] $Detect)

        if ($null -eq $Detect) { return '' }

        $part = New-Object -TypeName System.Collections.ArrayList
        $type = ''

        foreach ($property in @($Detect.PSObject.Properties)) {
            if ([string] $property.Name -eq 'Type') {
                $type = [string] $property.Value
                continue
            }

            # AN OPTIONAL KEY THE PROJECTION FILLED WITH NOTHING IS NOT A FACT
            # ABOUT THE RULE. Get-HDTApplication gives a file rule a 'version'
            # whether or not app.yaml declared one, and printing 'version=' with
            # nothing after it puts a field on the line that says only that the
            # renderer does not read what it prints.
            if ([string]::IsNullOrWhiteSpace([string] $property.Value)) { continue }

            [void] $part.Add(('{0}={1}' -f ([string] $property.Name).ToLowerInvariant(), [string] $property.Value))
        }

        if (@($part).Count -eq 0) { return $type }

        return ('{0}: {1}' -f $type, ($part -join ', '))
    }

    # -- what the installer itself said ---------------------------------------
    #
    # IT WAS BEING CAPTURED AND THROWN AWAY. IProcessService.Start has returned
    # StandardOutput and StandardError since it was written - the contract file
    # asserts both properties on both implementations - and this step read
    # ExitCode and dropped the rest. An installer that fails with 1603 prints
    # the reason on its way out, and the log recorded the number alone.
    #
    # NO ADAPTER CHANGE, AND THAT IS WORTH SAYING OUT LOUD. New-HDTProcessService
    # already drains both pipes asynchronously BEFORE it starts waiting -
    # ReadToEndAsync, precisely so a child that fills the 4 KB pipe buffer
    # cannot deadlock the wait - so reading the output here costs the 500 ms
    # poll nothing and the heartbeat loop is untouched.
    #
    # MDT'S SHAPE, WITH ONE DELIBERATE DEVIATION IN THE LEVEL.
    # StandardConsoleProcessing (ZTIUtility.vbs 2255-2299) writes one entry per
    # line, "  Console > " for stdout at LogTypeInfo and "  Console # " for
    # stderr at LogTypeError - two markers rather than one merged stream, so a
    # reader can tell which pipe a line came out of. HDT keeps the markers and
    # the one-record-per-line shape, and moves the level, for two reasons:
    #
    #   stdout at Info     a chatty installer that SUCCEEDED would cost a
    #                      technician a screen of scrollback and the share an
    #                      SMB round trip per line, for output nobody wanted
    #   stderr at Error    an installer that writes a benign note to stderr and
    #                      exits 0 would put Error records on a green run, and
    #                      HDT's failure window is derived from exactly those
    #
    # So the level follows the EXIT CODE instead: Debug when the code was
    # accepted, Warning (stdout) and Error (stderr) when it was not. A failing
    # install explains itself at the default level; a succeeding one stays
    # quiet.
    #
    # AND MDT'S APPLICATION STEP DOES NOT CAPTURE OUTPUT AT ALL, which is the
    # one place this goes further than MDT rather than following it.
    # ZTIApplications calls RunWithHeartbeat, which passes a NULL hook, which
    # takes the branch of RunCommandLog that skips console processing entirely -
    # so an MDT log records an application's exit code and nothing else either.
    # The vocabulary is MDT's; capturing an application's output is not.

    # HOW MANY LINES REACH THE LOG, and it is a TAIL: the reason an installer
    # gave up is the last thing it says, not the first. Forty on a success is a
    # courtesy; two hundred on a failure is evidence, and it is only ever paid
    # for by the run that has already gone wrong.
    $consoleLineLimit = 40
    $consoleLineLimitOnFailure = 200

    # AND HOW LONG ONE LINE MAY BE. An installer that draws a progress bar with
    # carriage returns emits a single line megabytes long. Splitting on a bare
    # CR as well as a newline turns that into many - the tail then keeps the
    # finished state, which is the only part worth reading - and this bounds
    # whatever is still oversized after that.
    $consoleLineLength = 1000

    $splitConsole = {
        param([string] $Text)

        if ([string]::IsNullOrEmpty($Text)) { return @() }

        return @(@($Text -split "`r`n|`n|`r") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $writeConsole = {
        param([string] $Id, [string[]] $Line, [string] $Marker, [string] $Stream, [string] $Severity, [int] $Limit)

        $count = @($Line).Count
        if ($count -eq 0) { return }

        $shown = @($Line)

        if ($count -gt $Limit) {
            $shown = @($Line[($count - $Limit)..($count - 1)])

            # NEVER SILENTLY. A truncation nobody is told about reads as an
            # installer that stopped talking, which is a different fault
            # entirely - so the count that was dropped is named before the
            # lines that survived.
            Write-HDTLog -Context $Context.Log -Severity $Severity -Event 'native.exec' `
                -Component 'InstallApplications' `
                -Message ("'{0}' {1} was {2} line(s); the first {3} are not shown, the last {4} follow." -f
                    $Id, $Stream, $count, ($count - $Limit), $Limit) `
                -Data ([ordered] @{
                    application = $Id
                    stream      = $Stream
                    lines       = $count
                    dropped     = ($count - $Limit)
                })
        }

        foreach ($text in $shown) {
            # THE SAME REDACTOR THE COMMAND LINE GOES THROUGH, and deliberately
            # not a second one. An installer routinely echoes its own arguments
            # back - TightVNC's VALUE_OF_PASSWORD reaches the log by that route
            # one line after the command line it was redacted out of - and two
            # redactors would have drifted apart by the next vendor.
            $one = & $redact ([string] $text)

            if ($one.Length -gt $consoleLineLength) {
                $one = '{0} ...({1} more character(s))' -f $one.Substring(0, $consoleLineLength),
                ($one.Length - $consoleLineLength)
            }

            Write-HDTLog -Context $Context.Log -Severity $Severity -Event 'native.exec' `
                -Component 'InstallApplications' `
                -Message ('  console {0} {1}' -f $Marker, $one) `
                -Data ([ordered] @{ application = $Id; stream = $Stream })
        }
    }

    # -- the list -------------------------------------------------------------

    # WHERE THIS STEP IS IN ITS OWN LIST, WHICH IS THE ONLY MEASURE IT HAS.
    # msiexec does not report how far through a 687 MB patch it is, so "1 of 2"
    # is the honest number and it is already in hand: the ordered plan is
    # resolved and logged before anything runs.
    #
    # THE STEP USED TO SAY NOTHING BETWEEN STARTING AN INSTALLER AND IT
    # RETURNING. Measured on LT-7FJ45S2, run-20260829-172208: two applications
    # over SMB, and the whole step wrote four lines - the plan, one line after
    # each application had finished, and a total. All boundaries. For the
    # minutes in between, the progress card showed a motionless bar, and because
    # elapsed on that card is derived from the first and last record in the log,
    # the clock stopped with it. A working machine looked exactly like a hung
    # one.
    #
    # COUNTED OVER THE WHOLE PLAN, INCLUDING THE ONES IT SKIPS, so the number a
    # technician reads is a position in the list they were shown rather than a
    # tally of work this leg happened to do.
    $position = 0
    $total = @($plannedId).Count

    # ANNOUNCED, THEN BANKED - TWO RECORDS PER APPLICATION, AND THE SECOND ONE
    # IS THE FIX. What shipped wrote only the first, at (position - 1) / total,
    # so a two-application list produced exactly two numbers: 0 when Acrobat
    # started and 50 when TightVNC started. Measured on LT-7FJ45S2,
    # run-20260829-190105, seq 133 and 135. The bar opened empty, moved once,
    # and the step ENDED at half - which on a wall is indistinguishable from a
    # step that never reported at all, and is what "the application step shows
    # no progress" actually was.
    #
    # MDT REPORTS ONE RECORD, AT n / total, BEFORE THE INSTALL.
    # ZTIApplications.wsf line 167: iPercent = CLng(iApplicationCount /
    # oApplications.Count * 100), reported as "Installing <Name>" - so MDT's bar
    # jumps to 50% the instant Acrobat starts and to 100% the instant TightVNC
    # does, and sits at 100% for however long the last installer takes. HDT
    # keeps MDT's endpoints, which is the part a technician reads, and splits
    # the difference across two records rather than crediting an install that
    # has not happened yet: a bar that reaches 100% while an MSI is still
    # running is the same lie as a bar that stops at 50%, pointing the other
    # way.
    #
    # A SKIP IS BANKED TOO, and both kinds of skip. A plan whose applications
    # are all already present, and a resumed leg whose first three were
    # installed before the reboot, are plans the step is genuinely part-way
    # through; a bar that ignored them would start the leg after a reboot behind
    # where the leg before it ended.
    $report = {
        param([int] $Done, [int] $Credited, [string] $Id, [string] $Message)

        $percent = 0
        if ($total -gt 0) {
            $percent = [int] [System.Math]::Floor(($Credited / $total) * 100)
        }

        Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'InstallApplications' `
            -Message $Message `
            -Data ([ordered] @{
                application = $Id
                done        = $Done
                total       = $total
                percent     = $percent
            })

        # AND THEN TELL THE WINDOW TO LOOK. Update-HDTProgressDisplay re-reads
        # the log and hands the host a new snapshot; without this the record
        # above is written and never drawn. The same two lines ApplyImage and
        # ApplyDrivers use, and it is documented never to fail a deployment.
        Update-HDTProgressDisplay -Context $Context
    }

    foreach ($application in $plan) {
        $id = [string] $application.Id
        $position++

        # Already done on an earlier leg of THIS run. Resuming at the next
        # application rather than restarting the list is the whole point of
        # checkpointing.
        if ($installed -contains $id) {
            [void] $skippedEarlierLeg.Add($id)

            Write-HDTLog -Context $Context.Log -Severity Debug -Component 'InstallApplications' `
                -Message ("'{0}' was installed on an earlier leg of this run." -f $id) `
                -Data ([ordered] @{ application = $id })

            & $report $position $position $id (
                'skipped {0} of {1}: {2}, installed on an earlier leg of this run.' -f
                $position, $total, [string] $application.Name)

            continue
        }

        try {
            $alreadyInstalled = Test-HDTApplicationDetection -Detect $application.Detect `
                -FileSystem $fileSystem -Registry $Context.Service.Registry `
                -ScriptInvoker $Context.Service.ScriptInvoker -Variable $Context.Variable
        } catch {
            return (& $fail ("'{0}': {1}" -f $id, [string] $_.Exception.Message) ([ordered] @{
                        application           = $id
                        planned               = $plannedId
                        installed             = [string[]] @($installed)
                        installedThisLeg      = [string[]] @($installedThisLeg)
                        skippedAlreadyPresent = [string[]] @($skipped)
                        skippedEarlierLeg     = [string[]] @($skippedEarlierLeg)
                    }))
        }

        # WHAT THE RULE LOOKED FOR AND WHAT IT FOUND, FOR EVERY APPLICATION -
        # including the ones it decides to install. Logging only the skips is
        # what made a wrong detection rule invisible: the application installs
        # every run, the rule never matched, and nothing in the log says the
        # rule was even evaluated. MDT logs one half of this ("Uninstall
        # registry key found, application is already installed."); the other
        # half is the one an admin actually needs.
        #
        # DEBUG, NOT INFO. A technician standing at the machine wants the plan,
        # a line per application and a total; this is what a support case turns
        # on a week later.
        $detectText = & $describeDetect $application.Detect

        if ([string]::IsNullOrWhiteSpace($detectText)) {
            Write-HDTLog -Context $Context.Log -Severity Debug -Component 'InstallApplications' `
                -Message ("'{0}': no detect rule, so it installs every time (DESIGN 8)." -f $id) `
                -Data ([ordered] @{ application = $id })
        } elseif ($alreadyInstalled) {
            Write-HDTLog -Context $Context.Log -Severity Debug -Component 'InstallApplications' `
                -Message ("'{0}': detection ({1}) found it, so it will not be installed again." -f $id, $detectText) `
                -Data ([ordered] @{ application = $id; detect = $detectText; detected = $true })
        } else {
            Write-HDTLog -Context $Context.Log -Severity Debug -Component 'InstallApplications' `
                -Message ("'{0}': detection ({1}) did not find it, so it will be installed." -f $id, $detectText) `
                -Data ([ordered] @{ application = $id; detect = $detectText; detected = $false })
        }

        if ($alreadyInstalled) {
            [void] $skipped.Add($id)

            Write-HDTLog -Context $Context.Log -Component 'InstallApplications' `
                -Message ("'{0}' is already installed; skipping it." -f $application.Name) `
                -Data ([ordered] @{ application = $id })

            & $report $position $position $id (
                'skipped {0} of {1}: {2}, already installed.' -f
                $position, $total, [string] $application.Name)

            continue
        }

        $argument = '/c {0}' -f [string] $application.Install

        # -- what the screen says for the next few minutes --------------------
        #
        # BEFORE THE INSTALLER, NOT AFTER IT. A line written when Acrobat
        # returns is four minutes too late to tell anybody what the machine was
        # doing. This is the record the progress card draws and the one that
        # keeps its elapsed clock moving.
        #
        # THE NAME, NOT THE COMMAND LINE. DESIGN 4.4.5 keeps the command at
        # Debug because it routinely carries a licence key; the application's
        # own name carries nothing and is what a technician recognises.
        #
        # THE PERCENTAGE IS HOW FAR THROUGH THE LIST, NOT THROUGH THE INSTALL.
        # Starting the first of two is nought per cent done, not fifty - the bar
        # must not credit work that has not happened. The record that DOES
        # credit it is written below, once the installer has returned.
        & $report $position ($position - 1) $id (
            'installing {0} of {1}: {2}' -f $position, $total, [string] $application.Name)

        # MDT'S TWO LINES, IN MDT'S ORDER, WITH MDT'S WORDING AND NOW AT MDT'S
        # LEVEL. ZTIApplications.wsf writes "Change directory: <dir>" (line 412)
        # and then "Run Command: <cmd>" (line 441), both with LogTypeInfo, so an
        # admin reading a DEFAULT MDT log sees the command that ran. An admin
        # who has read one MDT log has read this one.
        #
        # THESE WERE AT DEBUG, AND THAT WAS THE DEFECT. The command line is the
        # single line that makes a failure reproducible by hand, and an admin
        # must not have to re-run a whole deployment at a raised level to get
        # it back - by which time the machine that failed has been rebuilt.
        # DESIGN 4.4.5 keeps command lines at Debug because they carry licence
        # keys; the redactor above is what answers that, and it answers it
        # without costing the line. Everything else this step learned - which
        # detection rule was evaluated, which configured code matched - stays at
        # Debug, because that is what a support case turns on a week later and
        # not what a technician standing at the machine is reading.
        #
        # SourcePath IS BOTH, and that is why one value appears under a name
        # about directories: it is the folder the content provider resolved for
        # this application - the mapped drive in a network deployment, the media
        # on standalone media - and it is the working directory cmd.exe is given
        # so the vendor's own relative 'msiexec /i setup.msi' resolves.
        Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'InstallApplications' `
            -Message ("'{0}' change directory: {1}" -f $id, [string] $application.SourcePath) `
            -Data ([ordered] @{ application = $id; workingDirectory = [string] $application.SourcePath })

        Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'InstallApplications' `
            -Message ("'{0}' run command: {1} {2}" -f $id, $comSpec, (& $redact $argument)) `
            -Data ([ordered] @{ application = $id; commandLine = (& $redact ('{0} {1}' -f $comSpec, $argument)) })

        # ITS OWN ELAPSED, the way ApplyDrivers and ApplyImage report theirs.
        # An installer that took two minutes and one that took two seconds are
        # different machines, and the step-level total cannot tell them apart on
        # a list of five.
        $startedUtc = $clock.GetUtcNow()

        # AND SOMETHING TO SAY WHILE IT RUNS, because the two records either side
        # of this call are all a two-minute installer used to write. On
        # LT-7FJ45S2 run-20260829-190105 the "installing 1 of 2" line landed at
        # 16:13:41.358 and the next record of any kind at 16:15:38.176: the bar
        # was right, the name was right, and NOTHING MOVED for one hundred and
        # seventeen seconds, elapsed clock included, because
        # Get-HDTDeploymentProgress derives everything from record timestamps.
        #
        # THE NAME, NOT THE COMMAND LINE, for the reason two records up: DESIGN
        # 4.4.5 keeps command lines at Debug because they carry licence keys, and
        # a heartbeat is written at Info.
        #
        # THE INTERVAL AND THE RECORD'S SHAPE ARE NOT DECIDED HERE.
        # New-HDTStepHeartbeat owns both, so this step and every other one that
        # waits on somebody else's program report at the same stride.
        $heartbeat = New-HDTStepHeartbeat -Context $Context -Component 'InstallApplications' `
            -Activity ([string] $application.Name)

        $result = $process.Start($comSpec, $argument, [string] $application.SourcePath, $timeoutMillisecond, $heartbeat)

        $installMillisecond = [long] (($clock.GetUtcNow()) - $startedUtc).TotalMilliseconds

        $exitCode = [int] $result.ExitCode

        $data = [ordered] @{
            application           = $id
            exitCode              = $exitCode
            planned               = $plannedId
            installed             = [string[]] @($installed)
            installedThisLeg      = [string[]] @($installedThisLeg)
            skippedAlreadyPresent = [string[]] @($skipped)
            skippedEarlierLeg     = [string[]] @($skippedEarlierLeg)
        }

        # THE CODES IT WAS CONFIGURED TO ACCEPT, AND WHICH ONE MATCHED. Both
        # applications in the run that surfaced this had rebootCodes: [3010]
        # configured and nothing recorded that it had been considered at all -
        # so an admin chasing an installer that returned 3010 and did not reboot
        # could not tell a missing rebootCodes entry from an engine defect.
        $matched = 'no configured code'
        if (@($application.RebootCodes) -contains $exitCode) {
            $matched = 'a reboot code'
        } elseif (@($application.SuccessCodes) -contains $exitCode) {
            $matched = 'a success code'
        }

        # WHETHER THIS INSTALL IS ABOUT TO BE ACCEPTED, worked out once and read
        # twice: it is what decides how loudly the installer's own output is
        # logged, and $matched is already the only place that judgement lives. A
        # timeout is never acceptance - the process was killed mid-install, and
        # whatever it managed to print before that is the most useful thing in
        # the log.
        $accepted = ($matched -ne 'no configured code') -and (-not [bool] $result.TimedOut)

        $standardOutputLine = & $splitConsole ([string] $result.StandardOutput)
        $standardErrorLine = & $splitConsole ([string] $result.StandardError)

        if (@($standardOutputLine).Count -gt 0 -or @($standardErrorLine).Count -gt 0) {
            # AT INFO, BECAUSE A CAPTURE NOBODY IS TOLD ABOUT IS INVISIBLE. On a
            # successful install the lines themselves stay at Debug, so this one
            # line is the only thing that tells a technician there is something
            # to raise the level for. It costs the common case nothing: a silent
            # MSI prints nothing at all and this never fires.
            Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'InstallApplications' `
                -Message ("'{0}' wrote {1} line(s) to stdout and {2} to stderr." -f
                    $id, @($standardOutputLine).Count, @($standardErrorLine).Count) `
                -Data ([ordered] @{
                    application = $id
                    stdoutLines = @($standardOutputLine).Count
                    stderrLines = @($standardErrorLine).Count
                })
        }

        # MDT'S ORDER: the console lines, and then the return code.
        if ($accepted) {
            & $writeConsole $id ([string[]] @($standardOutputLine)) '>' 'stdout' 'Debug' $consoleLineLimit
            & $writeConsole $id ([string[]] @($standardErrorLine)) '#' 'stderr' 'Debug' $consoleLineLimit
        } else {
            & $writeConsole $id ([string[]] @($standardOutputLine)) '>' 'stdout' 'Warning' $consoleLineLimitOnFailure
            & $writeConsole $id ([string[]] @($standardErrorLine)) '#' 'stderr' 'Error' $consoleLineLimitOnFailure
        }

        Write-HDTLog -Context $Context.Log -Severity Debug -Event 'native.exec' -Component 'InstallApplications' `
            -Message ("'{0}' returned exit code {1} in {2} ms; successCodes ({3}), rebootCodes ({4}) - it matched {5}." -f
                $id, $exitCode, $installMillisecond, (@($application.SuccessCodes) -join ', '),
                (@($application.RebootCodes) -join ', '), $matched) `
            -Data ([ordered] @{
                application  = $id
                exitCode     = $exitCode
                durationMs   = [long] $installMillisecond
                successCodes = [int[]] @($application.SuccessCodes)
                rebootCodes  = [int[]] @($application.RebootCodes)
                matched      = $matched
            })

        if ([bool] $result.TimedOut) {
            return (& $fail ("'{0}' timed out after {1} minute(s) and was stopped." -f $id, $Step.TimeoutMinutes) $data)
        }

        # rebootCodes is checked FIRST, the same precedence the CommandLine step
        # states: an installer reporting 3010 that also lists it as successful is
        # a real configuration, and treating it as plain success would drop the
        # restart it asked for.
        if (@($application.RebootCodes) -contains $exitCode) {
            # 3010 is "installed, reboot required" - so it IS installed, and the
            # next leg must not run it again.
            [void] $installed.Add($id)
            [void] $installedThisLeg.Add($id)
            & $checkpoint

            $message = "'{0}' returned exit code {1} in {2} ms and asked for a restart. {3} of {4} application(s) done." -f
            $id, $exitCode, $installMillisecond, @($installed).Count, @($plannedId).Count

            Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' `
                -Component 'InstallApplications' -Data ([ordered] @{
                    application           = $id
                    exitCode              = $exitCode
                    installed             = [string[]] @($installed)
                    installedThisLeg      = [string[]] @($installedThisLeg)
                    skippedAlreadyPresent = [string[]] @($skipped)
                    skippedEarlierLeg     = [string[]] @($skippedEarlierLeg)
                })

            & $report $position $position $id (
                'installed {0} of {1}: {2}, which asked for a restart.' -f
                $position, $total, [string] $application.Name)

            return (New-HDTStepResult -Status RebootRequested -ExitCode $exitCode -Reenter `
                    -Message $message -Data ([ordered] @{
                        application           = $id
                        exitCode              = $exitCode
                        planned               = $plannedId
                        installed             = [string[]] @($installed)
                        installedThisLeg      = [string[]] @($installedThisLeg)
                        skippedAlreadyPresent = [string[]] @($skipped)
                        skippedEarlierLeg     = [string[]] @($skippedEarlierLeg)
                    }))
        }

        if (-not (@($application.SuccessCodes) -contains $exitCode)) {
            return (& $fail ("'{0}' returned {1}, which is not in its successCodes ({2}) or rebootCodes ({3}). The applications after it were not installed." -f
                    $id, $exitCode, (@($application.SuccessCodes) -join ', '), (@($application.RebootCodes) -join ', ')) $data)
        }

        [void] $installed.Add($id)
        [void] $installedThisLeg.Add($id)
        & $checkpoint

        # THE HOUSE STYLE, NOT A FOURTH ONE. ApplyDrivers ends "in 48078 ms.",
        # ApplyImage "in 131203 ms.", and the CommandLine step says "'X'
        # returned N" - so an exit code is named as one and the elapsed reads
        # the same as everywhere else. This line used to end in a bare "(0)",
        # which is an unlabelled number in the one place an admin is counting on
        # the log to be unambiguous.
        Write-HDTLog -Context $Context.Log `
            -Message ("installed '{0}'; it returned exit code {1} in {2} ms." -f
                $application.Name, $exitCode, $installMillisecond) `
            -Event 'native.exec' -Component 'InstallApplications' `
            -Data ([ordered] @{ application = $id; exitCode = $exitCode; durationMs = [long] $installMillisecond })

        & $report $position $position $id (
            'installed {0} of {1}: {2}.' -f $position, $total, [string] $application.Name)
    }

    # THE CLOSING LINE, AND IT HAS TO AGREE WITH THE LINES ABOVE IT. This used
    # to read "installed {n} application(s), skipped {n} already present." off
    # $installed and $skipped, and both halves were wrong on a resumed leg:
    # $installed is the RUN's checkpoint, seeded from _HDTApplicationInstalled
    # before the loop starts, so a second pass that installed nothing at all
    # reported every application the first pass had installed as its own work -
    # directly under two lines each saying "skipped ..., installed on an earlier
    # leg of this run".
    #
    # THREE NUMBERS, NOT TWO, because there are three outcomes and merging any
    # two of them loses the question the line is read to answer. "0 installed, 2
    # skipped" cannot distinguish a second pass proving idempotency from a
    # machine that already had both applications before HDT touched it.
    $message = ('installed {0} of {1} planned application(s) on this leg; ' +
        'skipped {2} that a detect rule found already present and ' +
        '{3} that an earlier leg of this run installed. ' +
        '{4} of {1} planned application(s) are installed by this run in all.') -f
    @($installedThisLeg).Count, @($plannedId).Count, @($skipped).Count,
    @($skippedEarlierLeg).Count, @($installed).Count

    Write-HDTLog -Context $Context.Log -Message $message -Component 'InstallApplications' `
        -Data ([ordered] @{
            planned               = $plannedId
            installed             = [string[]] @($installed)
            installedThisLeg      = [string[]] @($installedThisLeg)
            skippedAlreadyPresent = [string[]] @($skipped)
            skippedEarlierLeg     = [string[]] @($skippedEarlierLeg)
        })

    return (New-HDTStepResult -Status Completed -Message $message -Data ([ordered] @{
                planned               = $plannedId
                installed             = [string[]] @($installed)
                installedThisLeg      = [string[]] @($installedThisLeg)
                skippedAlreadyPresent = [string[]] @($skipped)
                skippedEarlierLeg     = [string[]] @($skippedEarlierLeg)
            }))
}
