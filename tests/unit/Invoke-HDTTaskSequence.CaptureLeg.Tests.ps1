# A RESTART WHOSE NEXT LEG IS WinPE NEEDS NO AUTOLOGON, AND THE ENGINE USED TO
# INSIST ON ONE ANYWAY.
#
# THE RUN THAT FOUND IT. 2026-08-31, a real reference build on real hardware:
# deploy, customize, sysprep, restart, capture. It reached step 11 of 12 and
# stopped dead -
#
#   step 'Restart into the boot media' asks for a restart on a resumed leg, but
#   the administrator password is not recoverable: state.json carries the
#   redaction rather than the value and the autologon LSA secret is empty.
#
# - having generalized the machine one step earlier. Nothing was wrong with the
# machine and nothing was wrong with the password. The sequence was ASKING THE
# WRONG QUESTION.
#
# WHY THE ENGINE COULD NOT ANSWER IT. Invoke-HDTSysprepStep clears the autologon
# deliberately and correctly: Winlogon's DefaultPassword, AutoLogonCount,
# RunOnce\HDTResume and the LSA secret all go, because an image that kept them
# would log itself in and re-enter a finished deployment on the first boot of
# EVERY machine ever built from it. The Restart step that follows then tried to
# arm the next logon out of the LSA secret sysprep had just - properly - emptied.
# Two correct steps, one contradiction between them.
#
# THE CONDITION IS NOT "IS THIS A RESTART", IT IS "DOES ANYTHING AFTER IT NEED A
# LOGON". An autologon exists to get a FULL-OS leg running again; a leg that
# resumes in WinPE is started by the boot media and needs nothing armed. So a
# restart followed only by WinPE steps must neither demand HDTAdminPassword nor
# arm Winlogon - and a restart followed by any FullOS step must go on doing both,
# which is the second half of every test here and the reason they come in pairs.
#
# THE PAIRING IS THE POINT (CLAUDE.md: prove it against the SET, not against the
# case you just added). A fix that stopped arming autologon everywhere would pass
# the reference-build assertions and silently strand every ordinary deployment at
# a logon screen after its restart - the exact failure DESIGN 4.5.2 exists to
# prevent. Every assertion below therefore has a twin that fails if arming is
# dropped for a leg that still needs it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

    # THE REFERENCE BUILD'S SHAPE, REDUCED TO THE THREE STEPS THAT MATTER.
    # A FullOS leg, a restart, and then a step that runs in WinPE - which is
    # reference.yaml's Sysprep / Restart / CaptureImage tail exactly, with the
    # two expensive steps replaced by NoOps so this runs against fakes.
    $script:captureLegYaml = @'
schemaVersion: 1
id: CAPTURE-LEG
name: A restart whose next leg is WinPE
steps:
  - name: Seal the machine
    type: NoOp
    runIn: FullOS
    message: stands in for Sysprep
  - name: Restart into the boot media
    type: Restart
    runIn: FullOS
  - name: Capture Image
    type: NoOp
    runIn: WinPE
    message: stands in for CaptureImage
'@

    # THE TWIN, AND THE ONLY DIFFERENCE IS THE LAST STEP'S PHASE. An ordinary
    # deployment restarts INTO the full OS and everything after depends on a
    # logon being armed.
    $script:fullOsLegYaml = @'
schemaVersion: 1
id: FULLOS-LEG
name: A restart whose next leg is the full OS
steps:
  - name: Seal the machine
    type: NoOp
    runIn: FullOS
    message: stands in for Sysprep
  - name: Restart into Windows
    type: Restart
    runIn: FullOS
  - name: Install Applications
    type: NoOp
    runIn: FullOS
    message: stands in for InstallApplications
