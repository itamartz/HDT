# DESIGN 4.5.2's SECRET BAG: "The durable answer is an LSA-carried secret bag
# written alongside each checkpoint, which is the same mechanism this section
# already chose for the autologon password."
#
# THE SYMPTOM IT EXISTS FOR, NAMED IN THE DESIGN AND DATED THERE. Save-HDTRunState
# redacts every secret on the way into state.json - because that file is copied
# to the deployment share and moved to C:\Windows\Logs\HDT on the deployed
# machine - and the leg after a restart rehydrates its whole variable bag from
# that file. So a JoinDomain step in State Restore, which is where DESIGN 4.1 and
# MDT both put it, was handed the literal '(set, not shown)' and REFUSED: trying
# it is one wrong-password attempt per machine against the one account that can
# join anything to the directory.
#
# THE TWO PROPERTIES THIS FILE IS FOR, AND THEY PULL AGAINST EACH OTHER:
#
#   1. the value SURVIVES the reboot, and
#   2. the value is in NOTHING the run writes down - not state.json, not
#      HDT.jsonl, not the CMTrace log, not a recorded service operation, at any
#      log level.
#
# A test for either one alone is passed by a defect. Storing the password in
# state.json satisfies 1; never storing it anywhere satisfies 2. Every Context
# below asserts both over the same run.
#
# THE VALUES ARE SYNTHETIC MARKERS ON PURPOSE. Nothing here looks like a
# password, because a fixture that does is a credential as far as the next person
# grepping this repository is concerned - the same rule
# SecretRedaction.Contract.Tests.ps1 already writes down.
#
# THE THREE COMMANDS ARE PRIVATE. Every caller of them is another file in this
# module - Invoke-HDTTaskSequence at each checkpoint and before each restart,
# Clear-HDTAutoLogon from the teardown checklist - and each one takes an
# ILsaService, which nothing outside the module builds. So they are not in
# FunctionsToExport, and tests/contract/ExportedCommandReach.Contract.Tests.ps1
# is what says an export needs a reader outside the module.
#
# WHICH MOVES THE CALL AND NOTHING ELSE. The fakes, the markers, the sequence
# legs and every assertion below are unchanged; the three scriptblocks in
# BeforeAll are the only new thing, and all they do is enter the module's own
# session state the way the Assert-HDT*Document tests already do. Assert on what
# the command DID, not on where the call was made from.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:module = Get-Module -Name 'Hephaestus'

    # THE REDACTION'S WORDING FROM THE ONE PLACE THAT DEFINES IT. A literal here
    # would go on passing after somebody changed the marker, which is the failure
    # Invoke-HDTJoinDomainStep already guards against the same way.
    $script:redaction = [string] (& $script:module {
            Protect-HDTSecretValue -Name 'HDTAdminPassword' -Value 'not the real value'
        })

    $script:bagYaml = Get-Content -LiteralPath (
        Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/sequences/valid-secret-bag-legs.yaml') -Raw

    # Distinct per variable, so a leak of one cannot be mistaken for a leak of
    # another - and neither can a bag that carried the wrong entry.
    $script:joinMarker = 'MARKER-JOIN-9d41c07a'
    $script:adminMarker = 'MARKER-ADMIN-4b7fe215'

    $script:newBag = {
        param([hashtable] $Entry)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($Entry.Keys)) { $bag[[string] $name] = $Entry[$name] }
        return $bag
    }

    # THE CALL, AND ONLY THE CALL, INSIDE THE MODULE. One harness per command
    # rather than an InModuleScope wrapped around each It: a fake built inside
    # the module and asserted outside it would be two objects to keep track of,
    # and the point of these tests is what the LSA service was handed. The fakes
    # are built out here, passed in by reference - InModuleScope runs in this
    # process, so nothing is copied - and the return value comes back out.
    $script:save = {
        param([object] $Lsa, [object] $Variable, [object] $LogContext)

        InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Lsa = $Lsa; Variable = $Variable; LogContext = $LogContext } {
            param($Lsa, $Variable, $LogContext)

            $argument = @{ Lsa = $Lsa; Variable = $Variable }
            if ($null -ne $LogContext) { $argument['LogContext'] = $LogContext }

            Save-HDTSecretBag @argument
        }
    }

    $script:restore = {
        param([object] $Lsa, [object] $Variable, [object] $LogContext)

        InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Lsa = $Lsa; Variable = $Variable; LogContext = $LogContext } {
            param($Lsa, $Variable, $LogContext)

            $argument = @{ Lsa = $Lsa; Variable = $Variable }
            if ($null -ne $LogContext) { $argument['LogContext'] = $LogContext }

            Restore-HDTSecretBag @argument
        }
    }

    $script:clear = {
        param([object] $Lsa, [object] $LogContext)

        InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Lsa = $Lsa; LogContext = $LogContext } {
            param($Lsa, $LogContext)

            $argument = @{ Lsa = $Lsa }
            if ($null -ne $LogContext) { $argument['LogContext'] = $LogContext }

            Clear-HDTSecretBag @argument
        }
    }

    # One leg of the two-leg sequence, over a SHARED filesystem, LSA and domain
    # service - because a machine keeps its disk, its LSA secrets and its
    # membership across a restart, and a fresh service per leg would model a
    # machine that forgot all three.
    $script:runLeg = {
        param([object] $FileSystem, [string] $StateJson, [string] $Phase, [object] $Lsa, [object] $Domain, [hashtable] $Variable)

        $argument = @{
            Yaml       = $script:bagYaml
            Phase      = $Phase
            FileSystem = $FileSystem
            Lsa        = $Lsa
            Domain     = $Domain
        }
        if (-not [string]::IsNullOrEmpty($StateJson)) { $argument['StateJson'] = $StateJson }
        if ($null -ne $Variable) { $argument['Variable'] = $Variable }

        $harness = New-HDTSequenceTestHarness @argument

        # What Invoke-HDTBootReconciliation does before handing the state over.
        if (-not [string]::IsNullOrEmpty($StateJson)) {
            $harness.State.leg = [int] $harness.State.leg + 1
        }

        $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

        return [pscustomobject] @{
            Harness   = $harness
            Result    = $result
            StateJson = $harness.FileSystem.ReadAllText($harness.StatePath)
        }
    }
}

