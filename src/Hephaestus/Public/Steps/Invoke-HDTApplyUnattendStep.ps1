function Invoke-HDTApplyUnattendStep {
    <#
        .SYNOPSIS
            Stages the unattend where Windows Setup consumes it.

        .DESCRIPTION
            Staging an unattend, as a step:

              - name: Apply Unattend
                type: ApplyUnattend
                template: unattend.xml     # relative to the sequence folder
                target: "%HDTOSVolume%"    # optional
                expand: true               # optional, default true

            THE DESTINATION IS <target>:\Windows\Panther\unattend.xml AND
            NOTHING ELSE IS VERIFIED. S7 deployed a real Windows 11 machine from
            a document staged exactly there: ComputerName applied in the
            specialize pass, OOBE skipped, the built-in Administrator enabled,
            FirstLogonCommands run, and autologon armed with the password held as
            an LSA secret rather than in the registry.

            THE PASSWORD HAS ONE SOURCE: the HDTAdminPassword variable, resolved
            through DESIGN 3.1's precedence like any other. DESIGN 4.5.2 settles
            it - "the administrator sets the password; HDT does not invent one" -
            and the workspace-wide default is the fallback rule of rules.yaml.

            NOTHING SUPPLYING IT FAILS THE STEP, and both alternatives are worse.
            Leaving the token unresolved deploys a machine whose local
            Administrator password is the literal '%HDTAdminPassword%', identical
            on every machine this share ever builds - and it would ship green.
            Minting one deploys a machine nobody can log into, at exactly the
            moment a half-finished deployment needs looking at. A named refusal
            is the only outcome that leaves somebody able to act.

            THE DOCUMENT IS NEVER LOGGED, AT ANY LEVEL. Only the path and the
            byte count. It carries the secret twice - Setup reads UserAccounts
            and AutoLogon separately - so a Debug-level dump of it would put the
            local Administrator password of every machine this toolkit builds
            into a log file that gets copied to a share.

            AN UNRESOLVED TOKEN IS LEFT LITERAL AND REPORTED (02-03's rule), by
            NAME rather than by quoting the line it appeared on.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry a
            FileSystem service.

        .OUTPUTS
            A New-HDTStepResult. Data carries path and byteCount - never the
            document.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyUnattend' })[0]

            Invoke-HDTApplyUnattendStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTApplyUnattendStep -Step $step -Context $context
            $result.Data.Path

            Where the answer file was staged, which is the path Windows Setup reads.
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

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'ApplyUnattend' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    try {
        $template = Get-HDTStepProperty -Step $Step -Name 'template' -Context $Context -Expand -As String
        $target = Get-HDTStepProperty -Step $Step -Name 'target' -Context $Context -Expand -As String
        $expand = Get-HDTStepProperty -Step $Step -Name 'expand' -Default $true -Context $Context -Expand -As Bool
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    if ([string]::IsNullOrWhiteSpace($template)) {
        return (& $fail ("step '{0}' declares no template. An ApplyUnattend step names the unattend to stage." -f $Step.Name) 'HDTConfigurationError')
    }

    try {
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'ApplyUnattend')
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    # -- where the template lives -----------------------------------------

    $templatePath = $template

    if (-not [System.IO.Path]::IsPathRooted($template)) {
        # No literal 'TaskSequences' anywhere: the workspace layout has one
        # owner, and it is Get-HDTWorkspacePath.
        $sequenceId = ''
        if ($null -ne $Context.State -and $null -ne $Context.State.PSObject.Properties['sequenceId']) {
            $sequenceId = [string] $Context.State.sequenceId
        }

        if ([string]::IsNullOrWhiteSpace($sequenceId)) {
            $sequenceId = [string] $Context.Variable['HDTTaskSequenceID']
        }

        if ([string]::IsNullOrWhiteSpace($sequenceId)) {
            return (& $fail ("step '{0}' names a template relative to the sequence folder, and this run does not know which sequence it is running. Set HDTTaskSequenceID, or give the template a rooted path." -f $Step.Name) 'HDTConfigurationError')
        }

        $templatePath = Get-HDTWorkspacePath -Root ([string] $Context.WorkspaceRoot) -Kind TaskSequences `
            -ChildPath $sequenceId, $template
    }

    if (-not $fileSystem.TestPath($templatePath)) {
        return (& $fail ("the unattend template '{0}' is not in this workspace ({1})." -f $template, $templatePath) 'HDTConfigurationError')
    }

    # -- where it goes ----------------------------------------------------

    $letter = $target
    if ([string]::IsNullOrWhiteSpace($letter)) {
        $letter = [string] $Context.Variable['HDTOSVolume']
    }

    if ([string]::IsNullOrWhiteSpace($letter)) {
        return (& $fail ("step '{0}' stages the unattend on the primary volume and HDTOSVolume is not set. The partition step publishes it; set target: on this step if the sequence knows better." -f $Step.Name) 'HDTConfigurationError')
    }

    $letter = $letter.Trim().TrimEnd(':')
    $volume = $letter.Substring(0, 1).ToUpperInvariant()

    # SPIKES S7's VERIFIED LOCATION. Nothing else has been proven to work.
    $pantherPath = '{0}:\Windows\Panther' -f $volume
    $unattendPath = '{0}\unattend.xml' -f $pantherPath

    # -- the document -----------------------------------------------------

    try {
        $text = $fileSystem.ReadAllText($templatePath)
    } catch {
        return (& $fail ("the unattend template '{0}' could not be read: {1}" -f $templatePath, [string] $_.Exception.Message) '')
    }

    # -- the one value Windows will silently discard ----------------------
    #
    # FOUND BY DEPLOYING A REAL MACHINE (04-04). The sample rules.yaml sets
    # HDTComputerName to 'PC-%HDTSerialNumber%', and a Hyper-V VM's serial is 32
    # characters - so HDT wrote a 35-character ComputerName into the unattend.
    # WINDOWS SETUP IGNORED IT WITHOUT COMPLAINT and named the machine
    # WIN-N91191NN153.
    #
    # That is the worst shape a defect can take. Every step reported Completed,
    # the deployment succeeded, no log said anything, and the machine came up
    # with a name nobody chose. So the limit is enforced HERE, where the value
    # is about to become a machine's identity, and the run stops instead.
    #
    # 15 characters is the NetBIOS limit. The illegal characters are the ones
    # Windows itself rejects; a name is otherwise left exactly as authored -
    # HDT does not truncate, because a silently shortened name is the same
    # failure with a different spelling.
    #
    # THE RULE ITSELF IS Test-HDTComputerName, AND IT IS NOT COPIED HERE. The
    # wizard asks a technician for this same value and has to refuse the same
    # names as they type, so the rule grew a second caller - and a rule with two
    # copies is a rule that drifts. The advice about WHERE a bad name came from
    # stays here, because it is true of a rules-built name and not of a typed
    # one.
    #
    # AN EMPTY VALUE IS STILL SKIPPED HERE. Test-HDTComputerName refuses one,
    # which is right in front of a technician looking at an empty box; in a
    # sequence, a template that carries the token and a run that never set the
    # variable is a different failure and not this step's to report.
    if ($text -match '%HDTComputerName%') {
        $computerName = [string] $Context.Variable['HDTComputerName']

        if (-not [string]::IsNullOrWhiteSpace($computerName)) {
            $judgement = Test-HDTComputerName -Name $computerName

            if (-not $judgement.IsValid) {
                return (& $fail ("{0} Shorten HDTComputerName - a rule that builds it from a serial number is the usual cause." -f
                        $judgement.Reason) 'HDTConfigurationError')
            }

            # A WARNING IS NOT A REFUSAL. A name DNS cannot carry is still a
            # legal computer name, and refusing one here would stop a deployment
            # over something Windows itself permits. It is recorded instead, so
            # the machine that later has trouble joining a domain has a log line
            # that said so on the day it was built.
            if ($judgement.Severity -eq 'Warning') {
                Write-HDTLog -Context $Context.Log -Severity Warning -Component 'ApplyUnattend' `
                    -Message ([string] $judgement.Reason) `
                    -Data ([ordered] @{ computerName = $computerName; isDnsSafe = [bool] $judgement.IsDnsSafe })
            }
        }
    }

    $document = $text

    if ($expand) {
        $scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($Context.Variable.Keys)) { $scope[[string] $key] = $Context.Variable[$key] }

        # -- the one element that must not be left empty ----------------------
        #
        # MDT's ProductKey. Windows reads it in the specialize pass, and the
        # three things that can be in the element are not equally survivable:
        # a key works, NO ELEMENT works - it is how every KMS, MAK-by-script and
        # LTSC deployment has always run - and an EMPTY element fails the pass.
        # So does the literal '%HDTProductKey%', which is what leaving the token
        # unresolved would deploy.
        #
        # A machine nobody supplied a key for therefore gets no element, not an
        # empty one. That is the same outcome the template had before it carried
        # the token at all, which is the behaviour every existing share needs.
        #
        # ONLY THE ELEMENT HOLDING THE UNRESOLVED TOKEN IS REMOVED. A template
        # that hard-codes a real key and never mentions the variable is an
        # author's deliberate choice; stripping every ProductKey element would
        # silently deactivate a sequence that worked, and the machine would not
        # say so until somebody looked at its activation status weeks later.
        if ($text -match '%HDTProductKey%') {
            $productKey = ''
            if ($scope.Contains('HDTProductKey')) {
                $productKey = ([string] $scope['HDTProductKey']).Trim()
            }

            if ([string]::IsNullOrWhiteSpace($productKey)) {
                # The whole line first, so removing the element does not leave a
                # blank line where it was; then the bare element, for a template
                # that puts it inline with something else.
                $text = $text -replace '(?m)^[ 	]*<ProductKey>%HDTProductKey%</ProductKey>[ 	]*
?
?', ''
                $text = $text -replace '<ProductKey>%HDTProductKey%</ProductKey>', ''
            } else {
                # Trimmed, because a key arrives pasted out of a licensing
                # portal and the surrounding space goes into the XML otherwise.
                $scope['HDTProductKey'] = $productKey
            }
        }

        # ONE SOURCE, AND IT IS THE ADMINISTRATOR'S.
        if ($text -match '%HDTAdminPassword%') {
            $secret = [string] $scope['HDTAdminPassword']

            # NOTHING TO PUT IN IT IS A CONFIGURATION ERROR, NOT A PASSWORD TO
            # INVENT. Leaving the token unresolved would deploy a machine whose
            # local Administrator password is the literal '%HDTAdminPassword%',
            # identical on every machine ever built from this share; minting one
            # would deploy a machine nobody can log into, which is the failure
            # DESIGN 4.5.2 rejected randomisation over. Refusing names the fix.
            if ([string]::IsNullOrWhiteSpace($secret)) {
                return (& $fail ("step '{0}' stages an answer file that asks for %HDTAdminPassword%, but nothing supplies it. Set it in the fallback rule of rules.yaml (MDT's [Default] section), in Control\machines\<UUID>.yaml for this machine, or on the wizard's administrator password page." -f
                        $Step.Name) 'HDTConfigurationError')
            }

            $scope['HDTAdminPassword'] = $secret
        }

        # -- AN ANSWER FILE IS XML, AND A VARIABLE IS NOT --------------------
        #
        # EVERY value is escaped, HERE, in ONE place, immediately before it is
        # substituted. Not the password specially: every value, because the
        # alternative is a rule the next person to add a token has to know
        # about, and this document already lost that bet once.
        #
        # THE GUARANTEE THAT USED TO MAKE THIS SAFE IS GONE. There was a
        # New-HDTDeploymentPassword whose alphabet excluded < > & " ' and the
        # per cent sign ON PURPOSE, so a minted password went into the document
        # without escaping. DESIGN 4.5.2 settled the policy the other way - "the
        # administrator sets the password; HDT does not invent one" - and the
        # command was deleted, taking its alphabet with it while the unescaped
        # substitution stayed. Every password here is now a string a human typed
        # into the wizard or wrote into rules.yaml, and 'Pa&ss' is a legal
        # Windows password that produces an answer file Setup cannot parse -
        # twice over, because the secret appears under UserAccounts AND inside
        # AutoLogon.
        #
        # THE TEMPLATE ITSELF IS NEVER ESCAPED, only the values going into it.
        # Escaping the document would turn its own markup into text.
        #
        # ESCAPING IS NOT APPLIED TWICE. Each raw value is escaped exactly once
        # on its way into the scope, and Expand-HDTVariableToken reads the
        # already-escaped text when it recurses - so a value holding a token
        # composes correctly and an ampersand reaches disk as one entity. A
        # value with nothing special in it comes back unchanged, which is what
        # "do not double-escape something already safe" amounts to here: these
        # are TEXT values, not markup, so an author who pre-escaped one was
        # working around this bug and their value was already wrong.
        $escaped = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($key in @($scope.Keys)) {
            $raw = $scope[$key]

            # A $null MUST STAY $null. Expand-HDTVariableToken leaves a token
            # naming one literal and reports it as unresolved, and that is the
            # behaviour 02-03 asked for; an empty string here would silently
            # deploy a machine named 'PC-'.
            if ($null -eq $raw) {
                $escaped[[string] $key] = $null
                continue
            }

            # THE SHAPES Expand-HDTVariableToken RENDERS, rendered the same way -
            # by calling the same command, rather than by carrying a copy of it
            # that has to be kept in step by hand.
            $rendered = ConvertTo-HDTVariableText -Value $raw

            $escaped[[string] $key] = [System.Security.SecurityElement]::Escape($rendered)
        }

        # -- and the per cent sign, which XML escaping does not touch ---------
        #
        # THE TOKEN GRAMMAR IS PER CENT SIGNS, and a password is allowed to
        # contain them. Expansion RECURSES into a substituted value - that is
        # what makes 'PC-%HDTSitePrefix%' work - so a password containing
        # '%HDTComputerName%' would expand into the machine's name, and one
        # containing its own token name would raise a cycle error halfway
        # through a deployment. 'Pa%%w0rd' would quietly become 'Pa%w0rd', and
        # the machine would take a password nobody typed.
        #
        # DOUBLING THE PER CENT SIGNS MAKES THE VALUE LITERAL, because '%%' is
        # exactly how that grammar spells one per cent sign.
        #
        # ONLY THE PASSWORD, AND DELIBERATELY SO. Every other variable is
        # documented as recursively expandable and administrators rely on it -
        # 'PC-%HDTSerialNumber%' is the seeded example. A password is a literal
        # secret and was never meant to name anything.
        foreach ($literal in @('HDTAdminPassword')) {
            if ($escaped.Contains($literal) -and $null -ne $escaped[$literal]) {
                $escaped[$literal] = ([string] $escaped[$literal]).Replace('%', '%%')
            }
        }

        $unresolved = New-Object -TypeName System.Collections.ArrayList
        $document = Expand-HDTVariableToken -Value $text -Scope $escaped -Unresolved $unresolved -Path $templatePath

        if (@($unresolved).Count -gt 0) {
            Write-HDTLog -Context $Context.Log -Severity Warning -Component 'ApplyUnattend' `
                -Message ("{0} variable token(s) in the unattend were never supplied and are left unexpanded: {1}." -f
                    @($unresolved).Count, (@($unresolved) -join ', ')) `
                -Data ([ordered] @{ path = $unattendPath; unresolved = [string[]] @($unresolved) })
        }
    }

    # -- staging it -------------------------------------------------------

    try {
        $fileSystem.CreateDirectory($pantherPath)
        $fileSystem.WriteAllText($unattendPath, $document)
    } catch {
        return (& $fail ("the unattend could not be staged at {0}: {1}" -f $unattendPath, [string] $_.Exception.Message) '')
    }

    # -- and applying it, which staging alone does not do -------------------
    #
    # SETUP READING Panther ON FIRST BOOT RUNS specialize AND oobeSystem. It
    # does NOT run offlineServicing, and offlineServicing is where
    # Microsoft-Windows-PnpCustomizationsNonWinPE lives - the component whose
    # DriverPaths is the only thing telling Windows to install what ApplyDrivers
    # staged to <OSVolume>\Drivers. A document staged and never applied leaves
    # that declaration inert, which is exactly the state this toolkit shipped in
    # until this call existed: drivers copied onto a disk, nothing installing
    # them, and every step reporting Completed.
    #
    # BOTH AUTHORITIES MAKE THE CALL, at the same point and with the same
    # arguments - MDT LTIApply.wsf:1021-1043 shells
    # dism.exe /Image:<vol>\ /Apply-Unattend:<panther> /ScratchDir:<scratch>,
    # and PSD does it through Use-WindowsUnattend (PSDConfigure.ps1:151). See
    # NOTICE.md. THE DOCUMENT APPLIED IS THE STAGED ONE, not the template back
    # on the share: MDT's own comment says the answer file must be applied from
    # Panther so its image-root-relative \Drivers path resolves.
    #
    # ONLY WHEN THE DOCUMENT ACTUALLY DECLARES THAT PASS. A servicing session
    # costs seconds and takes an exclusive lock on the applied OS, and an answer
    # file with no offlineServicing settings - the S7 capture is one - has
    # nothing for it to do. This is the precise condition under which the call
    # changes anything, so it is the condition it is made under.
    # READ OFF THE DOCUMENT THAT WAS ACTUALLY STAGED, as XML rather than by
    # looking for a string: 'offlineServicing' appears in the shipped template's
    # own comments, and a comment is not a pass.
    #
    # A DOCUMENT THAT WILL NOT PARSE IS NOT THIS STEP'S FAILURE TO REPORT. It is
    # staged already, and Setup refusing it is a different and louder event than
    # a servicing session that was skipped; saying so at Warning is what lets
    # somebody find it without turning a pre-existing template into a new
    # refusal here.
    $declaresOfflineServicing = $false

    try {
        $parsed = New-Object -TypeName System.Xml.XmlDocument
        $parsed.LoadXml($document)

        foreach ($settings in @($parsed.DocumentElement.ChildNodes)) {
            if ($settings.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($settings.LocalName -ne 'settings') { continue }
            if ([string] $settings.GetAttribute('pass') -ne 'offlineServicing') { continue }

            $declaresOfflineServicing = $true
        }
    } catch {
        Write-HDTLog -Context $Context.Log -Severity Warning -Component 'ApplyUnattend' `
            -Message ("the staged unattend at {0} could not be parsed as XML, so its offlineServicing pass could not be applied: {1}" -f
                $unattendPath, [string] $_.Exception.Message) `
            -Data ([ordered] @{ path = $unattendPath })
    }

    if ($declaresOfflineServicing) {
        try {
            $image = $Context.Service.GetRequired('Image', 'ApplyUnattend')
        } catch {
            return (& $fail ([string] $_.Exception.Message) '')
        }

        # THE IMAGE ROOT IS THE OS VOLUME, trailing separator and all: dism's
        # /Image: wants the root of the offline installation.
        $imageRoot = '{0}:\' -f $volume

        # OFF THE RAM DISK. WinPE runs from X:, and DISM left to itself expands
        # into TEMP there and runs out of room on a driver package of any size.
        # MDT creates <LocalRootPath>\Scratch on the local disk for exactly this.
        $scratchPath = '{0}:\HDT\Scratch' -f $volume

        # -- the only number that moves for the next three minutes ------------
        #
        # MEASURED, ON THE MACHINE THAT SURFACED IT. LT-7FJ45S2,
        # run-20260829-172208: step 7, Apply Windows Settings, held the progress
        # card motionless for over three minutes. It was working - that was the
        # first image with the driver-ordering fix, so this call was genuinely
        # running offlineServicing over 133 .inf packages instead of scanning an
        # empty folder - but the step said nothing between its start and its
        # end. A working machine and a hung one looked identical, and the card's
        # elapsed clock, derived from the first and last record in the log,
        # stopped with it.
        #
        # STILL NO SECOND CHANNEL (DESIGN 11.1). This writes a record to the
        # JSONL and asks the display to re-read it, exactly as the step loop
        # does between steps. The screen and the log cannot disagree because
        # they are the same facts.
        #
        # EVERY FIVE POINTS, AND ALWAYS AT A HUNDRED - ApplyImage's stride, and
        # for its reasons: dism prints about a hundred meter lines, five is the
        # granularity a bar on a wall is read at, and the last thing the log
        # says about a pass should be that it finished.
        $progressState = @{ Percent = 0 }

        # RESOLVED HERE AND CAPTURED, NOT LOOKED UP IN THE CALLBACK. The
        # callback is invoked from inside the image service, and the fake is a
        # PowerShell CLASS in HDTFakes - a scriptblock invoked from a class
        # method resolves its commands in THAT module, where these private
        # functions do not exist. The identical trap is documented at length on
        # Invoke-HDTApplyImageStep; a CommandInfo invoked with & does not care
        # whose scope it is called from.
        $parseProgress = Get-Command -Name 'ConvertFrom-HDTDismProgressLine'
        $writeLog = Get-Command -Name 'Write-HDTLog'
        $updateDisplay = Get-Command -Name 'Update-HDTProgressDisplay'

        # NO New-HDTStepHeartbeat HERE, FOR THE REASON SET OUT ON ApplyImage.
        # The heartbeat is for a step that BLOCKS with nothing to report, and it
        # fires from IProcessService.Start's poll loop. This pass streams a meter
        # and reports it, which is a better fact than "still running"; a
        # heartbeat hung off this callback could only fire when dism speaks -
        # which is when the meter already has.
        #
        # THE 03:04:41 TO 03:08:02 SILENCE ON LT-7FJ45S2 run-20260829-190105 WAS
        # THIS PASS WITH NO METER WIRED AT ALL, and the wiring below is what
        # closes it. A dism that goes silent mid-pass would still freeze the
        # screen, and closing THAT means running dism as a polled process rather
        # than a pipeline - MDT's WshShell.Exec loop. Not done here.
        $onOutput = {
            param([string] $Line)

            # A BAR DOES NOT GET TO FAIL A DEPLOYMENT. This runs inside the
            # servicing pass, on a machine part-way through building a computer;
            # a log write that lost its RAM disk or a display whose runspace has
            # died is not a reason to stop.
            try {
                $percent = & $parseProgress -Line $Line
                if ($null -eq $percent) { return }

                $reported = [int] $progressState['Percent']
                if ([int] $percent -le $reported) { return }
                if ([int] $percent -lt ($reported + 5) -and [int] $percent -lt 100) { return }

                $progressState['Percent'] = [int] $percent

                & $writeLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyUnattend' `
                    -Message ('applying the answer file to {0}, which installs the staged drivers: {1}%' -f
                        $imageRoot, [int] $percent) `
                    -Data ([ordered] @{
                        imageRoot = $imageRoot
                        path      = $unattendPath
                        percent   = [int] $percent
                    })

                & $updateDisplay -Context $Context
            } catch {
                # Kept where a debugger can reach it rather than thrown away: an
                # empty catch is how a percentage that never appeared stays a
                # mystery.
                $progressState['Error'] = [string] $_.Exception.Message
            }
        }.GetNewClosure()

        try {
            $image.ApplyUnattend($imageRoot, $unattendPath, $scratchPath, $onOutput)
        } catch {
            # NOT SWALLOWED, AND NOT DOWNGRADED TO A WARNING. The staging
            # succeeded, so everything upstream looks green; if this failure did
            # not stop the run, the deployment would finish and hand over a
            # machine with no drivers and a log that said so nowhere.
            return (& $fail ("the unattend was staged at {0} but could not be applied to the offline image at {1}: {2}" -f
                    $unattendPath, $imageRoot, [string] $_.Exception.Message) '')
        }

        Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'ApplyUnattend' `
            -Message ('applied the unattend to the offline image at {0}, which runs its offlineServicing pass.' -f $imageRoot) `
            -Data ([ordered] @{ imageRoot = $imageRoot; path = $unattendPath; scratch = $scratchPath })
    }

    $Context.Variable['HDTUnattendPath'] = $unattendPath

    # THE PATH AND THE BYTE COUNT, AND NOTHING ELSE. The document carries the
    # local Administrator password of the machine being built, twice.
    $byteCount = [long] [System.Text.Encoding]::UTF8.GetByteCount($document)

    $message = 'staged the unattend at {0} ({1} bytes).' -f $unattendPath, $byteCount

    Write-HDTLog -Context $Context.Log -Message $message -Component 'ApplyUnattend' `
        -Data ([ordered] @{ path = $unattendPath; byteCount = $byteCount; template = $templatePath })

    return (New-HDTStepResult -Status Completed -Message $message `
            -Data ([ordered] @{ path = $unattendPath; byteCount = $byteCount; template = $templatePath }))
}
