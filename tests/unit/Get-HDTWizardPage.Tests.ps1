# WHICH PAGES THIS DEPLOYMENT STILL HAS TO ASK.
#
# THE KEYS EXISTED AND NOTHING READ THEM. HDTSkipWizard appeared only in the MDT
# name map and in error text; HDTSkipTaskSequence, HDTSkipComputerName and
# HDTSkipSummary appeared nowhere in src/ at all. Only the Welcome screen was
# skippable, from bootstrap.json. So the summary page could tell an
# administrator what to set, and setting it did nothing - which is worse than
# not telling them, because they would go to a bench and watch a wizard appear
# anyway.
#
# THE SKIP VARIABLE DECIDES, NOT THE PRESENCE OF A VALUE, and that is MDT's
# behaviour: OSDComputerName being set does not hide the page, SkipComputerName
# does. It matters because a prefilled page a technician CONFIRMS is a real
# workflow - "a pane with the answer already in it is a statement worth
# reading" - and a page that vanished as soon as a rule guessed a name would
# take that away. DESIGN 11.2 said both things in two paragraphs; it says this
# one now.
#
# A SKIPPED PAGE WHOSE VALUE IS MISSING IS AN ERROR, NOT A PROMPT. DESIGN 11.2,
# in those words. Showing it anyway would produce a deployment nobody can
# reproduce; inventing a value would produce a machine nobody named.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTCataloguePage {
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
                Id      = 'ComputerDetail'
                Title   = 'Computer details'
                Collect = [pscustomobject] @{ Control = 'HDTComputerNameBox'; Variable = 'HDTComputerName' }
                Skip    = 'HDTSkipComputerName'
            },
            [pscustomobject] @{
                Id    = 'Summary'
                Title = 'Summary'
                Skip  = 'HDTSkipSummary'
            })
    }

    $script:supplied = @{
        HDTTaskSequenceID = 'STD-CLIENT'
        HDTComputerName   = 'HDT-01'
    }
}

