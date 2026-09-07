# THE FULL-OS LEG COULD NOT SEE A SECRET AT ALL, AND THIS IS THE COMMAND THAT
# FIXES IT.
#
# WHAT WAS BROKEN. Start-HDTResume.ps1 - the RunOnce agent that runs every
# full-OS leg - built its variable bag from state.json and from NOTHING ELSE. It
# never read rules.yaml. Save-HDTRunState writes '(set, not shown)' in place of
# every secret on the way to that file, and DESIGN 4.5.2's LSA secret bag cannot
# cross the WinPE -> full-OS boundary because WinPE's LSA is a RAM disk. So a
# secret that a full-OS step needed arrived as the redaction on a NewComputer
# run, always, with no source able to supply it:
#
#   * Invoke-HDTJoinDomainStep refused, which is why JoinDomain had never joined
#     a real domain;
#   * AD-DC-2025's promotion refused on HDTDsrmPassword for the same reason.
#
# Both refusals were CORRECT. The missing piece was a source, and rules.yaml is
# the source DESIGN 4.5.2 names.
#
# WHY A COMMAND RATHER THAN A DOZEN LINES IN THE PAYLOAD. Start-HDTResume.ps1 is
# tested by parsing it, not by running it (see StartHDTResumePayload.Tests.ps1),
# so logic placed there cannot be proven against a fake at all. The payload
# already reaches the engine through the module manifest; this is one more
# public command it calls, and every decision it makes is asserted here.
#
# THE PRECEDENCE IS Restore-HDTSecretBag's, DELIBERATELY WORD FOR WORD: a name
# is filled in only when it is MISSING, EMPTY, or holding the REDACTION. A live
# value always wins, because state.json is what the run already decided and
# rules.yaml is a lower-precedence source that the wizard and the machine
# override already beat once, on leg one.
#
# AND THE FACTS COME OUT OF THE BAG, NOT OFF THIS MACHINE. Re-gathering in the
# full OS would resolve the rules against DIFFERENT facts than leg one used -
# the OS has changed underneath the run - so a rule keyed on HDTOSVersion or
# HDTIsUEFI could answer differently on the second reading than on the first.
# Leg one's facts are already in the bag, so they are what this re-resolution is
# given, and the answer is the answer leg one would have got.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:rulesPath = 'C:\HDTLab\does-not-exist\ws\rules.yaml'

    # The redaction from the one place that defines it, so this file cannot
    # drift from Protect-HDTSecretValue by holding a second copy of the literal.
    $script:redaction = [string] (& (Get-Module Hephaestus) {
            Protect-HDTSecretValue -Name 'HDTAdminPassword' -Value 'a set value' })

    function New-HDTTestRuleDocument {
        <#
            .SYNOPSIS
                Turns rules.yaml text into the document Resolve-HDTVariable
                consumes, through the real importer and a fake filesystem.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory document for a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [string] $Yaml
        )

        $fs = New-HDTFakeFileSystem -File @{ $script:rulesPath = $Yaml }
        return (Import-HDTRuleDocument -Path $script:rulesPath -FileSystem $fs)
    }

    # A bag shaped like the one Start-HDTResume rehydrates from state.json:
    # ordered, case-insensitive, and carrying leg one's facts alongside its
    # answers.
    function New-HDTTestResumedBag {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory dictionary for a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([System.Collections.Specialized.OrderedDictionary])]
        param([Parameter()] [hashtable] $Extra)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['HDTComputerName'] = 'HDT-M6-DC01'
        $bag['HDTIsUEFI'] = 'True'

        if ($PSBoundParameters.ContainsKey('Extra')) {
            foreach ($key in @($Extra.Keys)) { $bag[[string] $key] = $Extra[$key] }
        }

        return $bag
    }
}

