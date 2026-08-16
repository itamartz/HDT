# THE SUMMARY PAGE, AND IT IS A TEACHING SCREEN AS MUCH AS A CONFIRMATION.
#
# MDT's summary confirms what is about to happen. This one also answers the
# question every administrator asks after driving the wizard by hand twice:
# WHAT DO I PUT IN rules.yaml SO NOBODY HAS TO SEE THIS AGAIN?
#
# DESIGN 11.2 already says every page is individually skippable and that a page
# whose values are all supplied never appears. What it did not have was anywhere
# that TOLD a technician the variable names - so the skip model was documented
# and undiscoverable, and the only way to learn it was to read the design.
#
# So each row carries three things: what was chosen, THE VARIABLE THAT HOLDS IT,
# and the variable that hides the page it came from. The snippet at the end is
# those rows as rules.yaml, ready to paste.
#
# IT REPORTS, IT DOES NOT DECIDE. Nothing here resolves, validates or applies a
# value - Resolve-HDTVariable does that, and this would be a second opinion.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTSummaryTestPage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param()

        return @(
            [pscustomobject] @{
                Id      = 'TaskSequence'
                Title   = 'Task sequence'
                Collect = [pscustomobject] @{ Control = 'HDTTaskSequenceList'; Variable = 'HDTTaskSequenceID' }
                Skip    = 'HDTSkipTaskSequence'
            },
            [pscustomobject] @{
                Id      = 'ComputerName'
                Title   = 'Computer name'
                Collect = [pscustomobject] @{ Control = 'HDTComputerNameBox'; Variable = 'HDTComputerName' }
                Skip    = 'HDTSkipComputerName'
            },
            [pscustomobject] @{
                Id      = 'Summary'
                Title   = 'Summary'
                Skip    = 'HDTSkipSummary'
            })
    }

    $script:value = @{
        HDTTaskSequenceID = 'STD-CLIENT'
        HDTComputerName   = 'HDT-01'
    }
}