Describe 'Save-HDTSecretBag' {

    It 'carries the secrets and leaves everything else out' {
        $lsa = New-HDTFakeLsaService
        $bag = & $script:newBag @{
            HDTComputerName        = 'HDT-LAB-01'
            HDTAdminPassword       = $script:adminMarker
            HDTDomainAdminPassword = $script:joinMarker
        }

        $carried = @(& $script:save -Lsa $lsa -Variable $bag)

        # Sorted, because the assertion is about the SET the classifier chose and
        # not about the order a dictionary happened to enumerate in.
        @($carried | Sort-Object) | Should -Be @('HDTAdminPassword', 'HDTDomainAdminPassword')

        $stored = [string] $lsa.GetSecret('HDTSecretBag')
        $stored | Should -Not -BeNullOrEmpty
        $stored | Should -BeLike ('*{0}*' -f $script:joinMarker)
        $stored | Should -Not -BeLike '*HDT-LAB-01*'
    }

    It 'writes no bag at all when the variables hold no secret' {
        # NOT AN EMPTY BAG, AND THE DIFFERENCE MATTERS. Every checkpoint of every
        # run calls this; a run with nothing to carry must touch LSA zero times,
        # or the engine writes an LSA secret per step on machines that need none.
        $lsa = New-HDTFakeLsaService
        $bag = & $script:newBag @{ HDTComputerName = 'HDT-LAB-01' }

        @(& $script:save -Lsa $lsa -Variable $bag) | Should -BeNullOrEmpty
        @($lsa.GetOperationName()) | Should -BeNullOrEmpty
    }

    It 'never overwrites a stored value with the redaction that replaced it' {
        # THE DEFECT THIS CATCHES IS THE ONE THAT WOULD MAKE THE WHOLE FEATURE
        # LOOK LIKE IT WORKED. A leg that rehydrates from state.json holds
        # '(set, not shown)' until Restore-HDTSecretBag runs; a checkpoint taken
        # before that - or after a step cleared the value - would otherwise
        # replace the real secret in LSA with the marker and lose it for good.
        $lsa = New-HDTFakeLsaService
        & $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        $carried = @(& $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:redaction }))

        $carried | Should -BeNullOrEmpty
        [string] $lsa.GetSecret('HDTSecretBag') | Should -BeLike ('*{0}*' -f $script:joinMarker)
    }

    It 'records the name and never the value' {
        $lsa = New-HDTFakeLsaService
        & $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        $recorded = ($lsa.Operations | ForEach-Object { @($_.Arguments) -join ' ' }) -join ' '

        $recorded | Should -BeLike '*HDTSecretBag*'
        $recorded | Should -Not -BeLike ('*{0}*' -f $script:joinMarker)
    }

    It 'logs the names it carried, their count and the secret it wrote, and never a value' {
        $fileSystem = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow ([datetime]'2026-09-07T00:00:00Z')
        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $fileSystem -Clock $clock -Level Debug

        & $script:save -Lsa (New-HDTFakeLsaService) -LogContext $log `
            -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        $written = ($fileSystem.File.Values -join "`n")

        $written | Should -BeLike '*HDTDomainAdminPassword*'
        $written | Should -Not -BeLike ('*{0}*' -f $script:joinMarker)
    }
}

