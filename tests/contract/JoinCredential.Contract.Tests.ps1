# A DOMAIN JOIN CREDENTIAL REACHES NO LOG, NO COMMAND LINE AND NO IMAGE.
#
# SecretRedaction.Contract.Tests.ps1 makes this guarantee for the LOCAL
# administrator password, and the reasoning there ends with "that is privilege
# escalation" - on one machine. This file makes the same guarantee for the
# account that joins machines to the domain, where the blast radius is the
# estate rather than the bench: an account with rights to create computer
# objects, recovered off a deployment share or out of a reference image, is a
# foothold in the directory itself.
#
# THREE PLACES IT COULD GO, AND ALL THREE ARE ASSERTED HERE, because the
# redaction machinery only covers the first:
#
#   1. A LOG OR A CHECKPOINT. Covered by Test-HDTSecretVariable, which already
#      classifies HDTDomainAdminPassword by BOTH its map row and its name - so
#      every writer that asks gets it right. What is asserted here is that the
#      STEP asks: it must not compose a message or a Data bag of its own that
#      carries the value past a redactor that never sees it.
#
#   2. A PROCESS COMMAND LINE. Nothing redacts one. Anyone on the machine can
#      read Win32_Process.CommandLine, including the account being deployed to,
#      and MDT's own answer here is the right one: ZTIDomainJoin.wsf passes the
#      password as a WMI method argument and never shells anything. So the
#      adapter is scanned for the cmdlets and the executables that would put it
#      on one.
#
#   3. AN ANSWER FILE, AND THEREFORE A CAPTURED IMAGE. This is the one MDT gets
#      wrong and HDT deliberately does not do at all. MDT's primary join is the
#      unattend's Microsoft-Windows-UnattendedJoin component, whose <Credentials>
#      block carries the password in clear - ZTIConfigure.wsf even sets the
#      parallel <PlainText> element to true - and LTICleanup.wsf's DoCapture
#      branch strips AutoLogon, FirstLogonCommands and LocalAccounts out of the
#      answer file before a capture WITHOUT stripping UnattendedJoin. Capture a
#      reference image from a machine whose sequence set JoinDomain and the
#      domain password rides inside the .wim.
#
#      HDT JOINS ONLINE, IN THE FULL OS, THROUGH A STEP - so there is no
#      credential in an answer file to leak in the first place. That is a
#      property of the shipped templates, and this file holds them to it.

