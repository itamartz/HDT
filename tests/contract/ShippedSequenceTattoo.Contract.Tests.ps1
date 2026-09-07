# THE STAMP THIS TOOLKIT LEAVES ON A MACHINE, ACROSS EVERY SEQUENCE IT SHIPS.
#
# Tattoo writes what built a machine - the task sequence, the image, the share,
# the time - into the registry, and it is the only record a technician has six
# months later on a machine they cannot reimage to ask. MDT stamps every one of
# its own deployments; HDT shipped the step, wired it up, tested it, and then
# put it in exactly ONE of its four shipped sequences (refresh.yaml). Every
# machine built from client.yaml, STD-CLIENT, STD-SERVER or DEMO-M2 came up
# anonymous, and nothing said so.
#
# SO THIS IS A RULE OVER THE SET, NOT A LIST OF FOUR FILES - CLAUDE.md rule 8.
# A test naming client.yaml passes for client.yaml and fails nobody after it.
# Every sequence document under the trees a new share is built from, plus the
# samples an administrator copies, is discovered and then CLASSIFIED:
#
#   1. A sequence that SYSPREPS AND CAPTURES must carry no Tattoo at all. The
#      stamp would be written before the capture and baked into the .wim, so
#      every machine deployed from that image would carry a registry record
#      describing the reference machine - a different computer, a different
#      sequence, a different day. A stamp that lies is worse than no stamp,
#      because somebody will believe it. reference.yaml omits it for this
#      reason, and so does the lab's REF-ACROBAT.
#
#   2. Otherwise, a sequence with a group that runs in the FULL OS must stamp
#      exactly once, and BEFORE it patches or installs anything. That is MDT's
#      own order - Client.xml's State Restore runs Tattoo and then Install
#      Applications - and it is the order that survives failure: an application
#      install that dies half way leaves a machine that is still identifiable,
#      whereas a stamp at the end leaves it anonymous precisely when somebody
#      needs to know what happened to it.
#
#   3. A sequence with no full-OS group is exempt. DEMO-M3 and DEMO-M4 stop in
#      WinPE; nothing in them ever runs where a registry hive is mounted as the
#      live one, so there is nowhere to stamp.
#
# THE CLASSIFICATION IS READ OFF EACH FILE, NOT ASSUMED. The templates say
# `runIn: FullOS` on the group; the samples say `condition: '"%_HDTPhase%" ==
# "FullOS"'` instead. Both are the same statement about where the group runs,
# and a rule that understood only one of them would quietly exempt three of the
# four files it exists to cover.

$script:HDTRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name powershell-yaml -ErrorAction Stop

# THE TREES A NEW SHARE IS BUILT FROM, plus the samples an administrator copies
# - the same two roots ShippedDocumentSchema walks, for the same reason.
$script:HDTSequenceRoot = @('src/Hephaestus/Templates', 'samples/workspace')

# The group tree flattened into document order, with the group entries noted as
# they are passed - the same walk SequenceTemplatePlan uses, recursing into a
# group's steps BEFORE looking at the entry's own type, so the list that comes
# out is the order the engine would execute in.
$script:HDTTattooWalk = {
    param($Node, $Sink)

    foreach ($current in @($Node)) {
        if ($null -eq $current) { continue }
        if (-not ($current -is [System.Collections.IDictionary])) { continue }

        if ($current.Contains('group')) {

            $runIn = ''
            if ($current.Contains('runIn')) { $runIn = [string] $current['runIn'] }

            $condition = ''
            if ($current.Contains('condition')) { $condition = [string] $current['condition'] }

            # BOTH SPELLINGS OF "THIS GROUP RUNS IN THE FULL OS". The templates
            # declare it; the samples gate it on the phase variable the engine
            # sets. See the header - handling only one of them exempts most of
            # the files this rule is for.
            if ($runIn -eq 'FullOS' -or ($condition -match '_HDTPhase' -and $condition -match 'FullOS')) {
                [void] $Sink.FullOsGroup.Add([string] $current['group'])
            }
        }

        if ($current.Contains('steps')) { & $script:HDTTattooWalk -Node $current['steps'] -Sink $Sink }

        if (-not $current.Contains('type')) { continue }

        $stepName = '(unnamed)'
        if ($current.Contains('name')) { $stepName = [string] $current['name'] }

        [void] $Sink.StepName.Add($stepName)
        [void] $Sink.StepType.Add([string] $current['type'])
    }
}

$script:HDTSequenceDocument = @()

