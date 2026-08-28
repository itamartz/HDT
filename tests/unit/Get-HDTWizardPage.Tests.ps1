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

# A LIST-VALUED COLLECT IS NOT A SCALAR, AND THE SKIP CHECK COULD NOT TELL.
#
# A real zero-touch deployment died five seconds in, before it had partitioned
# anything:
#
#   HDTConfigurationError: the wizard page 'Applications' is skipped by
#   HDTSkipWizard, but nothing supplies HDTApplications.
#
# THE REFUSAL COULD NOT BE SATISFIED. The check asked
# -not [string]::IsNullOrWhiteSpace([string] $resolved[$name]), and [string] @()
# is '' - so HDTApplications: [], the correct and explicit "install nothing",
# failed it exactly as a missing value did. There was no value an administrator
# could write into rules.yaml that got past it.
#
# AND MDT DEMANDS NO LIST, which settles what to do instead.
# DeployWiz_Definition_ENU.xml's Applications pane carries the condition
# UCase(Property("SkipApplications"))<>"YES" and no companion test that a value
# exists; ZTIApplications.wsf logs "Application List is empty, exiting
# ZTIApplications.wsf" and returns Success on a count of zero; PSD's
# PSDApplications.ps1 guards the same way. LiteTouch.wsf's "clean up properties
# if the wizard was skipped" block defaults the scalars - JoinWorkgroup,
# ComputerBackupLocation, UserDataLocation, TimeZoneName and the rest - and
# names Applications nowhere.
#
# So: one required scalar, and no list is ever required.