Describe 'Restore-HDTSecretBag' {

    It 'puts the real value back where the checkpoint left a redaction' {
        $lsa = New-HDTFakeLsaService
        & $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        $resumed = & $script:newBag @{ HDTDomainAdminPassword = $script:redaction }

        @(& $script:restore -Lsa $lsa -Variable $resumed) | Should -Be @('HDTDomainAdminPassword')
        [string] $resumed['HDTDomainAdminPassword'] | Should -BeExactly $script:joinMarker
    }

    It 'restores a name the resumed leg does not have at all' {
        $lsa = New-HDTFakeLsaService
        & $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        $resumed = & $script:newBag @{ HDTComputerName = 'HDT-LAB-01' }

        @(& $script:restore -Lsa $lsa -Variable $resumed) | Should -Be @('HDTDomainAdminPassword')
        [string] $resumed['HDTDomainAdminPassword'] | Should -BeExactly $script:joinMarker
    }

    It 'leaves a value this leg actually has alone' {
        # THE LIVE LEG WINS. A rule, a wizard answer or a SetVariable step in
        # this leg is newer than the bag, and a restore that overruled it would
        # make the bag a source of truth it was never meant to be.
        $lsa = New-HDTFakeLsaService
        & $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        $live = & $script:newBag @{ HDTDomainAdminPassword = 'MARKER-FRESH-11a2b3c4' }

        @(& $script:restore -Lsa $lsa -Variable $live) | Should -BeNullOrEmpty
        [string] $live['HDTDomainAdminPassword'] | Should -BeExactly 'MARKER-FRESH-11a2b3c4'
    }

    It 'does nothing, and throws nothing, when there is no bag' {
        $bag = & $script:newBag @{ HDTComputerName = 'HDT-LAB-01' }

        @(& $script:restore -Lsa (New-HDTFakeLsaService) -Variable $bag) | Should -BeNullOrEmpty
        @($bag.Keys) | Should -Be @('HDTComputerName')
    }

    It 'survives a bag that is not readable rather than taking the run down' {
        # A MACHINE IN AN UNKNOWN STATE IS THE NORMAL CASE HERE. An LSA secret
        # left by an older engine, or a truncated one, must cost the run its
        # secrets and not its life - the step that needs one refuses with a
        # sentence an administrator can act on, which is a better outcome than a
        # sequence that dies at leg two with a JSON parse error.
        $lsa = New-HDTFakeLsaService -Secret @{ HDTSecretBag = 'not json at all' }
        $bag = & $script:newBag @{ HDTDomainAdminPassword = $script:redaction }

        { & $script:restore -Lsa $lsa -Variable $bag } | Should -Not -Throw
        [string] $bag['HDTDomainAdminPassword'] | Should -BeExactly $script:redaction
    }
}

