# NO ARTEFACT A RUN LEAVES BEHIND MAY CONTAIN A SECRET'S VALUE.
#
# THE RUN THAT FORCED THIS FILE. A real deployment left the local administrator
# password in clear in every one of these, on the same run, minutes apart:
#
#   Logs\<computer>\<run>\HDT.jsonl     Debug | Variable | var.resolve | HDTAdminPassword = '...'
#   Logs\<computer>\<run>\HDT.log       the same record, CMTrace-formatted
#   Logs\<computer>-<run>\state.json    the variable map, verbatim
#
# while Gather\provenance.json, written from the same resolution seconds
# earlier, correctly said "(set, not shown)". One writer asked whether the
# variable was secret; three did not. Those files are copied to the deployment
# share, which every machine being deployed can read, and the finish action
# moves them to C:\Windows\Logs\HDT on the deployed machine, which authenticated
# users can read - so the local administrator password of a machine was readable
# by any local user of that machine. That is privilege escalation.
#
# WHY THE TEST IS SHAPED THIS WAY (CLAUDE.md rule 8). A test naming
# HDTAdminPassword and state.json would pass for those two and fail for nobody
# after them - which is exactly how three writers came to disagree. So:
#
#   - the SECRETS come from Test-HDTSecretVariable at run time, not from a list
#     written here. A sixth secret added to Get-HDTVariableMap tomorrow, or a
#     customer variable the name pattern catches, is asserted by this file today.
#   - the ARTEFACTS are enumerated as a set, each one produced by the real
#     writer against fakes, and every marker is searched for in every artefact.
#     A fourth writer added later fails here until it goes through the helper.
#   - each artefact must also PROVE IT CARRIED THE VARIABLE, by naming it. A
#     writer that wrote nothing at all would otherwise pass this file while
#     leaking nowhere and recording nothing.
#
# THE MARKERS ARE SYNTHETIC ON PURPOSE. Nothing below looks like a password,
# because a fixture that does is a credential as far as the next person grepping
# this repository is concerned.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:module = Get-Module -Name 'Hephaestus'

    # -- WHICH NAMES ARE SECRET, ASKED OF THE CLASSIFIER ITSELF ---------------
    #
    # Every declared one, plus names no map row mentions - the half the map
    # cannot cover, and the half a hand-written list here would never contain.
    $declared = @(Get-HDTVariableMap | Where-Object { $_.IsSecret } | ForEach-Object { [string] $_.HDTName })
    $undeclared = @('HDTJoinPassword', 'HDTApiSecret', 'HDTUnlockPin')

    $script:secretName = @(@($declared) + @($undeclared) | Select-Object -Unique | Where-Object {
            & $script:module { param($N) Test-HDTSecretVariable -Name $N } $PSItem
        })

    # A DISTINCT, FINDABLE MARKER PER VARIABLE. A shared literal could be
    # matched by the wrong entry and would make one leak look like none.
    $script:secretValue = [ordered] @{}
    $index = 0
    foreach ($name in $script:secretName) {
        $index++
        $script:secretValue[$name] = ('MARKER-{0:d2}-{1}' -f $index, [guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    # And an ordinary variable that must survive every artefact intact, so a
    # redaction that swallowed the whole file fails here rather than passing.
    $script:plainName = 'HDTComputerName'
    $script:plainValue = 'HDT-LAB-01'

    $commandLine = [ordered] @{}
    foreach ($name in $script:secretName) { $commandLine[$name] = $script:secretValue[$name] }
    $commandLine[$script:plainName] = $script:plainValue

    $script:resolution = Resolve-HDTVariable -CommandLine $commandLine -Fact @{}

    # -- THE ARTEFACTS, EACH FROM THE REAL WRITER ------------------------------
    #
    # Named by the file a run actually leaves behind, because the failure this
    # file exists to catch is read off those names.
    $script:artefact = [ordered] @{}

    $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 19, 1, 5, 0, [System.DateTimeKind]::Utc))

    # 1 + 2. HDT.jsonl and HDT.log. At Debug, because that is the level
    # var.resolve is written at and an Info context would drop every record -
    # which would pass this file by writing nothing.
    $logFileSystem = New-HDTFakeFileSystem
    $logContext = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
        -FileSystem $logFileSystem -Clock $clock -Level Debug

    Write-HDTVariableLog -Context $logContext -Resolution $script:resolution

    $script:jsonlText = [string] $logFileSystem.ReadAllText('X:\HDT\Logs\HDT.jsonl')
    $script:artefact['HDT.jsonl'] = $script:jsonlText
    $script:artefact['HDT.log'] = [string] $logFileSystem.ReadAllText('X:\HDT\Logs\HDT.log')

    # 3. state.json - the file that travels with the machine.
    $stateFileSystem = New-HDTFakeFileSystem
    $state = New-HDTRunState -SequenceId 'PNP-TEST' -RunId 'run-0001' -Phase WinPE `
        -Clock $clock -Variable $script:resolution.Variable -Step @(
        [ordered] @{ Name = 'Gather'; Type = 'Gather'; Index = 1 })

    Save-HDTRunState -State $state -Path 'C:\HDT\state.json' -FileSystem $stateFileSystem -Clock $clock -Confirm:$false

    $script:artefact['state.json'] = [string] $stateFileSystem.ReadAllText('C:\HDT\state.json')

    # 4. Gather\provenance.json - the one writer that already asked, kept
    # honest here so the fix cannot silently un-fix it.
    $provenanceFileSystem = New-HDTFakeFileSystem
    Export-HDTVariableProvenance -Resolution $script:resolution `
        -Path 'C:\HDT\Logs\Gather\provenance.json' -FileSystem $provenanceFileSystem

    $script:artefact['provenance.json'] = [string] $provenanceFileSystem.ReadAllText('C:\HDT\Logs\Gather\provenance.json')

    # 5. report.html - rendered from the stream above, so it leaks whatever the
    # stream leaked plus anything it adds of its own.
    $reportFileSystem = New-HDTFakeFileSystem -File @{ 'C:\HDT\Logs\HDT.jsonl' = $script:jsonlText }
    [void] (ConvertTo-HDTReport -JsonlPath 'C:\HDT\Logs\HDT.jsonl' -Path 'C:\HDT\Logs\report.html' `
            -FileSystem $reportFileSystem)

    $script:artefact['report.html'] = [string] $reportFileSystem.ReadAllText('C:\HDT\Logs\report.html')

    # 6. The SetVariable step's own var.resolve record. A SECOND WRITER OF THE
    # SAME EVENT, and the one a sequence uses to set a password from a script -
    # so it leaks by exactly the route Write-HDTVariableLog did.
    $stepFileSystem = New-HDTFakeFileSystem
    $stepLog = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Step' `
        -FileSystem $stepFileSystem -Clock $clock -Level Debug

    $stepContext = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'C:\ws' `
        -Variable ([ordered] @{}) -Log $stepLog `
        -Service (New-HDTServiceCatalog -FileSystem $stepFileSystem -Clock $clock)

    $setProperty = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $script:secretName) { $setProperty[$name] = $script:secretValue[$name] }
    $setProperty[$script:plainName] = $script:plainValue

    [void] (Invoke-HDTSetVariableStep -Context $stepContext -Step ([pscustomobject] @{
                Name     = 'Set the secrets'
                Type     = 'SetVariable'
                Index    = 1
                Property = [ordered] @{ variables = $setProperty }
            }))

    $script:artefact['SetVariable HDT.jsonl'] = [string] $stepFileSystem.ReadAllText('X:\HDT\Step\HDT.jsonl')
    $script:artefact['SetVariable HDT.log'] = [string] $stepFileSystem.ReadAllText('X:\HDT\Step\HDT.log')

    # 7. Gather\facts.json - provenance.json's sibling, and a name-and-value
    # serialiser writing into the same copied-back directory. A rule script can
    # put anything under any name into the fact bag.
    $factFileSystem = New-HDTFakeFileSystem
    $fact = [ordered] @{}
    foreach ($name in $script:secretName) { $fact[$name] = $script:secretValue[$name] }
    $fact[$script:plainName] = $script:plainValue

    [void] (Export-HDTMachineFact -Fact $fact -Path 'C:\HDT\Logs\Gather\facts.json' `
            -FileSystem $factFileSystem -Timestamp ([datetime]::new(2026, 8, 29, 19, 1, 5, 0, [System.DateTimeKind]::Utc)))

    $script:artefact['facts.json'] = [string] $factFileSystem.ReadAllText('C:\HDT\Logs\Gather\facts.json')

    $script:artefactName = @($script:artefact.Keys)
}

Describe 'The secrets and the artefacts this contract is asserted over' {

    # NON-VACUITY, TWICE. An empty secret list or an empty artefact list would
    # make every assertion below pass over nothing, which is the failure mode a
    # security contract test cannot afford.
    It 'knows of at least one secret to redact' {
        @($script:secretName).Count | Should -BeGreaterThan 0
    }

    It 'covers every variable Get-HDTVariableMap declares secret' {
        $declared = @(Get-HDTVariableMap | Where-Object { $_.IsSecret } | ForEach-Object { [string] $_.HDTName })
        $missed = @($declared | Where-Object { $script:secretName -notcontains $PSItem })

        ($missed -join ', ') | Should -BeExactly ''
    }

    It 'covers a secret name no map row declares, which is the one a list here would miss' {
        $script:secretName | Should -Contain 'HDTJoinPassword'
    }

    It 'produced every artefact it asserts over' {
        @($script:artefactName).Count | Should -BeGreaterThan 5
    }

    It 'produced an artefact with something in it' -ForEach @(
        'HDT.jsonl', 'HDT.log', 'state.json', 'provenance.json', 'report.html',
        'SetVariable HDT.jsonl', 'SetVariable HDT.log', 'facts.json') {

        [string] $script:artefact[$PSItem] | Should -Not -BeNullOrEmpty
    }
}

Describe 'No artefact a run leaves behind carries a secret value' {

    # THE ASSERTION, OVER THE CROSS PRODUCT. Every artefact against every
    # secret, so neither dimension can grow without this file noticing.
    It 'writes no secret value into <_>' -ForEach @(
        'HDT.jsonl', 'HDT.log', 'state.json', 'provenance.json', 'report.html',
        'SetVariable HDT.jsonl', 'SetVariable HDT.log', 'facts.json') {

        $text = [string] $script:artefact[$PSItem]
        $leaked = New-Object -TypeName System.Collections.ArrayList

        foreach ($name in $script:secretName) {
            if ($text -like ('*{0}*' -f $script:secretValue[$name])) {
                [void] $leaked.Add($name)
            }
        }

        (@($leaked) -join ', ') | Should -BeExactly '' -Because ("{0} must not carry a secret's value" -f $PSItem)
    }
}

Describe 'And it still answers the questions it exists to answer' {

    # THE NAME AND THE PROVENANCE STAY. A redaction that dropped the record
    # would answer "which rule set the administrator password" with silence,
    # which is worse than useless when a deployment has just failed for want of
    # one.
    It 'still names the secret variable in <_>' -ForEach @(
        'HDT.jsonl', 'HDT.log', 'state.json', 'provenance.json', 'report.html',
        'SetVariable HDT.jsonl', 'SetVariable HDT.log', 'facts.json') {

        [string] $script:artefact[$PSItem] | Should -BeLike '*HDTAdminPassword*'
    }

    It 'says the secret was set rather than leaving a blank in <_>' -ForEach @(
        'HDT.jsonl', 'HDT.log', 'state.json', 'provenance.json',
        'SetVariable HDT.jsonl', 'SetVariable HDT.log', 'facts.json') {

        [string] $script:artefact[$PSItem] | Should -BeLike '*(set, not shown)*'
    }

    # AND A REDACTION THAT SWALLOWED THE FILE IS NOT A FIX. The ordinary values
    # are what a deployment is diagnosed from and they must all still be there.
    It 'leaves an ordinary variable readable in <_>' -ForEach @(
        'HDT.jsonl', 'HDT.log', 'state.json', 'provenance.json', 'report.html',
        'SetVariable HDT.jsonl', 'SetVariable HDT.log', 'facts.json') {

        [string] $script:artefact[$PSItem] | Should -BeLike ('*{0}*' -f $script:plainValue)
    }
}
