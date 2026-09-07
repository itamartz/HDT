# THE TWO SEQUENCES THAT WILL GIVE JoinDomain ITS ONLY HARDWARE EVIDENCE, AND
# THE LAB RULES THEY ARE NOT ALLOWED TO BREAK ON THE WAY.
#
# JoinDomain is the last v1 step type verified against a fake and nothing else -
# ROADMAP names it, DESIGN 4.2 says so in the step's own help, and PROJECT.md
# records why: the lab's domain controller was retired on 2026-08-29 and
# _ldap._tcp resolves to nothing. AD-DC-2025 builds a controller and AD-JOIN
# joins a machine to it.
#
# THESE ARE LAB SEQUENCES, SO THE RULES HERE ARE LAB RULES. They are written
# over the SET - every sequence under tests/e2e/payload that does the thing in
# question - rather than over the two files that prompted them, because a rule
# that names AD-DC-2025 passes for AD-DC-2025 and fails nobody after it
# (CLAUDE.md rule 8).
#
# WHAT EACH RULE IS PROTECTING, and none of them is hypothetical:
#
#   * NOTHING IN THIS LAB SERVES DHCP. CLAUDE.md: the lab network is
#     192.168.1.0/24 and DHCP comes from the real LAN. A domain controller
#     build is exactly where somebody adds the DHCP role out of habit - it is
#     the second half of every "build a lab domain" article on the internet -
#     and a second DHCP server on a bridged segment answers the user's own
#     machines, not just ours. The role is refused here rather than discovered
#     when somebody's laptop gets a lease from a test VM.
#
#   * NOTHING IN THIS LAB ASSIGNS AN IP ADDRESS OR MAKES A SWITCH. Same rule,
#     the other half: 'Never assign, create or use another subnet without
#     asking'. That rule was written because inventing 10.10.10.0/24 collided
#     with a VMware adapter already holding 10.10.10.1. A payload script is a
#     place that rule could be broken silently, so the scripts are read.
#
#   * THE DOMAIN NAME CANNOT COLLIDE WITH A REAL ONE. '.test' is reserved by
#     RFC 2606 for exactly this and can never be delegated. '.local' is the one
#     to avoid: it is mDNS (RFC 6762), so a '.local' AD zone fights Bonjour and
#     every Apple device on the segment, and Microsoft has advised against it
#     since Windows 2000.
#
#   * A PROMOTION IS FOLLOWED BY A RESTART AND THEN BY A CHECK. Install-ADDSForest
#     leaves a server that IS NOT YET A DOMAIN CONTROLLER until it reboots -
#     NTDS, Netlogon, SYSVOL and the SRV records all arrive on the way back up.
#     A sequence that promoted and then asserted anything would assert it
#     against a server that had not finished, and a sequence that promoted and
#     stopped would report success for a machine with no directory on it.
#
#   * A JOIN IS PRECEDED BY POINTING DNS AT THE CONTROLLER. This is THE failure
#     of a first domain join and it is silent in the worst way: the client holds
#     a DHCP lease from the home router, whose DNS server is the router, which
#     has never heard of the AD zone. NetJoinDomain then fails with an error
#     about the domain not being found - which reads as a wrong domain name, a
#     wrong password, a dead controller, anything but DNS.
#
#   * NO SEQUENCE DOCUMENT CARRIES A PASSWORD. sequence.yaml is printed into a
#     text box in the console, quoted back in refusals and stored on a share
#     every machine being deployed can read (Invoke-HDTJoinDomainStep says so at
#     length, and it is why that step has no password property). A DSRM password
#     typed into a variables: block would be the same leak by another door.

$script:HDTRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name powershell-yaml -ErrorAction Stop

$script:HDTDomainPayloadRoot = Join-Path -Path $script:HDTRepoRoot -ChildPath 'tests/e2e/payload'