# THE FILE LISTS ARE BUILT IN BeforeDiscovery AND NOT IN BeforeAll, because
# Pester 5 expands -ForEach while DISCOVERING. Built in a BeforeAll they are
# $null at the moment the cases are made, which produces one nameless test case
# per block that binds nothing - and a scan of nothing is a contract that passes
# for ever. The same trap is written up at the head of StepProgress.Contract.Tests.ps1.
BeforeDiscovery {
    $script:discoveryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    $script:answerFileCase = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:discoveryRoot -ChildPath 'src/Hephaestus/Templates') `
            -Filter '*.xml' -File -Recurse | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })

    $script:shippedSequenceCase = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:discoveryRoot -ChildPath 'src/Hephaestus/Templates') `
            -Filter '*.yaml' -File -Recurse | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # REALISTIC IN SHAPE, SYNTHETIC IN CONTENT, and a marker nothing else uses -
    # so a hit anywhere below is unambiguous and no fixture in this repository
    # reads as a credential.
    $script:password = 'MARKER-JOIN-{0}-Aa1!' -f [guid]::NewGuid().ToString('N').Substring(0, 16)

    # And ordinary values that must SURVIVE, so a redaction that swallowed the
    # whole record fails here rather than passing.
    $script:domainName = 'corp.contoso.com'
    $script:accountName = 'svc-hdt-join'

    $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 1, 11, 30, 0, [System.DateTimeKind]::Utc))
    $script:fileSystem = New-HDTFakeFileSystem

    # AT Debug, because a level that dropped records would pass this file by
    # writing nothing at all.
    $script:log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
        -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

    $script:domainService = New-HDTFakeDomainService

    $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:variable['HDTComputerName'] = 'HDT-LAB-01'
    $script:variable['HDTJoinDomain'] = $script:domainName
    $script:variable['HDTMachineObjectOU'] = 'OU=Workstations,DC=corp,DC=contoso,DC=com'
    $script:variable['HDTDomainAdmin'] = $script:accountName
    $script:variable['HDTDomainAdminDomain'] = 'CORP'
    $script:variable['HDTDomainAdminPassword'] = $script:password

    $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Domain $script:domainService

    $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
        -Variable $script:variable -Service $catalog -Log $script:log
    $context.SetStep(1, 'Join Domain', 'JoinDomain', 'C:\HDT\Logs\Steps\001-JoinDomain.log')

    # THE REAL STEP, WITH THE SHIPPED TEMPLATE'S OWN PROPERTIES. Anything less
    # would assert this guarantee over a code path no sequence takes.
    $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in @(Get-HDTJoinDomainStepTemplate)) {
        if ($line -notmatch '^\s{2}(?<key>[a-zA-Z]+):\s*(?<value>\S.*)$') { continue }

        $key = [string] $Matches['key']
        if (@('type', 'runIn', 'retry', 'timeoutMinutes', 'continueOnError') -contains $key) { continue }

        $script:value = ([string] $Matches['value']).Trim().Trim("'").Trim('"')
        $property[$key] = $script:value
    }

    $script:stepProperty = $property

    $script:result = Invoke-HDTJoinDomainStep -Context $context -Step ([pscustomobject] @{
            Index          = 1
            Name           = 'Join Domain'
            Type           = 'JoinDomain'
            TimeoutMinutes = 0
            Log            = $null
            Property       = $property
        })

    # -- THE ARTEFACTS, EACH FROM ITS REAL WRITER -----------------------------

    $script:artefact = [ordered] @{}
    $script:artefact['HDT.jsonl'] = [string] $script:fileSystem.ReadAllText('C:\HDT\Logs\HDT.jsonl')
    $script:artefact['HDT.log'] = [string] $script:fileSystem.ReadAllText('C:\HDT\Logs\HDT.log')

    # The step result, as the loop hands it on: Message and Data both end up in
    # a log record and in the run summary.
    $script:artefact['step result'] = ('{0} {1} {2}' -f
        [string] $script:result.Status, [string] $script:result.Message,
        (@($script:result.Data.Keys | ForEach-Object { '{0}={1}' -f $_, [string] $script:result.Data[$_] }) -join ' '))

    # state.json, written from the bag the step ran against - the file that
    # travels with the machine and is copied to the share.
    $stateFileSystem = New-HDTFakeFileSystem
    $state = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'run-0001' -Phase FullOS `
        -Clock $script:clock -Variable $script:variable -Step @(
        [ordered] @{ Name = 'Join Domain'; Type = 'JoinDomain'; Index = 1 })

    Save-HDTRunState -State $state -Path 'C:\HDT\state.json' -FileSystem $stateFileSystem `
        -Clock $script:clock -Confirm:$false

    $script:artefact['state.json'] = [string] $stateFileSystem.ReadAllText('C:\HDT\state.json')

    $script:artefactName = @($script:artefact.Keys)

    # -- THE SOURCE THAT COULD PUT IT ON A COMMAND LINE -----------------------

    $script:adapterPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/New-HDTDomainService.ps1'
    $script:stepPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Steps/Invoke-HDTJoinDomainStep.ps1'

    # -- AND THE TEMPLATES THAT COULD PUT IT IN AN IMAGE ----------------------

    $script:answerFile = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates') `
            -Filter '*.xml' -File -Recurse)

    $script:shippedSequence = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates') `
            -Filter '*.yaml' -File -Recurse)

    # AND THE STEP THAT MUST BE IN THE SHIPPED CLIENT SEQUENCE. A wizard page
    # collecting six variables that no shipped sequence consumes is the defect
    # this whole change exists to close, and it would come back the moment
    # somebody tidied the step out of client.yaml.
    $script:clientSequencePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/client.yaml'
}