'@

    $script:runLeg = {
        param([string] $Yaml, [hashtable] $Variable, [hashtable] $Secret)

        $argument = @{ Yaml = $Yaml; Phase = 'FullOS' }
        if ($null -ne $Variable) { $argument['Variable'] = $Variable }
        if ($null -ne $Secret) { $argument['Secret'] = $Secret }

        $harness = New-HDTSequenceTestHarness @argument
        $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

        return [pscustomobject] @{ Harness = $harness; Result = $result }
    }

    # WHY A SUCCEEDED RUN'S MESSAGE HAS TO BE ASKED FOR CAREFULLY. The object
    # Invoke-HDTTaskSequence returns carries Message only when there is something
    # to say; a run that simply worked has no such property. Under StrictMode -
    # which ./build.ps1 sets and a bare Invoke-Pester does NOT - reading it is a
    # terminating error, so a -Because written to explain a FAILURE blows up on
    # the PASSING path instead and reports "The property 'Message' cannot be
    # found" in place of the real result. Three of these were exactly that, green
    # in a direct run and red in the gate; the gate was right.
    $script:reason = {
        param([object] $Run)

        if ($null -eq $Run -or $null -eq $Run.Result) { return '<no result>' }
        if ($null -eq $Run.Result.PSObject.Properties['Message']) { return '<no message>' }

        return [string] $Run.Result.Message
    }

    # What Save-HDTRunState writes to disk in place of a secret, and the exact
    # string a resumed leg therefore rehydrates into HDTAdminPassword.
    # Protect-HDTSecretValue owns these words but is private, so this is the
    # literal every other suite here spells out too - Get-HDTWizardSummary,
    # Get-HDTVariableMap and Export-HDTVariableProvenance all assert it by hand.
    $script:redaction = '(set, not shown)'
}

Describe 'a restart whose next leg runs in WinPE' {

    # THE REGRESSION, IN ITS ORIGINAL FORM. state.json carries the redaction
    # because this leg rehydrated from it, and the LSA secret is empty because
    # sysprep cleared it one step ago. Before the fix this threw and took the run
    # down at step 11 of 12, on a machine that had already been generalized and
    # so could not be picked up where it left off.
    It 'does not fail when the password is unrecoverable after sysprep cleared it' {
        $run = & $script:runLeg $script:captureLegYaml @{ HDTAdminPassword = $script:redaction } $null

        [string] $run.Result.Status | Should -Not -BeExactly 'Failed' -Because (
            (& $script:reason $run))
    }

    It 'reports the reboot rather than an error' {
        $run = & $script:runLeg $script:captureLegYaml @{ HDTAdminPassword = $script:redaction } $null

        [string] $run.Result.Status | Should -BeExactly 'RebootPending'
    }

    # AND IT DOES NOT DEMAND ONE EITHER. The pre-flight guard beside
    # Invoke-HDTStepAttempt refuses a restart when nothing supplies
    # HDTAdminPassword. That refusal is right for a leg that has to log itself
    # back on and wrong here, where the boot media starts the next leg.
    It 'does not demand HDTAdminPassword at all' {
        # EMPTY, NOT ABSENT. The harness seeds HDTAdminPassword so every other
        # suite gets a working restart for free, so "nothing supplies it" has to
        # be said out loud rather than by leaving it out.
        $run = & $script:runLeg $script:captureLegYaml @{ HDTAdminPassword = '' } $null

        [string] $run.Result.Status | Should -BeExactly 'RebootPending' -Because (
            (& $script:reason $run))
    }

    It 'writes nothing to Winlogon, because nothing after it logs on' {
        # ASSERTED FROM THE CROSS-SERVICE JOURNAL, which is the shape every other
        # reboot assertion here uses: it records the ORDER of calls across
        # services, so "did it arm" and "did it arm before restarting" are the
        # same evidence read two ways.
        $run = & $script:runLeg $script:captureLegYaml @{ HDTAdminPassword = 'Set-By-The-Rules-1' } $null

        $setValue = @($run.Harness.Journal |
                Where-Object { $_.Service -eq 'RegistryService' -and $_.Operation -eq 'SetValue' -and
                    [string] $_.Arguments[0] -eq $script:winlogonPath })

        $setValue | Should -BeNullOrEmpty -Because (
            'a leg that resumes in WinPE is started by the boot media; arming Winlogon would leave the captured machine logging itself in')
    }

    It 'stores no autologon secret either' {
        $run = & $script:runLeg $script:captureLegYaml @{ HDTAdminPassword = 'Set-By-The-Rules-1' } $null

        $secretWrite = @($run.Harness.Journal |
                Where-Object { $_.Service -eq 'LsaService' -and $_.Operation -eq 'SetSecret' })

        $secretWrite | Should -BeNullOrEmpty -Because (
            'sysprep cleared this secret one step earlier, precisely so the image would not carry it')
    }

    It 'still restarts the machine' {
        # THE STEP STILL HAS TO DO ITS JOB. "Arms nothing" must not quietly
        # become "does nothing": the boot media can only start the next leg if
        # the machine actually reboots.
        $run = & $script:runLeg $script:captureLegYaml @{ HDTAdminPassword = 'Set-By-The-Rules-1' } $null

        @($run.Harness.Journal |
                Where-Object { $_.Service -eq 'PowerService' -and $_.Operation -eq 'Restart' }).Count |
            Should -Be 1
    }
}

