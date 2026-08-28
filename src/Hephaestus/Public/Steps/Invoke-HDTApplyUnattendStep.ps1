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
                $text = $text -replace '(?m)^[ 	]*<ProductKey>%HDTProductKey%</ProductKey>[ 	]*?
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
