# THE LAB'S OWN TASK SEQUENCES, HELD TO THE SAME RULES AS THE SHIPPED ONES.
#
# tests/e2e/payload/<ID>/ IS WHERE A LAB SEQUENCE LIVES IN THIS REPOSITORY, and
# the e2e suites copy it onto C:\HDTLab\Share\TaskSequences\<ID>\ at the start of
# every run - CapturedImageDeployment, ApplicationRoundTrip, ReferenceCapture and
# WindowsUpdate all do it, each with the same two lines. CLAUDE.md rule 8: the
# repository is the one place of truth and the share is a copy of it.
#
# NOTHING HELD THESE FILES TO ANYTHING UNTIL NOW, and that is the gap this file
# closes. tests/contract/ShippedDocumentSchema and
# tests/contract/ShippedSequenceTattoo both walk exactly two roots -
# src/Hephaestus/Templates and samples/workspace - because those are the trees a
# NEW SHARE is built from. tests/e2e/payload is neither, so five sequence
# documents that a real machine executes against real disks were parsed for the
# first time on the VM that ran them. A typo in one costs a deployment run,
# which on this host is the better part of an hour.
#
# AND IT IS A RULE OVER THE SET (CLAUDE.md rule 8 again). Every sequence.yaml
# under tests/e2e/payload is discovered and judged; nothing here names a file.
# A test naming AD-DC-2025 would pass for AD-DC-2025 and fail nobody after it.
#
# THE FOUR QUESTIONS, and each one has a failure it has already cost somebody:
#
#   1. DOES IT PARSE AND VALIDATE? Import-HDTSequenceDocument runs the real
#      reader, the real Assert-HDTSequenceDocument and the real flattener, so an
#      unknown key, a bad runIn or a group with no steps fails here rather than
#      in WinPE.
#
#   2. DOES EVERY PowerShell STEP NAME A SCRIPT THAT SHIPS? A `script:` line
#      pointing at TaskSequences\<ID>\<leaf>.ps1 resolves, on the share, to the
#      file the e2e copy put there - which it can only do if the leaf is in the
#      payload folder beside the sequence. A sequence naming a script nobody
#      wrote fails at the step, minutes into a deployment, and the message names
#      the path rather than the omission.
#
#   3. DOES IT STAMP THE MACHINE? The same classification
#      ShippedSequenceTattoo applies to the shipped set, applied here for the
#      same reason: a sequence that captures must not stamp, one with a full-OS
#      group must stamp exactly once and before it patches or installs, and one
#      that never leaves WinPE is exempt.
#
#   4. DOES IT SAY WHY? Every one of these files is read months later by
#      somebody deciding whether to trust it. A sequence document with no
#      comment at the top is a set of steps with no reasoning behind them.

$script:HDTRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name powershell-yaml -ErrorAction Stop

$script:HDTPayloadRoot = Join-Path -Path $script:HDTRepoRoot -ChildPath 'tests/e2e/payload'

# The group tree flattened into document order - ShippedSequenceTattoo's walk,
# deliberately identical, because a second dialect of the same question is how
# two rules that were meant to agree stop agreeing.
$script:HDTPayloadWalk = {
    param($Node, $Sink)

    foreach ($current in @($Node)) {
        if ($null -eq $current) { continue }
        if (-not ($current -is [System.Collections.IDictionary])) { continue }

        if ($current.Contains('group')) {

            $runIn = ''
            if ($current.Contains('runIn')) { $runIn = [string] $current['runIn'] }

            $condition = ''
            if ($current.Contains('condition')) { $condition = [string] $current['condition'] }

            if ($runIn -eq 'FullOS' -or ($condition -match '_HDTPhase' -and $condition -match 'FullOS')) {
                [void] $Sink.FullOsGroup.Add([string] $current['group'])
            }
        }

        if ($current.Contains('steps')) { & $script:HDTPayloadWalk -Node $current['steps'] -Sink $Sink }

        if (-not $current.Contains('type')) { continue }

        $stepName = '(unnamed)'
        if ($current.Contains('name')) { $stepName = [string] $current['name'] }

        [void] $Sink.StepName.Add($stepName)
        [void] $Sink.StepType.Add([string] $current['type'])

        if (([string] $current['type']) -eq 'PowerShell' -and $current.Contains('script')) {
            [void] $Sink.ScriptPath.Add([string] $current['script'])
        }
    }
}