# Document order, groups recursed into before the entry's own type is read, so
# what comes out is the order the engine executes in - the same walk
# ShippedSequenceTattoo and LabPayloadSequence use.
$script:HDTDomainWalk = {
    param($Node, $Sink)

    foreach ($current in @($Node)) {
        if ($null -eq $current) { continue }
        if (-not ($current -is [System.Collections.IDictionary])) { continue }

        if ($current.Contains('steps')) { & $script:HDTDomainWalk -Node $current['steps'] -Sink $Sink }

        if (-not $current.Contains('type')) { continue }

        $stepName = '(unnamed)'
        if ($current.Contains('name')) { $stepName = [string] $current['name'] }

        $script = ''
        if ($current.Contains('script')) { $script = [string] $current['script'] }

        $feature = @()
        if ($current.Contains('features')) {
            $raw = $current['features']
            if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
                $feature = [string[]] @(@($raw) | ForEach-Object { [string] $_ })
            } else {
                $feature = [string[]] @(@(([string] $raw) -split '[,;]') | ForEach-Object { $_.Trim() })
            }
        }

        [void] $Sink.Add([pscustomobject] @{
                Name    = $stepName
                Type    = [string] $current['type']
                Script  = $script
                Feature = [string[]] $feature
                Domain  = $(if ($current.Contains('domain')) { [string] $current['domain'] } else { '' })
                Retry   = $(if ($current.Contains('retry') -and $null -ne $current['retry']) { $true } else { $false })
            })
    }
}

$script:HDTDomainDocument = @()

foreach ($file in @(Get-ChildItem -LiteralPath $script:HDTDomainPayloadRoot -Filter 'sequence.yaml' -File -Recurse)) {

    $document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($file.FullName)) -Ordered

    if ($null -eq $document) { continue }
    if (-not ($document -is [System.Collections.IDictionary])) { continue }
    if (-not $document.Contains('steps')) { continue }

    $sink = New-Object -TypeName System.Collections.ArrayList
    & $script:HDTDomainWalk -Node $document['steps'] -Sink $sink

    $variable = [ordered] @{}
    if ($document.Contains('variables') -and $null -ne $document['variables']) {
        foreach ($key in @($document['variables'].Keys)) { $variable[[string] $key] = $document['variables'][$key] }
    }

    $script:HDTDomainDocument += , @{
        Name     = $file.FullName.Substring($script:HDTRepoRoot.Length + 1)
        Folder   = $file.DirectoryName
        Id       = [string] $document['id']
        Variable = $variable
        Step     = @($sink)
        # Install-ADDSForest is the only way a forest is created, so the script
        # that names it is what marks a sequence as one that promotes.
        Promotes = @(@($sink) | Where-Object {
                $_.Type -eq 'PowerShell' -and $_.Script -match '(?i)forest'
            }).Count -gt 0
        Joins    = @(@($sink) | Where-Object { $_.Type -eq 'JoinDomain' }).Count -gt 0
    }
}

$script:HDTPromotingSequence = @($script:HDTDomainDocument | Where-Object { $_.Promotes })
$script:HDTJoiningSequence = @($script:HDTDomainDocument | Where-Object { $_.Joins })