Describe 'a restart whose next leg runs in the full OS' {

    # THE TWIN. Every assertion above has one here, and this is the half that
    # fails if the fix is "stop arming autologon" rather than "arm it when the
    # next leg needs one". DESIGN 4.5.2's whole mechanism lives or dies here.

    It 'still arms Winlogon' {
        $run = & $script:runLeg $script:fullOsLegYaml @{ HDTAdminPassword = 'Set-By-The-Rules-1' } $null

        @($run.Harness.Journal |
                Where-Object { $_.Service -eq 'RegistryService' -and $_.Operation -eq 'SetValue' -and
                    [string] $_.Arguments[0] -eq $script:winlogonPath }).Count |
            Should -BeGreaterThan 0
    }

    It 'still stores the autologon secret' {
        $run = & $script:runLeg $script:fullOsLegYaml @{ HDTAdminPassword = 'Set-By-The-Rules-1' } $null

        @($run.Harness.Journal |
                Where-Object { $_.Service -eq 'LsaService' -and $_.Operation -eq 'SetSecret' }).Count |
            Should -BeGreaterThan 0
    }

    It 'still arms it with HDTAdminPassword and not something it invented' {
        # DESIGN 4.5.2: the administrator sets the password, HDT does not invent
        # one. An earlier draft minted a random secret per deployment and left
        # machines nobody could log into when a run failed halfway.
        #
        # THE PASSWORD IS AN LSA SECRET AND NOT A REGISTRY VALUE, which is the
        # whole reason this defect existed: Winlogon reads DefaultPassword out of
        # the LSA store, sysprep clears that store before generalizing, and the
        # restart that followed then had nowhere left to read it from.
        $run = & $script:runLeg $script:fullOsLegYaml @{ HDTAdminPassword = 'Set-By-The-Rules-1' } $null

        $written = @($run.Harness.Journal |
                Where-Object { $_.Service -eq 'LsaService' -and $_.Operation -eq 'SetSecret' -and
                    [string] $_.Arguments[0] -eq 'DefaultPassword' })

        $written.Count | Should -BeGreaterThan 0

        # READ BACK OFF THE FAKE, NOT OUT OF THE JOURNAL. The journal REDACTS a
        # secret's value - it records that DefaultPassword was set and writes
        # "<redacted>" where the password would be, which is the same care
        # Save-HDTRunState takes with state.json. So the journal proves the call
        # happened and the store proves what it stored.
        [string] $run.Harness.Lsa.GetSecret('DefaultPassword') | Should -BeExactly 'Set-By-The-Rules-1'
    }

    It 'still refuses a restart nothing can come back from' {
        # The pre-flight guard, unchanged for the leg it was written for: no
        # password, a full-OS step waiting on the far side, so the machine would
        # stop at a logon screen. Between a loop and a stop, choose the stop.
        $run = & $script:runLeg $script:fullOsLegYaml @{ HDTAdminPassword = '' } $null

        [string] $run.Result.Status | Should -BeExactly 'Failed'
    }
}
