function Invoke-HDTGatherStep {
    <#
        .SYNOPSIS
            Re-reads the machine's facts into the sequence's variables.

        .DESCRIPTION
            Reads the machine's own facts - its hardware, its firmware, its
            SecureBoot state - and writes them back into the sequence's
            variables part way through a run, because the machine a sequence
            finishes on is not the machine it started on.

            WHY IT IS A STEP AND NOT ONLY ENGINE START-UP. HDT gathers once
            before the sequence begins, and DESIGN 3.2.1 already says the facts
            are "refreshed after OS apply". Making the refresh a step is what
            lets a sequence SAY WHERE it happens, in a file an administrator
            reads, instead of it being a rule inside the engine that nothing on
            screen mentions.

            IT IS NOT A RESET. Only the facts it gathers are replaced;
            HDTComputerName from rules.yaml, a variable a SetVariable step
            wrote, a drive letter a partition step published - none of them are
            touched. A gather that cleared what it did not produce would throw
            away the deployment's own decisions half way through.

            AND AN EMPTY ANSWER IS NOT A FACT IT GATHERED. That promise had a
            hole in it for as long as the step existed: a fact the machine could
            not determine came back as an empty string, which is still a value,
            and the step wrote it over whatever was there. On
            LT-7FJ45S2-run-20260829-190105 it replaced HDTAssetTag -
            'ASSET-7FJ45S2', set by a rule script and recorded as such in
            Gather\provenance.json - with the empty string SMBIOS reports on that
            Dell, and logged it as "HDTAssetTag: ASSET-7FJ45S2 -> ": an arrow
            pointing at nothing. Every step after it ran with an empty asset tag.

            Get-HDTMachineFact's -Provenance bag is what closes it. A fact
            carries whether the machine DETERMINED it, so this step can decline
            to erase a resolved value with a non-answer - and say in the log that
            it did, because a step that quietly does nothing is as hard to
            diagnose as one that quietly does the wrong thing.

            THE RULE IS "DO NOT ERASE", NOT "DO NOT WRITE". A machine with no
            asset tag and no rule setting one still ends up with the variable
            defined, or every condition reading it throws instead of being false.

            WHAT IT COULD NOT DETERMINE IS NAMED, WITH THE REASON. Until now an
            empty fact was invisible - simply absent from the log - so nothing
            distinguished "this machine has no TPM" from "the query failed" from
            "the property was blank", and a rule keyed on HDTSystemSKU that
            silently never matched had no explanation anywhere.

            IT REFUSES WITHOUT A CIM PROVIDER rather than gathering nothing and
            reporting success. A green step that quietly gathered nothing leaves
            every later condition false and every later check unmade, which is
            the most expensive way for this to fail.

            IT TOUCHES NO HARDWARE ITSELF. Get-HDTMachineFact takes the injected
            ICimProvider, so this runs under Pester against a fake like every
            other step here.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            The execution context, carrying the service catalog and the live
            variables.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - a step result.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Gather' })[0]

            Invoke-HDTGatherStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $before = @($context.Variable.Keys).Count
            $null = Invoke-HDTGatherStep -Step $step -Context $context
            @($context.Variable.Keys).Count - $before

            How many facts the gather added to the sequence's variables.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Step',
        Justification = 'The step contract requires -Step on every step command. A Gather step declares no properties - what to gather is not a choice - so the parameter is bound and unread, which is the contract being honoured rather than an oversight.')]
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

    # THREE PORTS, BECAUSE THE FACTS COME FROM THREE PLACES. CIM for the
    # hardware, the registry for SecureBoot, and the environment for the
    # firmware type - all injected, none of them touched directly here.
    $cim = $null
    $registry = $null
    $environment = $null

    try {
        $cim = $Context.Service.GetRequired('Cim', 'Gather')
        $registry = $Context.Service.GetRequired('Registry', 'Gather')
        $environment = $Context.Service.GetRequired('Environment', 'Gather')
    } catch {
        $message = 'this step gathers the machine facts and a service it needs was not supplied, so there is nothing to gather them with: {0}' -f $_.Exception.Message

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'Gather'

        return (New-HDTStepResult -Status Failed -Message $message `
                -Data ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    # WHICH MODE, SAID AS A FACT RATHER THAN LEFT TO THE STEP'S NAME. "Gather
    # local only" is what somebody called the step; whether a database was
    # consulted is a property of the engine, and people trip on MDT's
    # local/database distinction constantly - ZTIGather takes a /localonly switch
    # and behaves very differently with and without it.
    #
    # HDT HAS NO DATABASE SOURCE AT ALL. DESIGN 3.1's five prioritised sources
    # are the command line, the wizard, a machine override, the rules and the
    # sequence defaults; Add-HDTResolvedVariable's own ValidateSet is the list,
    # and there is no MDT-style SQL settings database among them. So every gather
    # is a local gather, and saying so once is cheaper than an administrator
    # looking for the switch that turns the other one on.
    Write-HDTLog -Context $Context.Log -Event message -Component 'Gather' -Severity Info `
        -Message 'gathering this machine''s own facts; HDT has no settings database, so every gather is a local one.'

    # THE SIDE CHANNEL, AND THE REASON THIS STEP CAN NOW TELL AN ANSWER FROM A
    # NON-ANSWER. Get-HDTMachineFact fills it in with, per fact, the source and
    # property it came from and whether the machine actually determined it.
    $provenance = [ordered] @{}

    try {
        $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $registry -EnvironmentProvider $environment `
            -Provenance $provenance -Clock $Context.Service.Clock
    } catch {
        $message = [string] $_.Exception.Message

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'Gather'

        return (New-HDTStepResult -Status Failed -Message $message `
                -Data ([ordered] @{ errorId = 'HDTGatherFailed' }))
    }

    $written = 0
    $changed = New-Object -TypeName System.Collections.ArrayList
    $kept = New-Object -TypeName System.Collections.ArrayList
    $undetermined = New-Object -TypeName System.Collections.ArrayList

    foreach ($name in @($fact.Keys)) {
        $before = $null
        if ($Context.Variable.Contains($name)) { $before = $Context.Variable[$name] }

        # -- did the machine actually answer this one? --------------------
        #
        # A fact assembled without provenance is treated as determined, because
        # the only thing worse than overwriting a good value is refusing to write
        # a real one.
        $determined = $true
        $why = ''

        if ($provenance.Contains($name)) {
            $determined = [bool] $provenance[$name].Determined
            $why = [string] $provenance[$name].Reason
        }

        # -- AND THE DEFECT THIS FIXES ------------------------------------
        #
        # A GATHERED FACT THE MACHINE COULD NOT DETERMINE MUST NOT ERASE A VALUE
        # SOMETHING ELSE RESOLVED. On LT-7FJ45S2-run-20260829-190105 this step
        # overwrote HDTAssetTag - set to 'ASSET-7FJ45S2' by a rule script, and
        # recorded as such in Gather\provenance.json - with the empty string
        # SMBIOS reports on that Dell, and logged it as "HDTAssetTag:
        # ASSET-7FJ45S2 -> " with nothing after the arrow. Every step after it
        # ran with an empty asset tag.
        #
        # THE STEP'S OWN HELP ALREADY PROMISED THIS: "IT IS NOT A RESET. Only the
        # facts it gathers are replaced." An empty answer is not a fact it
        # gathered; it is the absence of one, and the code had no way to tell the
        # two apart until the provenance bag existed.
        #
        # THE RULE IS "DO NOT ERASE", NOT "DO NOT WRITE". A machine with no asset
        # tag and no rule setting one must still end up with the variable
        # defined, or every condition reading it throws instead of being false -
        # so this only declines when there is something to lose.
        # RENDERED ONCE, BEFORE THE DECISION AND BEFORE THE WRITE. A [string] cast
        # SPACE-joins a list and a -f argument NESTS one, so the text that
        # decides "this would lose something" has to be the same text that says
        # what it changed to. Both the keep decision and the change line below
        # read these two.
        $beforeText = ConvertTo-HDTVariableText -Value $before
        $afterText = ConvertTo-HDTVariableText -Value $fact[$name]

        $hadValue = (-not [string]::IsNullOrEmpty($beforeText))

        # ONLY WHEN SOMETHING WOULD ACTUALLY BE LOST, and the third clause is
        # not a micro-optimisation - without it this step lies. HDTIsUEFI on a
        # machine with no firmware_type is undetermined and renders as 'False',
        # so the FIRST gather writes False and every gather after it finds a
        # non-empty previous value and announces that it "kept the resolved
        # value" - when the value it kept was the one this same step wrote a
        # moment earlier, resolved by nobody. Comparing the two renderings means
        # a fact that has not moved is written silently, and only a real loss -
        # 'ASSET-7FJ45S2' about to become '' - is declined and reported.
        #
        # AND IT STILL CATCHES THE CASE THAT MATTERS MOST: a rule that set
        # HDTIsUEFI to True against a gather that cannot tell is a genuine
        # disagreement, the renderings differ, and the rule wins.
        if ((-not $determined) -and $hadValue -and $beforeText -ne $afterText) {
            [void] $kept.Add(('{0}: kept the resolved value; the machine could not determine it ({1})' -f $name, $why))
            continue
        }

        if (-not $determined) {
            [void] $undetermined.Add([pscustomobject] @{
                    Name   = [string] $name
                    Reason = [string] $why
                    Source = [string] $(if ($provenance.Contains($name)) { $provenance[$name].Source } else { '' })
                    Value  = $fact[$name]
                })
        }

        $Context.Variable[$name] = $fact[$name]
        $written++

        # WHAT MOVED IS WORTH A LINE IN THE LOG. On the second gather of a
        # deployment that is the whole reason the step ran, and on the first it
        # is empty - which is also the right answer.
        #
        # $beforeText and $afterText were rendered above, before the keep
        # decision, because that decision compares the same two strings this
        # line prints - see the note there. Rendering them twice is how the two
        # would drift apart.

        if ($beforeText -ne $afterText) {
            # THE COMPARISON USES THE REAL TEXT AND THE LINE DOES NOT.
            # Comparing redactions would make two different secrets look
            # identical and report no change; a machine fact is not normally a
            # secret, but a rule may have put one into the same bag under a name
            # that is, and this line is written into HDT.log on the share.
            $beforeShown = ConvertTo-HDTVariableText -Value (Protect-HDTSecretValue -Name $name -Value $before)
            $afterShown = ConvertTo-HDTVariableText -Value (Protect-HDTSecretValue -Name $name -Value $fact[$name])

            # AN EMPTY SIDE IS SAID, NOT LEFT BLANK. A real run logged
            # "HDTAssetTag: ASSET-7FJ45S2 -> " with nothing after the arrow, and
            # the one line describing the one thing that changed was unreadable:
            # nothing on the page said whether the new value was empty, whether
            # the rendering had failed, or which side of the arrow was which.
            #
            # The arrow reads OLD -> NEW and that direction is correct: what the
            # line was reporting is a gathered fact arriving EMPTY and
            # overwriting a value a rule script had supplied. The "do not erase"
            # guard above stops that happening at all now, so this line should
            # no longer have an empty right-hand side for that reason - but a
            # fact can legitimately move from nothing to something, and a blank
            # LEFT-hand side is just as unreadable. Both sides say "(empty)".
            if ([string]::IsNullOrEmpty($beforeShown)) { $beforeShown = '(empty)' }
            if ([string]::IsNullOrEmpty($afterShown)) { $afterShown = '(empty)' }

            # AND WHO CHANGED IT. "HDTMake: Dell -> LENOVO" names the two values
            # and leaves the reader to guess what moved them; naming the source
            # is the difference between editing rules.yaml and hunting a CIM
            # property. The gather is what changed it, so the useful half is
            # WHICH source of the gather's own the new value came from.
            $by = ''
            if ($provenance.Contains($name)) {
                $by = ', from {0}.{1}' -f $provenance[$name].Source, $provenance[$name].Property
            }

            [void] $changed.Add(('{0}: {1} -> {2}{3}' -f $name, $beforeShown, $afterShown, $by))
        }
    }

    foreach ($line in $changed) {
        Write-HDTLog -Context $Context.Log -Message $line -Severity Debug -Event var.resolve -Component 'Gather'
    }

    # WHAT IT DECLINED TO OVERWRITE. A step that quietly does nothing is as hard
    # to diagnose as one that quietly does the wrong thing.
    foreach ($line in $kept) {
        Write-HDTLog -Context $Context.Log -Message $line -Severity Debug -Event var.resolve -Component 'Gather'
    }

    # -- where every fact came from, and what it cost ---------------------
    #
    # GROUPED BY SOURCE, because that is how the cost falls: one slow CIM class
    # is what makes a gather take four seconds, and a per-FACT list of twenty
    # lines hides which of the seven queries it was.
    $bySource = @{}
    foreach ($name in @($provenance.Keys)) {
        $source = [string] $provenance[$name].Source
        if (-not $bySource.ContainsKey($source)) {
            $bySource[$source] = New-Object -TypeName System.Collections.ArrayList
        }
        [void] $bySource[$source].Add([string] $name)
    }

    # NOT var.resolve, AND THE DISTINCTION IS NOT PEDANTRY. A var.resolve record
    # means "this variable took this value", and three commands already write
    # them in three shapes - Write-HDTVariableLog as "HDTModel = 'x' (Rule)" at
    # Debug, Invoke-HDTSetVariableStep at Info, and the change line below as
    # "HDTModel: old -> new". A per-source TIMING line is not a variable
    # resolution in any shape; filed under the same name it would be a fourth
    # format for a consumer filtering on that event to trip over, and it made a
    # second gather emit twelve records where the log's own test expected none.
    #
    # NAMES AND TIMINGS ONLY, NEVER VALUES, so there is nothing here to redact -
    # the one line in this step that carries a value is the change line, and it
    # goes through Protect-HDTSecretValue.
    foreach ($source in @($bySource.Keys | Sort-Object)) {
        $millisecond = 0
        foreach ($name in @($bySource[$source])) { $millisecond = [long] $provenance[$name].ElapsedMs }

        Write-HDTLog -Context $Context.Log -Severity Debug -Event message -Component 'Gather' `
            -Message ('{0,-34} {1} in {2} ms' -f $source, (@($bySource[$source]) -join ', '), $millisecond) `
            -Data ([ordered] @{ source = [string] $source; elapsedMs = [long] $millisecond })
    }

    # THE LIST THAT DID NOT EXIST, AND THE MOST VALUABLE THING HERE. A fact that
    # comes back empty is invisible today: it is simply absent from the log, and
    # nothing distinguishes "this machine has no TPM" from "the query failed"
    # from "the property was blank". A rule keyed on HDTSystemSKU that silently
    # never matches had no explanation anywhere.
    #
    # ONE RECORD PER FACT, SHAPED LIKE THE CHANGE LINES BESIDE IT rather than one
    # record carrying a newline-delimited block. A multi-line message is
    # unreadable in CMTrace, unfilterable, and cannot carry per-fact data.
    #
    # AND THE VALUE GOES THROUGH Protect-HDTSecretValue. A machine fact is not
    # normally a secret, but this bag is the same one a rule may have written
    # HDTAdminPassword into under a name that is - and this line is written into
    # HDT.log, which SLShare copies to the share. Whether a name is a secret is
    # Protect-HDTSecretValue's decision, never this step's; a second opinion here
    # is exactly how the log and Gather\provenance.json came to disagree before.
    foreach ($entry in $undetermined) {
        $shown = ConvertTo-HDTVariableText -Value (Protect-HDTSecretValue -Name $entry.Name -Value $entry.Value)
        if ([string]::IsNullOrEmpty($shown)) { $shown = '(empty)' }

        Write-HDTLog -Context $Context.Log -Severity Debug -Event var.resolve -Component 'Gather' `
            -Message ('{0}: could not be determined ({1}); left as {2}' -f $entry.Name, $entry.Reason, $shown) `
            -Data ([ordered] @{
                name       = [string] $entry.Name
                source     = [string] $entry.Source
                determined = $false
            })
    }

    # -- the one line an Info run gets ------------------------------------
    #
    # "20 machine facts gathered, 0 changed." LEFT A READER UNSURE WHETHER THE
    # STEP DID ANYTHING. The facts were already gathered during bootstrap - the
    # same run resolves every GatheredFact before the sequence starts - so this
    # step re-gathers and COMPARES, and "nothing moved" is the expected, healthy
    # answer. It should read like one.
    $totalMillisecond = 0
    foreach ($name in @($provenance.Keys)) { $totalMillisecond += [long] $provenance[$name].ElapsedMs }

    $changedText = 'none changed since bootstrap'
    if (@($changed).Count -gt 0) { $changedText = '{0} changed' -f @($changed).Count }

    $message = '{0} facts from {1} source(s) in {2} ms; {3}' -f
        $written, @($bySource.Keys).Count, $totalMillisecond, $changedText

    if (@($undetermined).Count -gt 0) {
        $message = '{0}; {1} could not be determined' -f $message, @($undetermined).Count
    }

    if (@($kept).Count -gt 0) {
        $message = '{0}; {1} resolved value(s) kept rather than overwritten by a fact the machine could not determine' -f
            $message, @($kept).Count
    }

    $message = '{0}.' -f $message

    Write-HDTLog -Context $Context.Log -Message $message -Severity Info -Event step.complete -Component 'Gather'

    return (New-HDTStepResult -Status Completed -Message $message `
            -Data ([ordered] @{
                gathered     = $written
                changed      = @($changed).Count
                sources      = @($bySource.Keys).Count
                undetermined = @($undetermined).Count
                kept         = @($kept).Count
                elapsedMs    = [long] $totalMillisecond
            }))
}