Describe 'Get-HDTWizardPage and a list-valued collect' {

    BeforeAll {
        # The Applications page as it ships: one control, one variable, and
        # select: many - a column of tick boxes rather than a property.
        function New-HDTApplicationsPage {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds in-memory test data; it changes no state.')]
            [CmdletBinding()]
            param()

            return @(
                [pscustomobject] @{
                    Id      = 'Applications'
                    Title   = 'Applications'
                    Skip    = 'HDTSkipApplications'
                    Collect = @(
                        [pscustomobject] @{
                            Control  = 'HDTApplicationList'
                            Variable = 'HDTApplications'
                            Select   = 'many'
                        })
                })
        }
    }

    Context 'the deployment that died before partitioning' {

        It 'does not refuse a skipped Applications page that supplies no HDTApplications' {
            { Get-HDTWizardPage -Page (New-HDTApplicationsPage) -Variable @{ HDTSkipWizard = $true } } |
                Should -Not -Throw
        }

        It 'records the page as skipped rather than asking it' {
            $result = Get-HDTWizardPage -Page (New-HDTApplicationsPage) -Variable @{ HDTSkipWizard = $true }

            @($result.Page) | Should -BeNullOrEmpty
            [string] @($result.Skipped)[0].Id | Should -BeExactly 'Applications'
        }

        It 'does not refuse under the page''s own skip variable either' {
            { Get-HDTWizardPage -Page (New-HDTApplicationsPage) -Variable @{ HDTSkipApplications = $true } } |
                Should -Not -Throw
        }
    }

    Context 'the answer an administrator could not write' {

        It 'accepts an empty list as the explicit install nothing' {
            # [string] @() is '', so this failed the old check exactly as a
            # missing value did. It is the one answer that says "I have decided,
            # and the decision is none".
            { Get-HDTWizardPage -Page (New-HDTApplicationsPage) `
                    -Variable @{ HDTSkipWizard = $true; HDTApplications = @() } } | Should -Not -Throw
        }

        It 'accepts a list with applications in it' {
            { Get-HDTWizardPage -Page (New-HDTApplicationsPage) `
                    -Variable @{ HDTSkipWizard = $true; HDTApplications = @('APP-0001', 'APP-0002') } } |
                Should -Not -Throw
        }

        It 'accepts the joined string the host actually harvests' {
            { Get-HDTWizardPage -Page (New-HDTApplicationsPage) `
                    -Variable @{ HDTSkipWizard = $true; HDTApplications = 'APP-0001, APP-0002' } } |
                Should -Not -Throw
        }
    }

    Context 'a list and a scalar are not the same kind of answer' {

        It 'demands a scalar collect and does not demand a list collect on the same page' {
            # The two declarations are identical but for select, which is the
            # whole point: the difference is the document's, not the engine's
            # guess about what a variable name means.
            $scalar = @(
                [pscustomobject] @{
                    Id      = 'Proof'
                    Title   = 'Proof'
                    Skip    = 'HDTSkipProof'
                    Collect = @([pscustomobject] @{ Control = 'HDTProofBox'; Variable = 'HDTProof' })
                })

            $list = @(
                [pscustomobject] @{
                    Id      = 'Proof'
                    Title   = 'Proof'
                    Skip    = 'HDTSkipProof'
                    Collect = @([pscustomobject] @{ Control = 'HDTProofBox'; Variable = 'HDTProof'; Select = 'many' })
                })

            { Get-HDTWizardPage -Page $scalar -Variable @{ HDTSkipProof = $true } } |
                Should -Throw -ExpectedMessage '*HDTProof*'

            { Get-HDTWizardPage -Page $list -Variable @{ HDTSkipProof = $true } } | Should -Not -Throw
        }

        It 'reads select of one as the scalar it is' {
            # Absent means one; written out it must still mean one, or a page
            # that says what every other page assumes would behave differently.
            $page = @(
                [pscustomobject] @{
                    Id      = 'Proof'
                    Title   = 'Proof'
                    Skip    = 'HDTSkipProof'
                    Collect = @([pscustomobject] @{ Control = 'HDTProofBox'; Variable = 'HDTProof'; Select = 'one' })
                })

            { Get-HDTWizardPage -Page $page -Variable @{ HDTSkipProof = $true } } |
                Should -Throw -ExpectedMessage '*HDTProof*'
        }
    }

    Context 'the one scalar MDT genuinely refuses without' {

        It 'still refuses a skipped TaskSequence page that supplies no HDTTaskSequenceID' {
            # LiteTouch.wsf dies on the missing Control\TS.XML for the sequence
            # named, and SetPropertyDefault has nothing to say about it. There
            # is no deployment to run without one.
            $page = @(
                [pscustomobject] @{
                    Id      = 'TaskSequence'
                    Title   = 'Task sequence'
                    Skip    = 'HDTSkipTaskSequence'
                    Collect = @([pscustomobject] @{ Control = 'HDTTaskSequenceList'; Variable = 'HDTTaskSequenceID' })
                })

            { Get-HDTWizardPage -Page $page -Variable @{ HDTSkipTaskSequence = $true } } |
                Should -Throw -ExpectedMessage '*HDTTaskSequenceID*'
        }
    }
}

# THE SET, NOT THE PAGE THAT BROKE.
#
# CLAUDE.md rule 8: a test that names the thing just added passes for it and
# fails nobody after it. This walks every page the shipped wizard.yaml declares,
# through the engine's own reader, and asserts the refusal fires for exactly the
# variables the DOCUMENT marks required - not for a list written here. The next
# page added is covered the day it is added.

Describe 'The shipped wizard.yaml, skipped a page at a time' {

    BeforeAll {
        $script:setRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:setRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:setRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        # The real templates, seeded onto a share the real way and read back by
        # the real reader - so the Optional, IsSecret and Select the check reads
        # are the ones Import-HDTWizardDocument actually produces, not a shape
        # invented in this file.
        $fs = New-HDTFakeFileSystem
        $null = New-HDTWorkspace -Path 'Z:\WizardSet' -Id 'WIZSET' -Name 'Wizard set' -FileSystem $fs -Confirm:$false

        $script:shippedPage = @((Import-HDTWizardDocument -Provider (New-HDTLocalContentProvider -Root 'Z:\WizardSet' -FileSystem $fs)).Page)

        # WHAT THE DOCUMENT CALLS REQUIRED, read off the document. A secret is
        # never written into rules.yaml; an optional half of a two-halved page
        # is whichever half the machine is not getting; and a list is an answer
        # when it is empty, so it is never demanded.
        $script:requiredOf = {
            param($Page)

            return @(@($Page.Collect) | Where-Object {
                    $null -ne $_ -and
                    -not [bool] $_.IsSecret -and
                    -not [bool] $_.Optional -and
                    ([string] $_.Select).Trim().ToLowerInvariant() -ne 'many'
                } | ForEach-Object { [string] $_.Variable })
        }
    }

    It 'reads back every page it ships' {
        @($script:shippedPage).Count | Should -BeGreaterThan 0
    }

    It 'refuses only for what the document marks required, skipping <Id>' -ForEach @(
        # -ForEach is bound before BeforeAll runs, so the cases are read here,
        # off the same file the reader reads.
        @(& {
                $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
                Import-Module -Name powershell-yaml -ErrorAction Stop
                $text = [System.IO.File]::ReadAllText([IO.Path]::Combine($root, 'src', 'Hephaestus', 'Templates', 'Wizard', 'wizard.yaml'))

                @((ConvertFrom-Yaml -Yaml $text -Ordered)['pages']) | ForEach-Object {
                    $skip = ''
                    if ($_.Contains('skip')) { $skip = [string] $_['skip'] }
                    @{ Id = [string] $_['id']; Skip = $skip }
                }
            })
    ) {
        $current = @($script:shippedPage | Where-Object { [string] $_.Id -eq $Id })[0]
        $current | Should -Not -BeNullOrEmpty

        $required = @(& $script:requiredOf $current)

        $record = $null
        try {
            $null = Get-HDTWizardPage -Page $script:shippedPage -Variable @{ $Skip = $true }
        } catch {
            $record = $PSItem
        }

        if (@($required).Count -eq 0) {
            $record | Should -BeNullOrEmpty -Because ('{0} marks nothing required, so skipping it with nothing set is an unattended deployment rather than a fault' -f $Id)
        } else {
            $record | Should -Not -BeNullOrEmpty -Because ('{0} requires {1}' -f $Id, ($required -join ', '))
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $required[0])
        }
    }

    It 'requires HDTTaskSequenceID and HDTComputerName across the whole document, and nothing else' {
        # MDT's rule, stated once against the set: one genuinely fatal missing
        # scalar. HDT keeps a second - HDTComputerName - because unlike MDT it
        # will not let Windows invent a machine's identity, and New-HDTWorkspace
        # seeds a Fallback rule that answers it on every share this module
        # creates. Anything else appearing here is a page that cannot be run
        # unattended, and that is the thing to notice.
        $required = @($script:shippedPage | ForEach-Object { & $script:requiredOf $_ })

        (@($required | Sort-Object) -join ',') | Should -BeExactly 'HDTComputerName,HDTTaskSequenceID'
    }
}