Describe 'Clear-HDTSecretBag' {

    It 'removes the bag' {
        $lsa = New-HDTFakeLsaService
        & $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        & $script:clear -Lsa $lsa | Should -BeTrue
        $lsa.GetSecret('HDTSecretBag') | Should -BeNullOrEmpty
    }

    It 'is idempotent on a machine that never had one' {
        $lsa = New-HDTFakeLsaService

        & $script:clear -Lsa $lsa | Should -BeFalse
        { & $script:clear -Lsa $lsa } | Should -Not -Throw
    }
}

Describe 'the teardown checklist' {

    It 'clears the secret bag along with the autologon secret' {
        # DESIGN 4.5.4: teardown is a failsafe, not a step, and the bag is an
        # artifact of the same run - a machine left holding a domain credential
        # in LSA after its deployment finished is the thing 4.5.2 is careful
        # about.
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'MARKER-AUTOLOGON-6c0d' }
        & $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        $result = Clear-HDTAutoLogon -Registry (New-HDTFakeRegistryService) -Lsa $lsa

        $result.Cleared | Should -Contain 'LsaSecret:HDTSecretBag'
        $lsa.GetSecret('HDTSecretBag') | Should -BeNullOrEmpty
    }

    It 'clears the bag at the boot-time reconcile' {
        $lsa = New-HDTFakeLsaService
        & $script:save -Lsa $lsa -Variable (& $script:newBag @{ HDTDomainAdminPassword = $script:joinMarker }) | Out-Null

        $decision = Invoke-HDTBootReconciliation -StatePath 'C:\HDT\state.json' `
            -FileSystem (New-HDTFakeFileSystem) -Registry (New-HDTFakeRegistryService) -Lsa $lsa `
            -Clock (New-HDTFakeClock -UtcNow ([datetime]'2026-09-07T00:00:00Z'))

        $decision.Action | Should -BeExactly 'Teardown'
        $lsa.GetSecret('HDTSecretBag') | Should -BeNullOrEmpty
    }

    It 'clears the bag when the sequence FAILS' {
        # THE CASE THE finally EXISTS FOR. A run that died is exactly the run
        # nobody comes back to tidy up, and it is the one most likely to have
        # left a credential behind.
        $fileSystem = New-HDTFakeFileSystem
        $lsa = New-HDTFakeLsaService
        $domain = New-HDTFakeDomainService -Failure @{
            JoinDomain = 'The specified domain either does not exist or could not be contacted.'
        }

        $leg1 = & $script:runLeg $fileSystem '' 'WinPE' $lsa $domain @{
            HDTJoinDomain          = 'corp.contoso.com'
            HDTDomainAdmin         = 'svc-hdt-join'
            HDTDomainAdminPassword = $script:joinMarker
        }
        $leg2 = & $script:runLeg $fileSystem $leg1.StateJson 'FullOS' $lsa $domain $null

        $leg2.Result.Status | Should -BeExactly 'Failed'
        $lsa.GetSecret('HDTSecretBag') | Should -BeNullOrEmpty
    }
}