$script:HDTPayloadSequence = @()

foreach ($file in @(Get-ChildItem -LiteralPath $script:HDTPayloadRoot -Filter 'sequence.yaml' -File -Recurse)) {

    $document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($file.FullName)) -Ordered

    if ($null -eq $document) { continue }
    if (-not ($document -is [System.Collections.IDictionary])) { continue }
    if (-not $document.Contains('steps')) { continue }

    $sink = @{
        StepName    = (New-Object -TypeName System.Collections.ArrayList)
        StepType    = (New-Object -TypeName System.Collections.ArrayList)
        FullOsGroup = (New-Object -TypeName System.Collections.ArrayList)
        ScriptPath  = (New-Object -TypeName System.Collections.ArrayList)
    }

    & $script:HDTPayloadWalk -Node $document['steps'] -Sink $sink

    $script:HDTPayloadSequence += , @{
        Name        = $file.FullName.Substring($script:HDTRepoRoot.Length + 1)
        Path        = $file.FullName
        Folder      = $file.DirectoryName
        Id          = [string] $document['id']
        Text        = [System.IO.File]::ReadAllText($file.FullName)
        StepName    = [string[]] @($sink.StepName)
        StepType    = [string[]] @($sink.StepType)
        ScriptPath  = [string[]] @($sink.ScriptPath)
        FullOsGroup = [string[]] @($sink.FullOsGroup)
        Captures    = @(@($sink.StepType) | Where-Object { $_ -eq 'Sysprep' -or $_ -like 'Capture*' }).Count -gt 0
    }
}