Describe 'Get-HDTWizardPage' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTWizardPage' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'nothing set' {

        It 'asks every page when no rule says otherwise' {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) -Variable @{}

            @($result.Page).Count | Should -Be 3
        }

        It 'keeps the catalogue order' {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) -Variable @{}

            (@($result.Page | ForEach-Object { [string] $_.Id }) -join ',') |
                Should -BeExactly 'TaskSequence,ComputerDetail,Summary'
        }

        It 'skips nothing' {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) -Variable @{}

            @($result.Skipped) | Should -BeNullOrEmpty
        }
    }

    Context 'a value being supplied is not a reason to hide a page' {

        It 'still asks a page whose value a rule already supplied' {
            # MDT's behaviour, and the reason for it: a prefilled page the
            # technician CONFIRMS is a real workflow. A page that vanished as
            # soon as a rule guessed a name would take that away, and a guessed
            # name is exactly the one worth confirming - SPIKES S9.11's machine
            # was named by a rule nobody checked.
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) -Variable $script:supplied

            @($result.Page).Count | Should -Be 3
        }
    }

    Context 'one page at a time' {

        It 'skips a page whose own key is set' {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                -Variable ($script:supplied + @{ HDTSkipComputerName = $true })

            (@($result.Page | ForEach-Object { [string] $_.Id }) -join ',') |
                Should -BeExactly 'TaskSequence,Summary'
        }

        It 'records what skipped it, so a technician can ask why a page never appeared' {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                -Variable ($script:supplied + @{ HDTSkipComputerName = $true })

            [string] @($result.Skipped)[0].Id | Should -BeExactly 'ComputerDetail'
            [string] @($result.Skipped)[0].Rule | Should -BeExactly 'HDTSkipComputerName'
        }

        It 'reads <_> as true, because YAML and rules deliver both' -ForEach @($true, 'true', 'True', 'YES', 'yes', '1') {
            # rules.yaml gives a real boolean; a command line or a machine
            # override can give a string. A skip that silently did not apply
            # because it arrived as text is a wizard appearing on a machine
            # nobody is standing at.
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                -Variable ($script:supplied + @{ HDTSkipSummary = $PSItem })

            @($result.Page | Where-Object { $_.Id -eq 'Summary' }) | Should -BeNullOrEmpty
        }

        It 'reads <_> as false' -ForEach @($false, 'false', 'no', '0', '') {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                -Variable ($script:supplied + @{ HDTSkipSummary = $PSItem })

            @($result.Page | Where-Object { $_.Id -eq 'Summary' }).Count | Should -Be 1
        }
    }

    Context 'HDTSkipWizard, the unattended case' {

        It 'asks nothing at all' {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                -Variable ($script:supplied + @{ HDTSkipWizard = $true })

            @($result.Page) | Should -BeNullOrEmpty
        }

        It 'says HDTSkipWizard was what did it, on every page' {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                -Variable ($script:supplied + @{ HDTSkipWizard = $true })

            @($result.Skipped).Count | Should -Be 3
            @($result.Skipped | Where-Object { $_.Rule -ne 'HDTSkipWizard' }) | Should -BeNullOrEmpty
        }

        It 'reports that no wizard is to be shown, so the caller never opens an empty one' {
            # Show-HDTWizardShell REFUSES an empty page list by design - a shell
            # opened on nothing would answer for a window nobody saw. So the
            # caller has to be able to ask this question before calling it.
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                -Variable ($script:supplied + @{ HDTSkipWizard = $true })

            [bool] $result.IsWizardNeeded | Should -BeFalse
        }

        It 'reports that a wizard IS needed when anything is left to ask' {
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) -Variable $script:supplied

            [bool] $result.IsWizardNeeded | Should -BeTrue
        }
    }

    Context 'a skipped page whose value is missing' {

        It 'is an error, not a prompt' {
            # DESIGN 11.2, in those words. Showing it anyway produces a
            # deployment nobody can reproduce; inventing a value produces a
            # machine nobody named.
            {
                Get-HDTWizardPage -Page (New-HDTCataloguePage) -Variable @{ HDTSkipComputerName = $true }
            } | Should -Throw
        }

        It 'names the variable that should have been set, and the rule that skipped the page' {
            $record = $null
            try {
                Get-HDTWizardPage -Page (New-HDTCataloguePage) -Variable @{ HDTSkipComputerName = $true }
            } catch {
                $record = $_
            }

            $record.Exception.Message | Should -BeLike '*HDTComputerName*'
            $record.Exception.Message | Should -BeLike '*HDTSkipComputerName*'
        }

        It 'refuses the same way under HDTSkipWizard' {
            # The blunt key is the commonest way to get this wrong: it skips
            # pages an administrator may not have realised collected anything.
            {
                Get-HDTWizardPage -Page (New-HDTCataloguePage) -Variable @{ HDTSkipWizard = $true }
            } | Should -Throw
        }

        It 'permits skipping a page that collects nothing' {
            # The summary collects nothing, so there is no value it could be
            # missing.
            $result = Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                -Variable ($script:supplied + @{ HDTSkipSummary = $true })

            @($result.Page).Count | Should -Be 2
        }

        # A PAGE WITH TWO MUTUALLY EXCLUSIVE HALVES CANNOT DEMAND BOTH.
        #
        # MDT's Computer Details pane offers a domain OR a workgroup, and
        # SkipDomainMembership needs whichever one the machine is actually
        # getting - not both. HDT demanded every non-secret variable the page
        # collected, so a workgroup machine could not skip the page without
        # being handed a domain name, an OU and a join account it would never
        # use. The first real zero-touch deployment failed on exactly that:
        #
        #   the wizard page 'ComputerDetail' is skipped by HDTSkipWizard, but
        #   nothing supplies HDTJoinDomain
        #
        # on a machine whose rules said WORKGROUP.
        #
        # SO THE DOCUMENT SAYS WHICH ARE REQUIRED, because only the document
        # knows. Inferring "domain things are optional when a workgroup is set"
        # would be the engine guessing at the meaning of somebody else's page,
        # and a third-party page would get no such courtesy.

        It 'does not demand a value the page declares optional' {
            $page = @(
                [pscustomobject] @{
                    Id      = 'ComputerDetail'
                    Title   = 'Computer details'
                    Collect = @(
                        [pscustomobject] @{ Control = 'HDTComputerNameBox'; Variable = 'HDTComputerName' }
                        [pscustomobject] @{ Control = 'HDTJoinDomainBox'; Variable = 'HDTJoinDomain'; Optional = $true }
                    )
                    Skip    = 'HDTSkipComputerName'
                })

            $result = Get-HDTWizardPage -Page $page `
                -Variable @{ HDTSkipComputerName = $true; HDTComputerName = 'HDT-01' }

            @($result.Page).Count | Should -Be 0
            @($result.Skipped).Count | Should -Be 1
        }

        It 'still demands the ones it does not' {
            # Optional is a per-variable statement, not a way to turn the whole
            # check off.
            $page = @(
                [pscustomobject] @{
                    Id      = 'ComputerDetail'
                    Title   = 'Computer details'
                    Collect = @(
                        [pscustomobject] @{ Control = 'HDTComputerNameBox'; Variable = 'HDTComputerName' }
                        [pscustomobject] @{ Control = 'HDTJoinDomainBox'; Variable = 'HDTJoinDomain'; Optional = $true }
                    )
                    Skip    = 'HDTSkipComputerName'
                })

            { Get-HDTWizardPage -Page $page -Variable @{ HDTSkipComputerName = $true } } |
                Should -Throw -ExpectedMessage '*HDTComputerName*'
        }

        It 'treats an empty value as missing, not as supplied' {
            {
                Get-HDTWizardPage -Page (New-HDTCataloguePage) `
                    -Variable @{ HDTSkipComputerName = $true; HDTComputerName = '   ' }
            } | Should -Throw
        }
    }

    Context 'what it refuses' {

        It 'refuses an empty catalogue' {
            { Get-HDTWizardPage -Page @() -Variable @{} } | Should -Throw
        }
    }
}