Describe 'Restore-HDTRuleVariable' {

    Context 'the redaction a resumed leg rehydrated' {

        It 'fills a secret back in from the fallback rule' {
            # THE WHOLE POINT OF THE COMMAND, in one assertion. Leg one resolved
            # HDTDsrmPassword from rules.yaml; the checkpoint replaced it with
            # the redaction; this leg gets the value back from the same rule.
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDsrmPassword: a-lab-dsrm-value
'@
            $bag = New-HDTTestResumedBag -Extra @{ HDTDsrmPassword = $script:redaction }

            $filled = @(Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag)

            [string] $bag['HDTDsrmPassword'] | Should -Be 'a-lab-dsrm-value'
            $filled | Should -Contain 'HDTDsrmPassword'
        }

        It 'fills the join credential back in, which is what JoinDomain refused on' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDomainAdminPassword: a-lab-join-value
'@
            $bag = New-HDTTestResumedBag -Extra @{ HDTDomainAdminPassword = $script:redaction }

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag | Out-Null

            [string] $bag['HDTDomainAdminPassword'] | Should -Be 'a-lab-join-value'
        }

        It 'mutates the bag in place rather than returning a copy' {
            # The execution context hands THIS object to every step, so a
            # command that replaced it would leave the steps reading the old one
            # - the same reason Restore-HDTSecretBag mutates.
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDsrmPassword: in-place
'@
            $bag = New-HDTTestResumedBag -Extra @{ HDTDsrmPassword = $script:redaction }
            $same = $bag

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag | Out-Null

            [string] $same['HDTDsrmPassword'] | Should -Be 'in-place'
        }
    }

    Context 'the live leg wins, always' {

        It 'leaves a real value alone even when a rule offers another' {
            # state.json is what the run ALREADY DECIDED - a wizard answer, a
            # machine override, a SetVariable step. rules.yaml lost to all three
            # on leg one and must not win them back on leg two.
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTTaskSequenceID: RULE-CLIENT
'@
            $bag = New-HDTTestResumedBag -Extra @{ HDTTaskSequenceID = 'WIZARD-CLIENT' }

            $filled = @(Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag)

            [string] $bag['HDTTaskSequenceID'] | Should -Be 'WIZARD-CLIENT'
            $filled | Should -Not -Contain 'HDTTaskSequenceID'
        }

        It 'reports nothing filled when the bag already holds every answer' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTTaskSequenceID: RULE-CLIENT
'@
            $bag = New-HDTTestResumedBag -Extra @{ HDTTaskSequenceID = 'WIZARD-CLIENT' }

            @(Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag).Count | Should -Be 0
        }
    }

    Context 'missing and empty names' {

        It 'fills a name the checkpoint did not carry at all' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDomainAdmin: Administrator
'@
            $bag = New-HDTTestResumedBag

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag | Out-Null

            [string] $bag['HDTDomainAdmin'] | Should -Be 'Administrator'
        }

        It 'fills a name the checkpoint carried empty' {
            # An empty value in the bag cannot be a technician's answer that beat
            # a rule: Resolve-HDTVariable lets the rule win where a wizard box
            # was left blank, so an empty here means the rule was empty too on
            # leg one and refilling it is a no-op or a correction.
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDomainAdmin: Administrator
'@
            $bag = New-HDTTestResumedBag -Extra @{ HDTDomainAdmin = '' }

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag | Out-Null

            [string] $bag['HDTDomainAdmin'] | Should -Be 'Administrator'
        }
    }

    Context 'the facts are leg ones, not this machines' {

        It 'resolves a conditional rule against the facts in the bag' {
            # THE DRIFT THIS PREVENTS. A rule keyed on a fact would answer
            # differently if the full OS were re-gathered, because the OS has
            # changed underneath the run since leg one read it. The bag carries
            # leg one's facts, so the rules see what they saw the first time.
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: UEFI machines
    when: { HDTIsUEFI: "True" }
    set:
      HDTDsrmPassword: uefi-value
  - name: Default
    set:
      HDTDsrmPassword: bios-value
'@
            $bag = New-HDTTestResumedBag -Extra @{ HDTDsrmPassword = $script:redaction }

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag | Out-Null

            [string] $bag['HDTDsrmPassword'] | Should -Be 'uefi-value'
        }
    }

    Context 'the engine-owned names in the bag' {

        It 'fills a secret even though the bag carries _HDT* names' {
            # THE DEFECT THIS CAUGHT, ON REAL HARDWARE, 2026-09-07.
            #
            # A resumed leg's bag carries the engine's own variables - _HDTRunId
            # and _HDTLogPath are in every state.json - and Add-HDTResolvedVariable
            # REFUSES any attempt to assign a _HDT* name: "engine-owned and cannot
            # be assigned". Handing the whole bag to Resolve-HDTVariable as -Fact
            # is such an attempt, so the resolution threw, the fill-in caught it
            # and filled nothing, and AD-DC-2025's promotion refused on the
            # redaction three legs later - the exact failure this command exists
            # to prevent, reintroduced by the command itself.
            #
            # The engine publishes those names on every leg, so they are never
            # something the rules need to supply; dropping them from the FACTS
            # loses nothing and is what lets the rules resolve at all.
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDsrmPassword: a-lab-dsrm-value
'@
            $bag = New-HDTTestResumedBag -Extra @{
                HDTDsrmPassword = $script:redaction
                _HDTRunId       = 'run-20260907-215358'
                _HDTLogPath     = 'C:\HDT\Logs'
            }

            $filled = @(Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag)

            [string] $bag['HDTDsrmPassword'] | Should -Be 'a-lab-dsrm-value'
            $filled | Should -Contain 'HDTDsrmPassword'
        }

        It 'leaves the engine-owned names exactly as the engine set them' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDsrmPassword: a-lab-dsrm-value
'@
            $bag = New-HDTTestResumedBag -Extra @{
                HDTDsrmPassword = $script:redaction
                _HDTRunId       = 'run-20260907-215358'
            }

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag | Out-Null

            [string] $bag['_HDTRunId'] | Should -Be 'run-20260907-215358'
        }
    }

    Context 'it never takes a run down' {

        It 'returns empty and changes nothing when there is no rule document' {
            # Same promise Restore-HDTSecretBag makes: this runs at the start of
            # every full-OS leg, on machines in states nobody anticipated, and a
            # leg that died in its own recovery mechanism would be worse than the
            # value being missing. The step that needs it refuses THERE, naming
            # the variable, where an administrator can act on it.
            $bag = New-HDTTestResumedBag -Extra @{ HDTDsrmPassword = $script:redaction }

            $filled = @(Restore-HDTRuleVariable -RuleDocument $null -Variable $bag)

            $filled.Count | Should -Be 0
            [string] $bag['HDTDsrmPassword'] | Should -Be $script:redaction
        }
    }

    Context 'the value is never logged' {

        It 'names the variable and never prints what it put back' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDsrmPassword: never-print-me
'@
            $bag = New-HDTTestResumedBag -Extra @{ HDTDsrmPassword = $script:redaction }

            $fileSystem = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]'2026-09-07T00:00:00Z')
            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Debug

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $bag -LogContext $log | Out-Null

            $written = ($fileSystem.File.Values -join "`n")

            $written | Should -BeLike '*HDTDsrmPassword*'
            $written | Should -Not -BeLike '*never-print-me*'
        }
    }
}