$script:HDTPayloadCapturing = @($script:HDTPayloadSequence | Where-Object { $_.Captures })
$script:HDTPayloadStamping = @($script:HDTPayloadSequence |
        Where-Object { -not $_.Captures -and $_.FullOsGroup.Count -gt 0 })

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Lab payload sequences' {

    # THE COUNTS COME IN AS TEST DATA. A $script: variable assigned during
    # DISCOVERY is $null by the time an It RUNS, and @($null).Count is 1 - so the
    # obvious guard passes without ever seeing the list it guards.
    # ShippedSequenceTattoo records the same trap for the same reason.
    Context 'the discovery itself' {

        It 'finds the lab sequence documents to judge' -ForEach @(@{
                DocumentCount = @($script:HDTPayloadSequence).Count
            }) {

            $DocumentCount | Should -BeGreaterThan 0
        }

        It 'finds the domain controller sequence and the sequence that joins it' -ForEach @(@{
                Id = [string[]] @(@($script:HDTPayloadSequence) | ForEach-Object { $_.Id })
            }) {

            # THE ONE PLACE THIS FILE NAMES A SEQUENCE, and it names it as an
            # ABSENCE rather than as a rule: the two documents that carry the
            # only hardware evidence JoinDomain will ever have must exist for
            # every rule below to have anything to say about them.
            $Id | Should -Contain 'AD-DC-2025'
            $Id | Should -Contain 'AD-JOIN'
        }

        It 'classifies at least one lab sequence as one an image is captured from' -ForEach @(@{
                CapturingCount = @($script:HDTPayloadCapturing).Count
            }) {

            $CapturingCount | Should -BeGreaterThan 0
        }

        It 'classifies at least one lab sequence as one that must stamp' -ForEach @(@{
                StampingCount = @($script:HDTPayloadStamping).Count
            }) {

            $StampingCount | Should -BeGreaterThan 0
        }
    }

    Context 'it is a sequence the engine can actually read' {

        It 'parses, validates and flattens <Name>' -ForEach $script:HDTPayloadSequence {

            # THE REAL READER, not a second parser written for the test. A
            # sequence ConvertFrom-Yaml accepts and Assert-HDTSequenceDocument
            # refuses is exactly the file this is looking for.
            $sequence = Import-HDTSequenceDocument -Path $Path

            @($sequence.Step).Count | Should -BeGreaterThan 0 -Because (
                '{0} is copied onto the share and executed against a real disk; a document that flattens to no steps deploys nothing' -f $Name)
        }
    }

    Context 'every script a step names is a script that ships beside it' {

        It 'ships every script <Name> names' -ForEach $script:HDTPayloadSequence {

            $missing = New-Object -TypeName System.Collections.ArrayList

            foreach ($declared in @($ScriptPath)) {

                # The share-relative form the engine resolves against the
                # workspace root. Only the sequence's OWN folder is this file's
                # business - a script under Scripts\ is seeded by
                # New-HDTWorkspace and lives in Templates\, which
                # ShippedDocumentSchema already walks.
                $prefix = 'TaskSequences\{0}\' -f $Id
                if (-not $declared.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

                $leaf = $declared.Substring($prefix.Length)
                $onDisk = [System.IO.Path]::Combine($Folder, $leaf)

                if (-not (Test-Path -LiteralPath $onDisk -PathType Leaf)) {
                    [void] $missing.Add(('{0} -> {1}' -f $declared, $onDisk))
                }
            }

            ($missing -join ' | ') | Should -BeNullOrEmpty -Because (
                'the e2e copy stages this folder onto the share, so a script the sequence names and the folder does not hold fails at the step - a long way into a deployment, with a message that names the path rather than the omission')
        }
    }

    Context 'the stamp, over the lab set as well as the shipped one' {

        It 'writes no Tattoo into <Name>' -ForEach $script:HDTPayloadCapturing {

            $offender = @(0..($StepType.Count - 1) |
                    Where-Object { $StepType[$_] -eq 'Tattoo' } |
                    ForEach-Object { ('{0} / {1}' -f $Name, $StepName[$_]) })

            ($offender -join ' | ') | Should -BeNullOrEmpty -Because (
                '{0} syspreps or captures, so a Tattoo would be baked into the image and would then describe the reference machine on every machine deployed from it' -f $Name)
        }

        It 'stamps exactly once in <Name>' -ForEach $script:HDTPayloadStamping {

            $tattoo = @(0..($StepType.Count - 1) | Where-Object { $StepType[$_] -eq 'Tattoo' })

            $tattoo.Count | Should -Be 1 -Because (
                '{0} runs a group in the full OS ({1}) and so must record what built the machine' -f
                $Name, ($FullOsGroup -join ', '))
        }

        It 'stamps before it patches or installs applications in <Name>' -ForEach $script:HDTPayloadStamping {

            $tattooAt = [array]::IndexOf($StepType, 'Tattoo')

            $late = New-Object -TypeName System.Collections.ArrayList

            if ($tattooAt -lt 0) {
                [void] $late.Add(('{0}: no Tattoo step at all' -f $Name))
            } else {
                foreach ($type in @('InstallApplications', 'WindowsUpdate')) {

                    $at = [array]::IndexOf($StepType, $type)
                    if ($at -lt 0) { continue }

                    if ($at -lt $tattooAt) {
                        [void] $late.Add(('{0}: ''{1}'' ({2}) runs at {3}, before ''{4}'' at {5}' -f
                                $Name, $StepName[$at], $type, $at, $StepName[$tattooAt], $tattooAt))
                    }
                }
            }

            ($late -join ' | ') | Should -BeNullOrEmpty -Because (
                "MDT's Client.xml runs Tattoo then Install Applications, so a run that dies in an installer still leaves an identifiable machine")
        }
    }

    Context 'it says why it exists' {

        It 'opens <Name> with a comment' -ForEach $script:HDTPayloadSequence {

            # Not a style rule. Every one of these documents encodes a lab
            # decision - which switch, which image index, why the step order is
            # what it is - and the reasoning is worth more than the steps.
            $first = @($Text -split "`n")[0]

            $first.TrimStart([char] 0xFEFF).TrimStart() | Should -Match '^#' -Because (
                '{0} is executed against a real machine months after it was written' -f $Name)
        }
    }
}