# Every .ps1 a lab sequence folder ships, PARSED. The networking rules below are
# about what these scripts DO, and they are the only place in the payload tree
# where a line of PowerShell runs on a real machine.
#
# BY AST AND NOT BY GREP, and the first draft of this file was a grep and failed
# its own subjects for it. Every one of these scripts NAMES New-NetIPAddress in
# its header, in a sentence explaining that it does not call it and why -
# which is exactly the comment that should be there. A rule about what a script
# calls has to read the calls.
$script:HDTPayloadScript = @(Get-ChildItem -LiteralPath $script:HDTDomainPayloadRoot -Filter '*.ps1' -File -Recurse |
        ForEach-Object {

            $parseError = $null
            $token = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref] $token, [ref] $parseError)

            $called = @()
            if ($null -ne $ast) {
                $called = [string[]] @($ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst]
                        }, $true) | ForEach-Object { [string] $_.GetCommandName() } | Where-Object { $_ })
            }

            # EVERY BRANCH THAT RECOGNISES THE REDACTION SENTINEL, and whether
            # that branch records a problem or just carries on.
            #
            # Save-HDTRunState writes '(set, not shown)' over every secret on
            # the way to state.json, so a resumed leg can hold the words instead
            # of the value. A script that NOTICES that and then continues as
            # though nothing happened is the failure this looks for: on
            # 2026-09-07 Test-DomainMembership.ps1 skipped its whole directory
            # check on that condition, printed 'SKIPPED', and returned success -
            # a verification that silently reduced its own scope and stayed
            # green, which reads exactly like a verification that passed.
            $redactionBlind = @()

            if ($null -ne $ast) {
                foreach ($ifAst in @($ast.FindAll({
                                param($node)
                                $node -is [System.Management.Automation.Language.IfStatementAst]
                            }, $true))) {

                    foreach ($clause in @($ifAst.Clauses)) {

                        if ([string] $clause.Item1.Extent.Text -notmatch [regex]::Escape('(set, not shown)')) { continue }

                        # Recording a problem or throwing are the two honest
                        # endings. Anything else is a skip that reports success.
                        if ([string] $clause.Item2.Extent.Text -match '(?i)Problem\.Add|\bthrow\b') { continue }

                        $redactionBlind += ('line {0}' -f $clause.Item1.Extent.StartLineNumber)
                    }
                }
            }

            @{
                Name           = $_.FullName.Substring($script:HDTRepoRoot.Length + 1)
                Called         = [string[]] $called
                Text           = [string] [System.IO.File]::ReadAllText($_.FullName)
                RedactionBlind = [string[]] $redactionBlind
                # A parse error means nothing below judged anything, so it is
                # reported as itself rather than as a script that calls nothing.
                Unparsed       = [string] (@(@($parseError) | ForEach-Object { [string] $_.Message }) -join ' | ')
            }
        })