Describe 'a secret across a reboot' {

    BeforeAll {
        $script:fs = New-HDTFakeFileSystem
        $script:lsa = New-HDTFakeLsaService
        $script:domain = New-HDTFakeDomainService

        $script:leg1 = & $script:runLeg $script:fs '' 'WinPE' $script:lsa $script:domain @{
            HDTJoinDomain          = 'corp.contoso.com'
            HDTDomainAdmin         = 'svc-hdt-join'
            HDTDomainAdminPassword = $script:joinMarker
            HDTAdminPassword       = $script:adminMarker
        }

        $script:leg2 = & $script:runLeg $script:fs $script:leg1.StateJson 'FullOS' $script:lsa $script:domain $null
    }

    It 'ends the first leg at the Restart' {
        $script:leg1.Result.Status | Should -BeExactly 'RebootPending'
    }

    It 'writes the redaction into state.json, not the password' {
        $script:leg1.StateJson | Should -Not -BeLike ('*{0}*' -f $script:joinMarker)
        $script:leg1.StateJson | Should -BeLike '*HDTDomainAdminPassword*'
        $script:leg1.StateJson | Should -BeLike ('*{0}*' -f $script:redaction)
    }

    It 'hands the resumed leg the real password rather than the redaction' {
        # THE ACCEPTANCE CASE. The step reads HDTDomainAdminPassword out of the
        # variable bag and passes it to IDomainService.JoinDomain; the fake keeps
        # what it was handed, so this asserts what the directory would have been
        # given.
        [string] $script:domain.LastPassword | Should -BeExactly $script:joinMarker
    }

    It 'joins the domain instead of refusing' {
        $script:leg2.Result.Status | Should -BeExactly 'Succeeded'

        $join = @($script:leg2.Result.Result | Where-Object { $_.Name -eq 'Join Domain' })
        $join.Count | Should -Be 1
        $join[0].Status | Should -BeExactly 'Completed'
    }

    It 'leaves the password in nothing the run wrote to disk, at Debug level' {
        # EVERY FILE, NOT A NAMED ONE. state.json, HDT.jsonl, the CMTrace
        # HDT.log, the status marker and anything a writer added since - the
        # assertion is over the SET, so a fourth artefact added later is covered
        # by this test the day it appears (CLAUDE.md rule 8).
        $leaked = @($script:fs.File.Keys | Where-Object {
                ([string] $script:fs.File[$_]) -like ('*{0}*' -f $script:joinMarker)
            })

        $leaked | Should -BeNullOrEmpty
    }

    It 'leaves the administrator password in nothing the run wrote either' {
        $leaked = @($script:fs.File.Keys | Where-Object {
                ([string] $script:fs.File[$_]) -like ('*{0}*' -f $script:adminMarker)
            })

        $leaked | Should -BeNullOrEmpty
    }

    It 'leaves no secret bag behind once the run has finished' {
        $script:lsa.GetSecret('HDTSecretBag') | Should -BeNullOrEmpty
    }

    It 'records the bag in the log by name and count, never by value' {
        # BY COMPONENT AND NOT BY A NEW EVENT NAME. DESIGN 4.4.2's event
        # vocabulary is a compatibility surface pinned to the design document by
        # LogEventVocabulary.Contract.Tests.ps1, and the bag needs no name in it:
        # a report renderer or the console filters this on component, and adding
        # a twenty-ninth event would be a deliberate act with a document change
        # of its own.
        $record = @(Get-HDTLogRecord -FileSystem $script:fs -Path 'X:\HDT\Logs\HDT.jsonl' |
                Where-Object { $_.component -eq 'SecretBag' })

        @($record | Where-Object { $_.message -like '*HDTDomainAdminPassword*' }) | Should -Not -BeNullOrEmpty

        $raw = [string] (Get-HDTLogRecord -FileSystem $script:fs -Path 'X:\HDT\Logs\HDT.jsonl' -Raw)
        $raw | Should -Not -BeLike ('*{0}*' -f $script:joinMarker)
    }
}