Describe 'The run this contract is asserted over' {

    # NON-VACUITY FIRST. A step that refused, or a fake that was never called,
    # would make every assertion below pass while proving nothing.
    It 'joined the domain' {
        [string] $script:result.Status | Should -BeExactly 'Completed'
        @($script:domainService.GetOperationName()) | Should -Contain 'JoinDomain'
    }

    It 'handed the real password to the service, so there was one to leak' {
        [string] $script:domainService.LastPassword | Should -BeExactly $script:password
    }

    It 'wrote something to <_>' -ForEach @('HDT.jsonl', 'HDT.log', 'step result', 'state.json') {
        [string] $script:artefact[$PSItem] | Should -Not -BeNullOrEmpty
    }
}

Describe 'The domain join password survives no artefact of the leg that used it' {

    It 'writes the password nowhere in <_>' -ForEach @('HDT.jsonl', 'HDT.log', 'step result', 'state.json') {
        [string] $script:artefact[$PSItem] |
            Should -Not -BeLike ('*{0}*' -f $script:password) `
            -Because ("{0} must not carry the account that can join machines to the directory" -f $PSItem)
    }
}

Describe 'And it still answers the questions a failed join is diagnosed by' {

    # A LOG THAT WENT QUIET TO AVOID LEAKING IS NOT A FIX. "The join failed" with
    # nothing beside it sends an administrator to look at DNS when the account was
    # wrong, or at the account when the OU did not exist.
    It 'still names the domain in <_>' -ForEach @('HDT.jsonl', 'HDT.log', 'step result') {
        [string] $script:artefact[$PSItem] | Should -BeLike ('*{0}*' -f $script:domainName)
    }

    It 'still names the account it joined as in <_>' -ForEach @('HDT.jsonl', 'HDT.log', 'step result') {
        [string] $script:artefact[$PSItem] | Should -BeLike ('*{0}*' -f $script:accountName)
    }

    # AND THE CHECKPOINT STILL SAYS A PASSWORD WAS SET, which is how "nobody
    # filled the box in" is told apart from "it was redacted on the way past".
    It 'names the secret without carrying it, in state.json' {
        [string] $script:artefact['state.json'] | Should -BeLike '*HDTDomainAdminPassword*'
        [string] $script:artefact['state.json'] | Should -BeLike '*(set, not shown)*'
    }
}

Describe 'The password reaches no process command line' {

    # NOTHING REDACTS Win32_Process.CommandLine. Every local account on the
    # machine can read it while the process lives, and a process that runs for a
    # second still overlaps the deployment's own polling.
    #
    # MDT REACHED THE SAME ANSWER: ZTIDomainJoin.wsf passes the password as an
    # argument to Win32_ComputerSystem.JoinDomainOrWorkgroup and shells nothing
    # at all. HDT calls Add-Computer in-process with a PSCredential, which is the
    # same shape through a supported cmdlet.
    #
    # THE SCAN IS OVER THE ADAPTER, because the step cannot do this: the AST scan
    # in StepContract.Tests.ps1 already bans Start-Process inside Public\Steps as
    # raw text. The adapter is the only file with an opportunity.
    It 'has an adapter to scan' {
        Test-Path -LiteralPath $script:adapterPath -PathType Leaf | Should -BeTrue
    }

    It 'launches no process from the adapter: <_>' -ForEach @(
        'Start-Process', 'Invoke-Expression', 'Invoke-Command', 'Start-Job',
        'netdom', 'djoin', 'net.exe', 'cmd.exe', 'wmic') {

        $text = Get-Content -LiteralPath $script:adapterPath -Raw

        $text | Should -Not -Match ('\b{0}\b' -f [regex]::Escape($PSItem)) `
            -Because 'a domain password on a command line is readable by every local account through Win32_Process'
    }

    # AND THE ONE CALL IT DOES MAKE IS THE IN-PROCESS ONE. A scan that only
    # forbade things would pass a file that joined nothing.
    It 'joins through the in-process cmdlet' {
        Get-Content -LiteralPath $script:adapterPath -Raw | Should -Match '\bAdd-Computer\b'
    }

    # THE PASSWORD IS NEVER A STEP PROPERTY EITHER. A password: key in
    # sequence.yaml is a domain credential in a file the console prints into a
    # text box, quotes back in refusals and stores on a share every machine
    # being deployed can read.
    It 'reads no password key off the authored step' {
        Get-Content -LiteralPath $script:stepPath -Raw |
            Should -Not -Match "(?m)^\s*[^#]*'password'"
    }
}

