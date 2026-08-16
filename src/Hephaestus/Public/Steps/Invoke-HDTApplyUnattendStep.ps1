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

            THE PASSWORD HAS THREE SOURCES AND NO FOURTH OUTCOME:

              1. an HDTAdminPassword variable the rules resolved - used;
              2. otherwise $Context.State.deploymentPassword, when the state
                 carries one (the oobeSystem AutoLogon block is
                 what arms the first logon);
              3. otherwise ONE IS MINTED, written back to
                 $Context.State.deploymentPassword and used.

            STEP 3 IS NOT TIDINESS - IT IS THE REASON THIS STEP IS SAFE TO RUN.
            Invoke-HDTTaskSequence mints the deployment password only when a step
            returns RebootRequested, and a WinPE-half sequence such as DEMO-M3
            has no Restart step. Without step 3 the token stays unresolved,
            Expand-HDTVariableToken leaves it literal, and HDT deploys a machine
            whose local Administrator password is the string
            '%HDTAdminPassword%' - identical on every machine it ever builds.
            That is worse than a failed step, and it would have shipped green.
            Writing it back to the state is what makes a later Restart arm
            autologon with the SAME secret: one machine, one secret per run.

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
            Invoke-HDTApplyUnattendStep -Step $step -Context $context
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

        # The three sources, in order, and there is no fourth outcome.
        if ($text -match '%HDTAdminPassword%') {
            $secret = [string] $scope['HDTAdminPassword']

            if ([string]::IsNullOrEmpty($secret) -and $null -ne $Context.State -and
                $null -ne $Context.State.PSObject.Properties['deploymentPassword']) {

                $secret = [string] $Context.State.deploymentPassword
            }

            if ([string]::IsNullOrEmpty($secret)) {
                $secret = New-HDTDeploymentPassword

                Write-HDTLog -Context $Context.Log -Component 'ApplyUnattend' `
                    -Message 'this run had no deployment password, so one was generated for the unattend and recorded in the run state.'
            }

            if ($null -ne $Context.State -and $null -ne $Context.State.PSObject.Properties['deploymentPassword'] -and
                [string]::IsNullOrEmpty([string] $Context.State.deploymentPassword)) {

                # One machine, one secret per run: a later Restart arms autologon
                # with this one rather than making a second.
                $Context.State.deploymentPassword = $secret
            }

            $scope['HDTAdminPassword'] = $secret
        }

        $unresolved = New-Object -TypeName System.Collections.ArrayList
        $document = Expand-HDTVariableToken -Value $text -Scope $scope -Unresolved $unresolved -Path $templatePath

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