Describe 'Get-HDTWizardSummary' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTWizardSummary' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what the technician sees' {

        It 'has one row per page that collects something' {
            # The summary page itself collects nothing and is not a row about
            # itself.
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            @($summary.Row).Count | Should -Be 2
        }

        It 'keeps the pages in the order they were asked' {
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            (@($summary.Row | ForEach-Object { [string] $_.Setting }) -join ' > ') |
                Should -BeExactly 'Task sequence > Computer name'
        }

        It 'shows the value that was chosen' {
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] @($summary.Row)[1].Value | Should -BeExactly 'HDT-01'
        }

        It 'names the variable that holds it, which is the whole point' {
            # A summary that showed only 'Computer name: HDT-01' would confirm
            # the deployment and teach nothing. HDTComputerName is the thing an
            # administrator has to type into rules.yaml.
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] @($summary.Row)[1].Variable | Should -BeExactly 'HDTComputerName'
        }

        It 'names the variable that hides the page it came from' {
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] @($summary.Row)[1].Skip | Should -BeExactly 'HDTSkipComputerName'
        }

        It 'says so when a page collected nothing' {
            # An empty cell reads as a value of empty string. "not set" is a
            # different fact and the one that explains why the page appeared.
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value @{}

            [string] @($summary.Row)[0].Value | Should -BeExactly '(not set)'
        }
    }

    Context 'the snippet that makes the wizard disappear' {

        It 'is rules.yaml, not prose' {
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] $summary.Snippet | Should -BeLike '*rules:*'
            [string] $summary.Snippet | Should -BeLike '*set:*'
        }

        It 'carries every value that was chosen' {
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] $summary.Snippet | Should -BeLike '*HDTTaskSequenceID: STD-CLIENT*'
            [string] $summary.Snippet | Should -BeLike '*HDTComputerName: HDT-01*'
        }

        It 'sets HDTSkipWizard, because hiding every screen is what was asked for' {
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] $summary.Snippet | Should -BeLike '*HDTSkipWizard: true*'
        }

        It 'sets every page skip as well, not only the one that covers them all' {
            # WHY BOTH. HDTSkipWizard is one line and easy to get right; the
            # per-page keys are what a site edits when it wants to hide four
            # pages and keep two. A snippet with only the blunt one leaves an
            # administrator to guess that the fine-grained ones exist - which is
            # the same undiscoverability this whole screen exists to fix.
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] $summary.Snippet | Should -BeLike '*HDTSkipTaskSequence: true*'
            [string] $summary.Snippet | Should -BeLike '*HDTSkipComputerName: true*'
            [string] $summary.Snippet | Should -BeLike '*HDTSkipSummary: true*'
        }

        It 'includes the skip for a page that collects nothing, because it is still a page' {
            # The summary page has no value to set and still has to be hidden.
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] $summary.Snippet | Should -BeLike '*HDTSkipSummary: true*'
        }

        It 'says the Welcome screen is not in this file' {
            # THE CORRECTION WPF-FIRST ALREADY RECORDED. rules.yaml lives ON THE
            # SHARE, and the Welcome screen is what makes the share reachable -
            # so HDTSkipWelcome in this file is a rule the machine cannot read
            # until after the screen it was meant to skip has been shown. It
            # belongs in bootstrap.json, inside the boot image. An administrator
            # who pastes this and still meets a Welcome screen has to be told
            # why HERE, not in a document they have not opened.
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] $summary.Snippet | Should -BeLike '*bootstrap.json*'
        }
    }

    Context 'a page that fills in more than one variable' {

        # MDT'S COMPUTER DETAILS PANE COLLECTS FOUR THINGS AT LEAST - the name,
        # the domain or workgroup, the OU and the account that joins - so a page
        # that could name only one variable could not describe itself. Collect
        # takes a list, and a single declaration still works because @() around
        # one object is that object.

        BeforeAll {
            $script:multiPage = @(
                [pscustomobject] @{
                    Id      = 'ComputerDetail'
                    Title   = 'Computer details'
                    Skip    = 'HDTSkipComputerName'
                    Collect = @(
                        [pscustomobject] @{ Control = 'HDTComputerNameBox'; Variable = 'HDTComputerName' },
                        [pscustomobject] @{ Control = 'HDTJoinWorkgroupBox'; Variable = 'HDTJoinWorkgroup' },
                        [pscustomobject] @{ Control = 'HDTJoinDomainBox'; Variable = 'HDTJoinDomain' })
                })
        }

        It 'has a row for each one' {
            $summary = Get-HDTWizardSummary -Page $script:multiPage `
                -Value @{ HDTComputerName = 'HDT-01'; HDTJoinWorkgroup = 'WORKGROUP' }

            @($summary.Row).Count | Should -Be 3
        }

        It 'writes each one that was set into the snippet' {
            $summary = Get-HDTWizardSummary -Page $script:multiPage `
                -Value @{ HDTComputerName = 'HDT-01'; HDTJoinWorkgroup = 'WORKGROUP' }

            [string] $summary.Snippet | Should -BeLike '*HDTComputerName: HDT-01*'
            [string] $summary.Snippet | Should -BeLike '*HDTJoinWorkgroup: WORKGROUP*'
        }

        It 'leaves out the one that was not' {
            # A machine that joined a workgroup did not join a domain, and a
            # rule setting HDTJoinDomain to nothing would resolve the variable
            # and stop any later rule supplying a real one.
            $summary = Get-HDTWizardSummary -Page $script:multiPage `
                -Value @{ HDTComputerName = 'HDT-01'; HDTJoinWorkgroup = 'WORKGROUP' }

            [string] $summary.Snippet | Should -Not -BeLike '*HDTJoinDomain:*'
        }

        It 'writes the page skip once, not once per variable' {
            $summary = Get-HDTWizardSummary -Page $script:multiPage `
                -Value @{ HDTComputerName = 'HDT-01' }

            @([regex]::Matches([string] $summary.Snippet, 'HDTSkipComputerName')).Count | Should -Be 1
        }
    }

    Context 'one box that fills two variables' {

        # THE JOIN ACCOUNT IS TYPED ONCE - CORP\svc-hdt-join - and lands in
        # HDTDomainAdmin and HDTDomainAdminDomain. The summary has to write both
        # or the snippet is not the file that reproduces this deployment: a
        # rules.yaml with the account and no domain leaves the join to guess.

        BeforeAll {
            $script:splitPage = @(
                [pscustomobject] @{
                    Id      = 'ComputerDetail'
                    Title   = 'Join account'
                    Skip    = 'HDTSkipDomainMembership'
                    Collect = @(
                        [pscustomobject] @{
                            Control       = 'HDTDomainAdminBox'
                            Variable      = 'HDTDomainAdmin'
                            Split         = 'AccountName'
                            SplitVariable = 'HDTDomainAdminDomain'
                        })
                })
        }

        It 'writes both halves' {
            $summary = Get-HDTWizardSummary -Page $script:splitPage `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            [string] $summary.Snippet | Should -BeLike '*HDTDomainAdmin: svc-hdt-join*'
            [string] $summary.Snippet | Should -BeLike '*HDTDomainAdminDomain: CORP*'
        }

        It 'gives each half its own row' {
            $summary = Get-HDTWizardSummary -Page $script:splitPage `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            @($summary.Row).Count | Should -Be 2
        }

        It 'leaves the domain out when nothing supplied one' {
            $summary = Get-HDTWizardSummary -Page $script:splitPage -Value @{ HDTDomainAdmin = 'svc' }

            [string] $summary.Snippet | Should -Not -BeLike '*HDTDomainAdminDomain:*'
        }
    }

    Context 'a value that must never be printed' {

        # THE SUMMARY IS A SCREEN AND A SNIPPET TO COPY, and a domain join
        # password is neither. Get-HDTVariableMap already says of
        # HDTDomainAdminPassword: "never written to a log". A screen a
        # technician photographs and a YAML block they paste into a file that
        # lives on a share are both worse than a log.
        #
        # THE ROW STAYS. Hiding it entirely would leave an administrator
        # wondering whether the password had been collected at all - which is
        # the question they most need answered before pressing Deploy.

        BeforeAll {
            $script:secretPage = @(
                [pscustomobject] @{
                    Id      = 'ComputerDetail'
                    Title   = 'Domain account'
                    Collect = [pscustomobject] @{
                        Control  = 'HDTPasswordBox'
                        Variable = 'HDTDomainAdminPassword'
                        Property = 'Password'
                        IsSecret = $true
                    }
                    Skip    = 'HDTSkipDomainMembership'
                })
        }

        It 'says it was set without saying what it is' {
            $summary = Get-HDTWizardSummary -Page $script:secretPage `
                -Value @{ HDTDomainAdminPassword = 'Pa$$w0rd-nobody-should-read' }

            [string] @($summary.Row)[0].Value | Should -BeExactly '(set, not shown)'
        }

        It 'says nothing was set when nothing was' {
            $summary = Get-HDTWizardSummary -Page $script:secretPage -Value @{}

            [string] @($summary.Row)[0].Value | Should -BeExactly '(not set)'
        }

        It 'never puts the secret in the row, whatever the row is asked for' {
            $summary = Get-HDTWizardSummary -Page $script:secretPage `
                -Value @{ HDTDomainAdminPassword = 'Pa$$w0rd-nobody-should-read' }

            ($summary.Row | Out-String) | Should -Not -BeLike '*nobody-should-read*'
        }

        It 'never puts the secret in the snippet' {
            $summary = Get-HDTWizardSummary -Page $script:secretPage `
                -Value @{ HDTDomainAdminPassword = 'Pa$$w0rd-nobody-should-read' }

            [string] $summary.Snippet | Should -Not -BeLike '*nobody-should-read*'
        }

        It 'does not set the variable in the snippet at all' {
            # NOT EVEN EMPTY OR REDACTED. A rules.yaml carrying
            # HDTDomainAdminPassword: "" resolves the variable to nothing, so
            # every later rule that would have supplied it is skipped - and the
            # join fails with a password nobody set rather than one nobody
            # typed.
            $summary = Get-HDTWizardSummary -Page $script:secretPage `
                -Value @{ HDTDomainAdminPassword = 'Pa$$w0rd-nobody-should-read' }

            [string] $summary.Snippet | Should -Not -BeLike '*HDTDomainAdminPassword:*'
        }

        It 'says where the secret belongs instead' {
            # A blank where a password should be teaches nothing. The snippet
            # names the variable in a comment and says it is not written here.
            $summary = Get-HDTWizardSummary -Page $script:secretPage `
                -Value @{ HDTDomainAdminPassword = 'Pa$$w0rd-nobody-should-read' }

            [string] $summary.Snippet | Should -BeLike '*HDTDomainAdminPassword*'
            [string] $summary.Snippet | Should -BeLike '*#*'
        }
    }

    Context 'what it does not claim' {

        It 'does not promise that this file alone gives an unattended boot' {
            # THE HALF THIS FILE CANNOT DO. Get-HDTWizardPage honours every key
            # in the snippet, so the WIZARD disappears - but the Welcome screen
            # runs before the share is reachable and is governed by
            # bootstrap.json inside the boot image. An administrator who pastes
            # this, boots, and still meets a screen has to be told why here.
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value $script:value

            [string] $summary.Snippet | Should -BeLike '*bootstrap.json*'
            [string] $summary.Snippet | Should -Not -BeLike '*not yet*'
        }

        It 'omits a value nobody chose, rather than writing an empty one' {
            # A rule that sets HDTComputerName to nothing is worse than no rule:
            # it RESOLVES the variable, so every later rule that would have
            # supplied a real name is skipped (DESIGN 3.1, first match wins).
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value @{ HDTComputerName = 'HDT-01' }

            [string] $summary.Snippet | Should -Not -BeLike '*HDTTaskSequenceID:*'
            [string] $summary.Snippet | Should -BeLike '*HDTComputerName: HDT-01*'
        }

        It 'quotes a value that YAML would otherwise read as something else' -ForEach @(
            @{ Chosen = 'true'; Expect = '"true"' }
            @{ Chosen = '0123'; Expect = '"0123"' }
            @{ Chosen = 'yes'; Expect = '"yes"' }
            @{ Chosen = 'PC-%HDTSerialNumber%'; Expect = '"PC-%HDTSerialNumber%"' }) {

            # A snippet that is pasted and then does not parse - or worse,
            # parses as a boolean - is a snippet that cost an administrator an
            # afternoon.
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value @{ HDTComputerName = $Chosen }

            [string] $summary.Snippet | Should -BeLike ('*HDTComputerName: {0}*' -f $Expect)
        }

        It 'leaves a plain name unquoted, because noise is what stops a snippet being read' {
            $summary = Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value @{ HDTComputerName = 'HDT-01' }

            [string] $summary.Snippet | Should -BeLike '*HDTComputerName: HDT-01*'
        }
    }

    Context 'what it refuses' {

        It 'refuses no pages at all' {
            { Get-HDTWizardSummary -Page @() -Value $script:value } | Should -Throw
        }

        It 'accepts no values at all, because a summary of nothing chosen is still a summary' {
            { Get-HDTWizardSummary -Page (New-HDTSummaryTestPage) -Value @{} } | Should -Not -Throw
        }
    }
}