foreach ($relative in $script:HDTSequenceRoot) {

    $full = Join-Path -Path $script:HDTRepoRoot -ChildPath $relative
    if (-not (Test-Path -LiteralPath $full)) { continue }

    foreach ($file in @(Get-ChildItem -LiteralPath $full -Filter '*.yaml' -File -Recurse)) {

        $document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($file.FullName)) -Ordered

        # NOT EVERY SHIPPED YAML IS A SEQUENCE. os-releases.yaml, wizard.yaml,
        # rules.yaml and the rest have no top-level steps and are not asked to
        # stamp anything.
        if ($null -eq $document) { continue }
        if (-not ($document -is [System.Collections.IDictionary])) { continue }
        if (-not $document.Contains('steps')) { continue }

        $sink = @{
            StepName    = (New-Object -TypeName System.Collections.ArrayList)
            StepType    = (New-Object -TypeName System.Collections.ArrayList)
            FullOsGroup = (New-Object -TypeName System.Collections.ArrayList)
        }

        & $script:HDTTattooWalk -Node $document['steps'] -Sink $sink

        $script:HDTSequenceDocument += , @{
            Name        = $file.FullName.Substring($script:HDTRepoRoot.Length + 1)
            StepName    = [string[]] @($sink.StepName)
            StepType    = [string[]] @($sink.StepType)
            FullOsGroup = [string[]] @($sink.FullOsGroup)
            # Sysprep generalises the installation and CaptureImage writes the
            # .wim; either one means an image leaves this sequence.
            Captures    = @(@($sink.StepType) | Where-Object { $_ -eq 'Sysprep' -or $_ -like 'Capture*' }).Count -gt 0
        }
    }
}

$script:HDTCapturingSequence = @($script:HDTSequenceDocument | Where-Object { $_.Captures })
$script:HDTStampingSequence = @($script:HDTSequenceDocument |
        Where-Object { -not $_.Captures -and $_.FullOsGroup.Count -gt 0 })

Describe 'Shipped sequences: the deployment stamp' {

    # THE COUNTS COME IN AS TEST DATA. A $script: variable assigned while Pester
    # is DISCOVERING is $null by the time an It RUNS, and @($null).Count is 1 -
    # so the obvious guard passes without ever seeing the list it guards.
    # ShippedDocumentSchema records the same trap for the same reason.
    Context 'the discovery itself' {

        It 'finds the shipped sequence documents to judge' -ForEach @(@{
                DocumentCount = @($script:HDTSequenceDocument).Count
            }) {

            $DocumentCount | Should -BeGreaterThan 0
        }

        It 'classifies at least one sequence as one an image is captured from' -ForEach @(@{
                CapturingCount = @($script:HDTCapturingSequence).Count
            }) {

            # Without this, rule 1 below is vacuous and reference.yaml could
            # start stamping tomorrow with nothing to say so.
            $CapturingCount | Should -BeGreaterThan 0
        }

        It 'classifies at least one sequence as one that must stamp' -ForEach @(@{
                StampingCount = @($script:HDTStampingSequence).Count
            }) {

            # And without this, rules 2 and 3 are vacuous: a walk that
            # recognised no full-OS group would exempt every file and pass.
            $StampingCount | Should -BeGreaterThan 0
        }
    }

    Context 'a sequence an image is captured from stamps nothing' {

        It 'writes no Tattoo into <Name>' -ForEach $script:HDTCapturingSequence {

            $offender = @(0..($StepType.Count - 1) |
                    Where-Object { $StepType[$_] -eq 'Tattoo' } |
                    ForEach-Object { ('{0} / {1}' -f $Name, $StepName[$_]) })

            # WHICH TEMPLATE AND WHICH STEP, and the whole list rather than the
            # first - a template bug is usually a habit.
            ($offender -join ' | ') | Should -BeNullOrEmpty -Because (
                '{0} syspreps or captures, so a Tattoo would be baked into the image and would then describe the reference machine on every machine deployed from it' -f $Name)
        }
    }

    Context 'a sequence that runs in the full OS stamps the machine it built' {

        It 'stamps exactly once in <Name>' -ForEach $script:HDTStampingSequence {

            $tattoo = @(0..($StepType.Count - 1) | Where-Object { $StepType[$_] -eq 'Tattoo' })

            $tattoo.Count | Should -Be 1 -Because (
                '{0} runs a group in the full OS ({1}) and so must record what built the machine - MDT stamps every deployment it makes' -f
                $Name, ($FullOsGroup -join ', '))
        }

        It 'stamps before it patches or installs applications in <Name>' -ForEach $script:HDTStampingSequence {

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
}