Describe 'The password reaches no answer file, and therefore no captured image' {

    # THIS IS THE MDT DEFECT NOT CARRIED ACROSS. MDT's join is the unattend's
    # Microsoft-Windows-UnattendedJoin component and its <Credentials> block
    # holds the password in clear on the deployed disk; its capture path strips
    # AutoLogon and LocalAccounts out of the answer file and leaves that block
    # in. HDT has no such block anywhere, because the join is a step.
    It 'found the shipped answer files to scan' {
        @($script:answerFile).Count | Should -BeGreaterThan 0
    }

    It 'declares no UnattendedJoin component in <Name>' -ForEach $script:answerFileCase {

        $text = Get-Content -LiteralPath $Path -Raw

        $text | Should -Not -Match 'Microsoft-Windows-UnattendedJoin'
        $text | Should -Not -Match '<JoinDomain>'
        $text | Should -Not -Match '<MachineObjectOU>'
    }

    It 'names no domain join password in <Name>' -ForEach $script:answerFileCase {

        Get-Content -LiteralPath $Path -Raw | Should -Not -Match 'HDTDomainAdminPassword'
    }

    # AND THE REFERENCE BUILD JOINS NOTHING. MDT hard-fails sysprep on a
    # domain-joined machine - LTISysprep.wsf reports failure 7002 on DomainRole
    # 1, 3, 4 or 5 - so a capture sequence that joined first would abort at the
    # last step of a build somebody spent a day on. The shipped capture sequence
    # therefore has no JoinDomain step in it, and this is what keeps it that way.
    It 'found the shipped sequences to scan' {
        @($script:shippedSequence).Count | Should -BeGreaterThan 0
    }

    It 'declares no JoinDomain step in a sequence that captures an image: <Name>' -ForEach $script:shippedSequenceCase {

        $text = Get-Content -LiteralPath $Path -Raw

        if ($text -notmatch '(?m)^\s*type:\s*CaptureImage\s*$') { return }

        $text | Should -Not -Match '(?m)^\s*type:\s*JoinDomain\s*$' `
            -Because 'sysprep refuses a domain-joined machine, and a captured image must carry no domain state'
    }
}

Describe 'The shipped client sequence consumes what the wizard collects' {

    # THE DEFECT THIS WHOLE STEP EXISTS TO CLOSE, ASSERTED SO IT CANNOT COME
    # BACK. The Computer Details page collected a domain, an OU, a workgroup, a
    # join account and a DOMAIN ADMIN PASSWORD, and no shipped sequence did
    # anything with any of it - a technician answered that page and the answers
    # went nowhere. A step type that exists but appears in no sequence is the
    # same defect with an extra file in it.
    It 'declares a JoinDomain step' {
        Get-Content -LiteralPath $script:clientSequencePath -Raw |
            Should -Match '(?m)^\s*type:\s*JoinDomain\s*$'
    }

    It 'names every variable the Computer Details page collects, bar the password' -ForEach @(
        'HDTJoinDomain', 'HDTMachineObjectOU', 'HDTJoinWorkgroup',
        'HDTDomainAdmin', 'HDTDomainAdminDomain') {

        Get-Content -LiteralPath $script:clientSequencePath -Raw |
            Should -BeLike ('*{0}*' -f $PSItem)
    }

    # THE VALUE, NOT THE NAME. The file NAMES the variable, in a comment that
    # warns an administrator it does not survive the restart above it - which is
    # exactly the thing somebody has to know before they wonder why an
    # unattended join refused. What must not be there is a step KEY that carries
    # the credential: a password: on the step, or a %HDTDomainAdminPassword%
    # token substituted into one. Either would put a domain admin credential
    # into a file on a share every machine being deployed can read, and into the
    # console's own text box.
    It 'declares no key on any step that would carry the credential' {
        $text = Get-Content -LiteralPath $script:clientSequencePath -Raw

        $text | Should -Not -Match '(?m)^\s*password:'
        $text | Should -Not -Match '%HDTDomainAdminPassword%'
    }
}