Describe 'The lab domain sequences' {

    Context 'the discovery itself' {

        It 'finds a lab sequence that promotes a forest' -ForEach @(@{
                PromotingCount = @($script:HDTPromotingSequence).Count
            }) {

            # Without this every promotion rule below is vacuous and would pass
            # on a repository with no domain controller sequence in it at all.
            $PromotingCount | Should -BeGreaterThan 0
        }

        It 'finds a lab sequence that joins a domain' -ForEach @(@{
                JoiningCount = @($script:HDTJoiningSequence).Count
            }) {

            $JoiningCount | Should -BeGreaterThan 0
        }

        It 'finds the scripts those sequences run' -ForEach @(@{
                ScriptCount = @($script:HDTPayloadScript).Count
            }) {

            $ScriptCount | Should -BeGreaterThan 0
        }
    }

    Context 'nothing in this lab competes with the LAN it is bridged to' {

        It 'installs no DHCP server role in <Name>' -ForEach $script:HDTDomainDocument {

            $offender = @(@($Step) | Where-Object {
                    $_.Type -eq 'InstallRoles' -and
                    @($_.Feature | Where-Object { $_ -match '(?i)^DHCP' }).Count -gt 0
                } | ForEach-Object { '{0} ({1})' -f $_.Name, ($_.Feature -join ', ') })

            ($offender -join ' | ') | Should -BeNullOrEmpty -Because (
                'DHCP on 192.168.1.0/24 belongs to the home router. A second server on a bridged segment answers the machines this repository does not own, which is the blast radius CLAUDE.md draws around the whole lab')
        }

        It 'assigns no address and creates no switch in <Name>' -ForEach $script:HDTPayloadScript {

            # Set-DnsClientServerAddress is NOT here, and the distinction is the
            # point: pointing a resolver at a server changes name resolution and
            # nothing about addressing. Assigning an address, or making a switch
            # to put it on, is what CLAUDE.md says to ask about first.
            $forbidden = @(
                'New-NetIPAddress', 'Set-NetIPAddress', 'Remove-NetIPAddress',
                'New-VMSwitch', 'Set-VMSwitch', 'Remove-VMSwitch',
                'New-NetNat', 'Add-DhcpServerv4Scope', 'Install-WindowsFeature'
            )

            $found = @(@($Called) | Where-Object { $forbidden -contains $_ } | Sort-Object -Unique)

            $Unparsed | Should -BeNullOrEmpty -Because (
                '{0} has to parse before anything can be said about what it calls' -f $Name)

            ($found -join ', ') | Should -BeNullOrEmpty -Because (
                '{0} runs on a VM bridged to the user''s own LAN. Addressing comes from that LAN''s DHCP, and roles come from the InstallRoles step so the sequence log names what was installed' -f $Name)
        }
    }

    Context 'the domain name cannot collide with a real one' {

        It 'names a reserved domain in <Name>' -ForEach $script:HDTDomainDocument {

            $named = @(@($Variable.Keys) | Where-Object { $_ -match '(?i)DnsName$|JoinDomain$' } |
                    ForEach-Object { [string] $Variable[$_] }) +
            @(@($Step) | Where-Object { $_.Type -eq 'JoinDomain' -and $_.Domain -ne '' } |
                    ForEach-Object { $_.Domain })

            $bad = New-Object -TypeName System.Collections.ArrayList

            foreach ($candidate in @($named)) {
                # A %token% is resolved from rules.yaml at run time and is not a
                # name this file can judge.
                if ($candidate -match '^%.*%$') { continue }
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

                if ($candidate -match '(?i)\.local$') {
                    [void] $bad.Add(('{0}: ''{1}'' ends in .local, which is mDNS (RFC 6762)' -f $Name, $candidate))
                    continue
                }

                if ($candidate -notmatch '(?i)\.test$') {
                    [void] $bad.Add(('{0}: ''{1}'' is not under .test, the TLD RFC 2606 reserves and no registry can delegate' -f $Name, $candidate))
                }
            }

            ($bad -join ' | ') | Should -BeNullOrEmpty -Because (
                'this domain exists on a segment bridged to a real LAN with real name resolution on it')
        }
    }

    Context 'a promotion finishes before anything believes it' {

        It 'restarts after promoting in <Name>' -ForEach $script:HDTPromotingSequence {

            $type = [string[]] @(@($Step) | ForEach-Object { $_.Type })
            $promoteAt = [array]::IndexOf(
                [string[]] @(@($Step) | ForEach-Object { $_.Script }),
                @(@($Step) | Where-Object { $_.Type -eq 'PowerShell' -and $_.Script -match '(?i)forest' })[0].Script)

            $restartAfter = @($promoteAt..($type.Count - 1) | Where-Object { $type[$_] -eq 'Restart' })

            @($restartAfter).Count | Should -BeGreaterThan 0 -Because (
                'Install-ADDSForest leaves a server that is not a domain controller until it reboots - NTDS, Netlogon, SYSVOL and the SRV records all arrive on the way back up')
        }

        It 'verifies the directory after that restart in <Name>' -ForEach $script:HDTPromotingSequence {

            $type = [string[]] @(@($Step) | ForEach-Object { $_.Type })
            $script = [string[]] @(@($Step) | ForEach-Object { $_.Script })

            $promoteAt = [array]::IndexOf($script,
                @(@($Step) | Where-Object { $_.Type -eq 'PowerShell' -and $_.Script -match '(?i)forest' })[0].Script)

            $restartAt = @($promoteAt..($type.Count - 1) | Where-Object { $type[$_] -eq 'Restart' })[0]

            $verifyAfter = @($restartAt..($type.Count - 1) |
                    Where-Object { $type[$_] -eq 'PowerShell' -and $script[$_] -match '(?i)Test-' })

            @($verifyAfter).Count | Should -BeGreaterThan 0 -Because (
                'a sequence that promoted and stopped reports success for a machine nobody has asked a single directory question of')
        }
    }

    Context 'a join is preceded by pointing DNS at the controller' {

        It 'sets the resolver before it joins in <Name>' -ForEach $script:HDTJoiningSequence {

            $type = [string[]] @(@($Step) | ForEach-Object { $_.Type })
            $script = [string[]] @(@($Step) | ForEach-Object { $_.Script })

            $joinAt = [array]::IndexOf($type, 'JoinDomain')

            $dnsBefore = @(0..($joinAt - 1) |
                    Where-Object { $type[$_] -eq 'PowerShell' -and $script[$_] -match '(?i)Dns' })

            @($dnsBefore).Count | Should -BeGreaterThan 0 -Because (
                'the client holds a lease from the home router, whose DNS server is the router, which has never heard of the AD zone - and the join then fails with a message about the domain not being found, which reads as anything but DNS')
        }

        It 'names the domain by variable rather than by literal in <Name>' -ForEach $script:HDTJoiningSequence {

            $join = @(@($Step) | Where-Object { $_.Type -eq 'JoinDomain' })[0]

            $join.Domain | Should -Match '^%.+%$' -Because (
                'the domain a machine joins is a per-site fact that belongs in rules.yaml with its provenance recorded, not baked into a sequence document copied between labs')
        }
    }

    Context 'no sequence document carries a secret' {

        It 'declares no password, key or credential in <Name>' -ForEach $script:HDTDomainDocument {

            $offender = @(@($Variable.Keys) |
                    Where-Object { $_ -match '(?i)password|passphrase|secret|credential|productkey|apikey|pin$|token$' })

            ($offender -join ', ') | Should -BeNullOrEmpty -Because (
                'sequence.yaml is printed into the console, quoted back in refusals and stored on a share every machine being deployed can read. A secret belongs in rules.yaml or a machine document, where Test-HDTSecretVariable redacts it everywhere it is written down')
        }
    }

    Context 'a verification never quietly reduces its own scope' {

        It 'records a problem where it recognises a redacted secret in <Name>' -ForEach $script:HDTPayloadScript {

            # THE SHAPE OF THE 2026-09-07 DEFECT, WRITTEN AS A RULE OVER EVERY
            # PAYLOAD SCRIPT rather than over the one that had it. A resumed leg
            # rehydrates its bag from state.json, where every secret is the
            # words '(set, not shown)'. Restore-HDTRuleVariable refills them
            # from rules.yaml now, so a script that sees the sentinel is seeing
            # a recovery that did not work - which is a finding, not a licence
            # to check less and pass anyway.
            $Unparsed | Should -BeNullOrEmpty -Because (
                '{0} has to parse before anything can be said about its branches' -f $Name)

            ($RedactionBlind -join ', ') | Should -BeNullOrEmpty -Because (
                '{0} notices the redaction and then neither records a problem nor throws. A check that quietly narrows itself and stays green is indistinguishable from a check that passed, which is worse than not having it' -f $Name)
        }

        It 'asserts machine identity rather than a name in <Name>' -ForEach $script:HDTPayloadScript {

            # A DIRECTORY SEARCH BY cn= FINDS AN OBJECT WITH THAT NAME - not
            # this machine's account. The stale-computer-account failure these
            # scripts exist to catch leaves exactly that: an object named
            # HDT-M6-CL01 that a domain admin can read, belonging to a machine
            # that cannot authenticate. objectSid or objectGUID is what tells
            # the live account from the leftover, so a script that reads the
            # directory has to compare one of them.
            $searches = $Text -match '(?i)DirectorySearcher|ADSISearcher'
            $identity = $Text -match '(?i)objectSid|objectGUID'

            (-not $searches -or $identity) | Should -BeTrue -Because (
                '{0} reads the directory. A cn= match proves the directory holds AN object with this machine''s name; only a SID or GUID comparison proves it holds THIS machine''s account' -f $Name)
        }
    }

    Context 'a retry belongs on an action, never on an assertion' {

        It 'puts no retry on a verification step in <Name>' -ForEach $script:HDTDomainDocument {

            # A RETRY ON AN ACTION MEANS 'DO IT UNTIL IT TAKES'. A RETRY ON AN
            # ASSERTION MEANS 'IT HELD AT LEAST ONCE IN THREE', which is not the
            # claim any of these steps is making, and it hides how long the
            # machine really took to get there.
            #
            # The repository already has the honest shape for a check that must
            # tolerate a settling machine: AD-DC-2025's Test-DomainControllerReady.ps1
            # polls INSIDE itself against a deadline and logs every attempt with
            # its elapsed time, so the log says the directory came up at 41
            # seconds instead of saying attempt two passed.
            $offender = @(@($Step) | Where-Object {
                    $_.Type -eq 'PowerShell' -and $_.Retry -and
                    (Split-Path -Path $_.Script -Leaf) -match '(?i)^Test-'
                } | ForEach-Object { $_.Name })

            ($offender -join ', ') | Should -BeNullOrEmpty -Because (
                'the engine retrying an assertion turns "this held" into "this held at least once", and a verification that passes on attempt three of three has found a machine that took a minute to become a member without ever saying so. A check that must wait, waits inside itself and logs each attempt')
        }
    }
}
