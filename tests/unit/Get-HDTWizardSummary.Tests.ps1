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
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

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


    # THE PAGE SETS RULE 8 IS ASSERTED AGAINST, including the one that ships.
    #
    # A hand-written shape can drift from the definition a technician actually
    # meets, so the shipped wizard.yaml is read here by the engine's own reader,
    # through a content provider over a fake file system - the same route
    # Start-HDTDeployment takes on a share.
    function New-HDTSummaryTestPageSet {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string] $Name
        )

        if ($Name -eq 'one page declaring one variable twice') {
            return @(
                [pscustomobject] @{
                    Id      = 'ComputerDetail'
                    Title   = 'Computer details'
                    Skip    = 'HDTSkipComputerName'
                    Collect = @(
                        [pscustomobject] @{ Control = 'HDTDomainAdminDomainBox'; Variable = 'HDTDomainAdminDomain' },
                        [pscustomobject] @{
                            Control       = 'HDTDomainAdminBox'
                            Variable      = 'HDTDomainAdmin'
                            Split         = 'AccountName'
                            SplitVariable = 'HDTDomainAdminDomain'
                        })
                })
        }

        if ($Name -eq 'the same variable on two pages') {
            return @(
                [pscustomobject] @{
                    Id      = 'JoinAccount'
                    Title   = 'Join account'
                    Skip    = 'HDTSkipDomainMembership'
                    Collect = @(
                        [pscustomobject] @{
                            Control       = 'HDTDomainAdminBox'
                            Variable      = 'HDTDomainAdmin'
                            Split         = 'AccountName'
                            SplitVariable = 'HDTDomainAdminDomain'
                        })
                },
                [pscustomobject] @{
                    Id      = 'AccountDomain'
                    Title   = 'Account domain'
                    Skip    = 'HDTSkipAccountDomain'
                    Collect = @(
                        [pscustomobject] @{ Control = 'HDTDomainAdminDomainBox'; Variable = 'HDTDomainAdminDomain' })
                })
        }

        if ($Name -eq 'the shipped wizard') {
            $definitionPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/Wizard/wizard.yaml'
            $yaml = [System.IO.File]::ReadAllText($definitionPath)

            # EVERY PAGE THE DEFINITION NAMES, taken FROM the definition. A list
            # written here would go stale the day a page is added - and the
            # reader refuses a definition naming markup that is not there, so a
            # stale list fails as a missing page rather than as a duplicate
            # variable and nobody would look here.
            $file = @{ 'C:\Share\Scripts\UI\wizard.yaml' = $yaml }

            foreach ($named in [regex]::Matches($yaml, '(?m)^\s*reference:\s*(\S+)\s*$')) {
                $file[('C:\Share\Scripts\UI\{0}' -f $named.Groups[1].Value)] =
                '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" />'
            }

            $provider = New-HDTLocalContentProvider -Root 'C:\Share' -FileSystem (New-HDTFakeFileSystem -File $file)

            return @((Import-HDTWizardDocument -Provider $provider).Page)
        }

        throw ("there is no wizard test page set called '{0}'." -f $Name)
    }

    # EVERY VARIABLE A PAGE SET DECLARES, ANSWERED. A variable nobody supplied
    # is left out of the snippet by design, so a duplicate would hide from the
    # snippet assertion unless every declaration is given a value.
    function Get-HDTSummaryTestValue {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object[]] $Page
        )

        $value = @{}

        foreach ($current in @($Page)) {
            if ($null -eq $current.PSObject.Properties['Collect']) { continue }

            foreach ($declaration in @($current.Collect)) {
                if ($null -eq $declaration) { continue }

                foreach ($key in @('Variable', 'SplitVariable')) {
                    if ($null -eq $declaration.PSObject.Properties[$key]) { continue }

                    $name = [string] $declaration.$key
                    if (-not [string]::IsNullOrWhiteSpace($name)) { $value[$name] = 'ANSWERED' }
                }
            }
        }

        return $value
    }

    $script:value = @{
        HDTTaskSequenceID = 'STD-CLIENT'
        HDTComputerName   = 'HDT-01'
    }

    # WHAT A TECHNICIAN ACTUALLY TYPED, and not 'ANSWERED' repeated seventeen
    # times. The line-length assertions below are about LENGTH, so a page set
    # answered with a short placeholder would pass while the real screen wrapped
    # on every other row. These are the values the offscreen probe renders, the
    # OU included - a real distinguished name is the one thing on this page the
    # command cannot shorten.
    #
    # HDTJoinWorkgroup IS DELIBERATELY ABSENT. A machine that joined a domain
    # joined no workgroup, and the snippet must leave the variable out rather
    # than write it empty (DESIGN 3.1).
    $script:realistic = @{
        HDTTaskSequenceID      = 'STD-CLIENT'
        HDTComputerName        = 'LAB-W11-014'
        HDTJoinDomain          = 'corp.contoso.com'
        HDTMachineObjectOU     = 'OU=Workstations,OU=Lab,DC=corp,DC=contoso,DC=com'
        HDTDomainAdmin         = 'svc-hdt-join'
        HDTDomainAdminDomain   = 'CORP'
        HDTDomainAdminPassword = 'not-shown-anywhere'
        HDTAdminPassword       = 'also-not-shown'
        HDTBitLockerPin        = '481507'
        HDTApplications        = '7-Zip;Google Chrome'
        HDTUILanguage          = 'en-GB'
        HDTUserLocale          = 'en-GB'
        HDTKeyboardLocale      = 'en-GB'
        HDTTimeZone            = 'GMT Standard Time'
        HDTEnableBitLocker     = 'True'
        HDTBitLockerProtector  = 'tpmPin'
        HDTBitLockerEscrow     = 'ad'
        HDTBitLockerStartupKey = 'F:'
    }

    # EVERY LINE THAT IS TOO WIDE FOR THE BOX, with ONE narrow allowance.
    #
    # A line is forgiven only when the overage IS THE TECHNICIAN'S OWN VALUE: an
    # OU of any realistic depth pushes its line past the budget and re-breaking
    # or truncating a YAML value would change what pastes into rules.yaml. So
    # the value's own length is subtracted and the REST of the line - indent,
    # key, colon, quotes - still has to fit on its own.
    #
    # Everything the command AUTHORS is measured with no allowance at all. A
    # comment line over budget is returned here and fails, which is the whole
    # point: the header was 84 characters and wrapped six times on a real render.
    function Get-HDTSummaryOverBudgetLine {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string] $Snippet,

            [Parameter(Mandatory = $true)]
            [hashtable] $Value,

            [Parameter(Mandatory = $true)]
            [int] $Budget
        )

        $over = @()

        foreach ($line in ($Snippet -split "`r?`n")) {

            if ($line.Length -le $Budget) { continue }

            $authored = $line.Length

            $set = [regex]::Match($line, '^ {6}(\S+): (.+)$')
            if ($set.Success -and $Value.ContainsKey($set.Groups[1].Value)) {
                $authored = $line.Length - ([string] $Value[$set.Groups[1].Value]).Length
            }

            if ($authored -gt $Budget) { $over += $line }
        }

        return $over
    }

    # THE KEYS THE SNIPPET MUST CARRY, TAKEN FROM THE DEFINITION rather than
    # written down here - rule 8. Every variable the pages declare, including a
    # split half, minus the ones nobody answered and the ones any declaration
    # calls a secret; plus every page's skip; plus HDTSkipWizard. A page added
    # tomorrow is covered without anybody editing this test.
    function Get-HDTSummaryExpectedKey {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object[]] $Page,

            [Parameter(Mandatory = $true)]
            [hashtable] $Value
        )

        $variable = @()
        $secret = @{}
        $skip = @()

        foreach ($current in @($Page)) {

            if ($null -ne $current.PSObject.Properties['Skip'] -and
                -not [string]::IsNullOrWhiteSpace([string] $current.Skip)) {

                if ($skip -notcontains [string] $current.Skip) { $skip += [string] $current.Skip }
            }

            if ($null -eq $current.PSObject.Properties['Collect']) { continue }

            foreach ($declaration in @($current.Collect)) {
                if ($null -eq $declaration) { continue }

                $isSecret = $false
                if ($null -ne $declaration.PSObject.Properties['IsSecret']) { $isSecret = [bool] $declaration.IsSecret }

                foreach ($key in @('Variable', 'SplitVariable')) {
                    if ($null -eq $declaration.PSObject.Properties[$key]) { continue }

                    $name = [string] $declaration.$key
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }

                    # SECRECY IS STICKY, exactly as the command treats it.
                    if ($isSecret) { $secret[$name] = $true }
                    if ($variable -notcontains $name) { $variable += $name }
                }
            }
        }

        $expected = @($variable | Where-Object {
                -not $secret.ContainsKey($_) -and
                $Value.ContainsKey($_) -and
                -not [string]::IsNullOrWhiteSpace([string] $Value[$_])
            })

        return @($expected) + @('HDTSkipWizard') + @($skip)
    }

    # THE SECRETS THE SHIPPED DEFINITION DECLARES, again read off the definition
    # so a fourth one is covered the day it is added.
    function Get-HDTSummarySecretVariable {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object[]] $Page
        )

        $secret = @()

        foreach ($current in @($Page)) {
            if ($null -eq $current.PSObject.Properties['Collect']) { continue }

            foreach ($declaration in @($current.Collect)) {
                if ($null -eq $declaration) { continue }
                if ($null -eq $declaration.PSObject.Properties['IsSecret']) { continue }
                if (-not [bool] $declaration.IsSecret) { continue }

                $name = [string] $declaration.Variable
                if (-not [string]::IsNullOrWhiteSpace($name) -and $secret -notcontains $name) { $secret += $name }
            }
        }

        return $secret
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

    Context 'a variable that two declarations both fill' {

        # THE FIELD DEFECT, AND IT WAS SEEN ON A REAL RENDER. The shipped
        # ComputerDetail page declares HDTDomainAdminDomain TWICE - once as its
        # own collect entry, behind HDTDomainAdminDomainBox, and once as the
        # splitVariable of HDTDomainAdminBox, which takes CORP\svc-hdt-join and
        # tears it in half. Both declarations are right: a technician may type
        # the account and the domain separately, or type one string carrying
        # both.
        #
        # THE SUMMARY WAS WHAT WAS WRONG. It listed CORP on two rows and wrote
        # the line into the snippet twice, reporting one answer as though the
        # deployment had been told two things.
        #
        # AND A DUPLICATE IN THE SNIPPET IS NOT COSMETIC. That block is meant to
        # be pasted into rules.yaml, where the FIRST match wins (DESIGN 3.1) - so
        # a variable written twice in one set: block teaches an administrator a
        # shape that bites them the day the two lines disagree.

        BeforeAll {
            $script:twiceOnOnePage = @(
                [pscustomobject] @{
                    Id      = 'ComputerDetail'
                    Title   = 'Computer details'
                    Skip    = 'HDTSkipComputerName'
                    Collect = @(
                        [pscustomobject] @{ Control = 'HDTDomainAdminDomainBox'; Variable = 'HDTDomainAdminDomain' },
                        [pscustomobject] @{
                            Control       = 'HDTDomainAdminBox'
                            Variable      = 'HDTDomainAdmin'
                            Split         = 'AccountName'
                            SplitVariable = 'HDTDomainAdminDomain'
                        })
                })
        }

        It 'gives HDTDomainAdminDomain one row, not one per declaration' {
            $summary = Get-HDTWizardSummary -Page $script:twiceOnOnePage `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            @($summary.Row | Where-Object { [string] $_.Variable -eq 'HDTDomainAdminDomain' }).Count |
                Should -Be 1
        }

        It 'still gives the other variable its row, because de-duplication is not deletion' {
            $summary = Get-HDTWizardSummary -Page $script:twiceOnOnePage `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            @($summary.Row).Count | Should -Be 2
        }

        It 'writes HDTDomainAdminDomain into the snippet once' {
            $summary = Get-HDTWizardSummary -Page $script:twiceOnOnePage `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            @([regex]::Matches([string] $summary.Snippet, '(?m)^\s+HDTDomainAdminDomain:')).Count |
                Should -Be 1
        }

        It 'shows the value on the row that survived, rather than losing it with the duplicate' {
            $summary = Get-HDTWizardSummary -Page $script:twiceOnOnePage `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            $surviving = @($summary.Row | Where-Object { [string] $_.Variable -eq 'HDTDomainAdminDomain' })[0]

            [string] $surviving.Value | Should -BeExactly 'CORP'
            [bool] $surviving.IsSet | Should -BeTrue
        }

        It 'says not set once, rather than twice, when nobody supplied it' {
            # SET BEATS NOT SET, and the row that survives is the one carrying an
            # answer. A value is looked up by VARIABLE NAME, so both declarations
            # of one variable agree today about whether it was filled in - which
            # is why this reads as "exactly one row, and it is the right one"
            # rather than as a contest between a set row and an unset one.
            $summary = Get-HDTWizardSummary -Page $script:twiceOnOnePage -Value @{ HDTDomainAdmin = 'svc' }

            $unset = @($summary.Row | Where-Object { [string] $_.Variable -eq 'HDTDomainAdminDomain' })

            @($unset).Count | Should -Be 1
            [string] $unset[0].Value | Should -BeExactly '(not set)'
            [string] $summary.Snippet | Should -Not -BeLike '*HDTDomainAdminDomain:*'
        }
    }

    Context 'which of two declarations wins' {

        # THE RULE, AND IT IS DELIBERATE RATHER THAN WHICHEVER ENUMERATION
        # REACHED FIRST:
        #
        #   1. a declaration whose value IS set beats one that is not
        #   2. a declaration with ITS OWN CONTROL beats a split half
        #   3. otherwise the first page to ask wins
        #
        # Rule 2 is the one that decides the shipped page. The split half is
        # DERIVED - whatever was left of CORP\svc-hdt-join after the backslash -
        # while HDTDomainAdminDomainBox is a box a technician typed into, and it
        # is that box's page, title and skip variable a summary should name.

        BeforeAll {
            # The split half is asked FIRST here, so "first wins" and "the box
            # wins" give different answers and the test can tell them apart.
            $script:splitBeforeBox = @(
                [pscustomobject] @{
                    Id      = 'JoinAccount'
                    Title   = 'Join account'
                    Skip    = 'HDTSkipDomainMembership'
                    Collect = @(
                        [pscustomobject] @{
                            Control       = 'HDTDomainAdminBox'
                            Variable      = 'HDTDomainAdmin'
                            Split         = 'AccountName'
                            SplitVariable = 'HDTDomainAdminDomain'
                        })
                },
                [pscustomobject] @{
                    Id      = 'AccountDomain'
                    Title   = 'Account domain'
                    Skip    = 'HDTSkipAccountDomain'
                    Collect = @(
                        [pscustomobject] @{ Control = 'HDTDomainAdminDomainBox'; Variable = 'HDTDomainAdminDomain' })
                })
        }

        It 'keeps the declaration that owns a control, not the half split off another box' {
            $summary = Get-HDTWizardSummary -Page $script:splitBeforeBox `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            $surviving = @($summary.Row | Where-Object { [string] $_.Variable -eq 'HDTDomainAdminDomain' })

            @($surviving).Count | Should -Be 1
            [string] $surviving[0].Setting | Should -BeExactly 'Account domain'
        }

        It 'names the skip of the page that owns the box, which is the page an administrator has to hide' {
            $summary = Get-HDTWizardSummary -Page $script:splitBeforeBox `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            $surviving = @($summary.Row | Where-Object { [string] $_.Variable -eq 'HDTDomainAdminDomain' })[0]

            [string] $surviving.Skip | Should -BeExactly 'HDTSkipAccountDomain'
        }

        It 'still writes the skip of every page, because de-duplicating a variable hides no page' {
            $summary = Get-HDTWizardSummary -Page $script:splitBeforeBox `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            [string] $summary.Snippet | Should -BeLike '*HDTSkipDomainMembership: true*'
            [string] $summary.Snippet | Should -BeLike '*HDTSkipAccountDomain: true*'
        }

        It 'treats the variable as a secret when any declaration of it says so' {
            # SECRECY IS NOT A TIE-BREAK, IT IS STICKY. A half printed because it
            # arrived by the other route is exactly the shape a leak takes, so a
            # variable declared secret anywhere is secret on the row that
            # survives and is not written into the snippet at all.
            $page = @(
                [pscustomobject] @{
                    Id      = 'JoinAccount'
                    Title   = 'Join account'
                    Skip    = 'HDTSkipDomainMembership'
                    Collect = @(
                        [pscustomobject] @{
                            Control       = 'HDTDomainAdminBox'
                            Variable      = 'HDTDomainAdmin'
                            IsSecret      = $true
                            Split         = 'AccountName'
                            SplitVariable = 'HDTDomainAdminDomain'
                        },
                        [pscustomobject] @{ Control = 'HDTDomainAdminDomainBox'; Variable = 'HDTDomainAdminDomain' })
                })

            $summary = Get-HDTWizardSummary -Page $page `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            $surviving = @($summary.Row | Where-Object { [string] $_.Variable -eq 'HDTDomainAdminDomain' })[0]

            [string] $surviving.Value | Should -BeExactly '(set, not shown)'
            [string] $summary.Snippet | Should -Not -BeLike '*HDTDomainAdminDomain: CORP*'
        }

        It 'de-duplicates on the variable, never on the value' {
            # TWO DIFFERENT VARIABLES THAT HAPPEN TO AGREE. A machine named CORP
            # joining a domain named CORP is not a duplicate, and a summary that
            # dropped one of those rows would hide half the deployment.
            $page = @(
                [pscustomobject] @{
                    Id      = 'ComputerDetail'
                    Title   = 'Computer details'
                    Skip    = 'HDTSkipComputerName'
                    Collect = @(
                        [pscustomobject] @{ Control = 'HDTComputerNameBox'; Variable = 'HDTComputerName' },
                        [pscustomobject] @{ Control = 'HDTJoinDomainBox'; Variable = 'HDTJoinDomain' })
                })

            $summary = Get-HDTWizardSummary -Page $page -Value @{ HDTComputerName = 'CORP'; HDTJoinDomain = 'CORP' }

            @($summary.Row).Count | Should -Be 2
            [string] $summary.Snippet | Should -BeLike '*HDTComputerName: CORP*'
            [string] $summary.Snippet | Should -BeLike '*HDTJoinDomain: CORP*'
        }

        It 'reaches a split half at all, which is what stops the de-duplication passing vacuously' {
            # THE GUARD. Every test above would go green if the walk had simply
            # stopped enumerating splitVariable declarations - a summary that
            # never saw the second declaration has no duplicate to remove, and no
            # domain to write either.
            $page = @(
                [pscustomobject] @{
                    Id      = 'JoinAccount'
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

            $summary = Get-HDTWizardSummary -Page $page `
                -Value @{ HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' }

            @($summary.Row | Where-Object { [string] $_.Variable -eq 'HDTDomainAdminDomain' }).Count |
                Should -Be 1
            [string] $summary.Snippet | Should -BeLike '*HDTDomainAdminDomain: CORP*'
        }
    }

    Context 'no page set at all produces a repeated variable' {

        # RULE 8, AS A TEST WRITTEN AGAINST THE SET. An It naming
        # HDTDomainAdminDomain passes for HDTDomainAdminDomain and fails nobody
        # after it. These drive off the OUTPUT - every row, every key the snippet
        # carries - so the next page that declares a variable twice fails here
        # without anybody adding a case for it.
        #
        # AND ONE OF THE SETS IS THE SHIPPED DEFINITION, read through
        # Import-HDTWizardDocument - the same reader Start-HDTDeployment uses -
        # because the share is a copy of the templates (CLAUDE.md rule 8) and a
        # hand-written shape here could drift from what a technician meets.

        It 'lists each variable once, whatever the pages declared' -ForEach @(
            @{ Name = 'one page declaring one variable twice' }
            @{ Name = 'the same variable on two pages' }
            @{ Name = 'the shipped wizard' }) {

            $page = @(New-HDTSummaryTestPageSet -Name $Name)
            $summary = Get-HDTWizardSummary -Page $page -Value (Get-HDTSummaryTestValue -Page $page)

            $repeated = @(@($summary.Row) | Group-Object -Property Variable | Where-Object { $_.Count -gt 1 })

            (@($repeated | ForEach-Object { [string] $_.Name }) -join ', ') | Should -BeExactly ''
        }

        It 'writes each key into the snippet once, whatever the pages declared' -ForEach @(
            @{ Name = 'one page declaring one variable twice' }
            @{ Name = 'the same variable on two pages' }
            @{ Name = 'the shipped wizard' }) {

            # EVERY KEY, not only the ones this fix was about: the set: lines,
            # the per-page skips and HDTSkipWizard are all six-space keys inside
            # one rule, and any of them written twice is the same defect.
            $page = @(New-HDTSummaryTestPageSet -Name $Name)
            $summary = Get-HDTWizardSummary -Page $page -Value (Get-HDTSummaryTestValue -Page $page)

            $key = @([regex]::Matches([string] $summary.Snippet, '(?m)^ {6}(\S+):') |
                    ForEach-Object { $_.Groups[1].Value })

            $repeated = @($key | Group-Object | Where-Object { $_.Count -gt 1 })

            (@($repeated | ForEach-Object { [string] $_.Name }) -join ', ') | Should -BeExactly ''
        }

        It 'reads the shipped definition through the engine, not through a shape written here' {
            # THE GUARD ON THE GUARD. If the shipped set arrived empty - a
            # provider that served nothing, a reader that returned nothing - the
            # two tests above would pass having summarised nothing at all.
            $page = @(New-HDTSummaryTestPageSet -Name 'the shipped wizard')

            @($page).Count | Should -BeGreaterThan 0
            @($page | Where-Object { @($_.Collect).Count -gt 0 }).Count | Should -BeGreaterThan 0

            $declared = @($page | ForEach-Object { @($_.Collect) } |
                    ForEach-Object { [string] $_.SplitVariable } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $declared.Count | Should -BeGreaterThan 0 -Because 'the shipped join-account box splits a DOMAIN\user in two, and that is the declaration this defect came from'
        }
    }

    Context 'lines that fit the box they are rendered into' {

        # WHERE 68 COMES FROM, AND HOW TO RE-DERIVE IT.
        #
        # Summary.xaml gives the whole page to HDTSummarySnippet, and that box is
        # already as wide as it can get: the shell is 900px, the rail takes 230,
        # the content margin 36, the ScrollViewer's padding 12 and its own
        # scrollbar the rest - about 542px of text. HDTSnippetBox is Consolas at
        # HDTHintSize, which HDTTheme.xaml sets to 14, and Consolas advances
        # 0.5498em, so a character is 7.7px and 542px is a shade over 70 of them.
        #
        # 68 RATHER THAN 70 leaves two characters of margin, because that sum is
        # a measurement of a layout rather than a guarantee - a scrollbar a pixel
        # wider eats the difference.
        #
        # CHANGE THE SHELL WIDTH, THE RAIL, THE MARGINS OR HDTHintSize AND THIS
        # NUMBER IS WRONG. The paragraph above is the sum to redo, not decoration.
        #
        # WRAPPING STAYS ON REGARDLESS (see Summary.xaml). It is the safety net
        # for the one line this command cannot shorten - a technician's own OU -
        # and a net catching every line is a net holding the whole weight.

        BeforeAll {
            $script:snippetLineBudget = 68
        }

        It 'emits nothing wider than the box, once a technician value is discounted' {
            # THE REALISTIC RENDER: the shipped pages, answered the way a bench
            # answers them, OU and all.
            $page = @(New-HDTSummaryTestPageSet -Name 'the shipped wizard')
            $summary = Get-HDTWizardSummary -Page $page -Value $script:realistic

            $over = @(Get-HDTSummaryOverBudgetLine -Snippet ([string] $summary.Snippet) `
                    -Value $script:realistic -Budget $script:snippetLineBudget)

            ($over -join ' | ') | Should -BeExactly ''
        }

        It 'keeps every comment it authors inside the budget' {
            # SAID SEPARATELY BECAUSE THE PROSE IS THE PART THAT WAS WRONG. The
            # header ran to 84 characters and wrapped six times on a real render.
            # No allowance applies to a comment, ever - the exemption above is
            # for YAML VALUES and must never grow to cover an explanation.
            $page = @(New-HDTSummaryTestPageSet -Name 'the shipped wizard')
            $summary = Get-HDTWizardSummary -Page $page -Value $script:realistic

            $wide = @([string] $summary.Snippet -split "`r?`n" |
                    Where-Object { $_ -match '^\s*#' -and $_.Length -gt $script:snippetLineBudget })

            ($wide -join ' | ') | Should -BeExactly ''
        }

        It 'holds for every page set, not only the one it was measured on' -ForEach @(
            @{ Name = 'one page declaring one variable twice' }
            @{ Name = 'the same variable on two pages' }
            @{ Name = 'the shipped wizard' }) {

            # RULE 8, AS A TEST AGAINST THE SET. This drives off the OUTPUT, so
            # the next page whose title or variable name pushes a line past the
            # budget fails here without anybody adding a case for it.
            $page = @(New-HDTSummaryTestPageSet -Name $Name)
            $value = Get-HDTSummaryTestValue -Page $page
            $summary = Get-HDTWizardSummary -Page $page -Value $value

            $over = @(Get-HDTSummaryOverBudgetLine -Snippet ([string] $summary.Snippet) `
                    -Value $value -Budget $script:snippetLineBudget)

            ($over -join ' | ') | Should -BeExactly ''
        }

        It 'still wraps rather than truncates the one line it cannot shorten' {
            # THE OTHER HALF OF THE BARGAIN. Shortening the prose is not licence
            # to shorten a DN: the OU line is over budget on purpose, written
            # whole, and the box's TextWrapping is what makes it readable.
            $page = @(New-HDTSummaryTestPageSet -Name 'the shipped wizard')
            $summary = Get-HDTWizardSummary -Page $page -Value $script:realistic

            [string] $summary.Snippet |
                Should -BeLike ('*"{0}"*' -f $script:realistic['HDTMachineObjectOU'])

            $long = @([string] $summary.Snippet -split "`r?`n" |
                    Where-Object { $_.Length -gt $script:snippetLineBudget })

            @($long).Count | Should -Be 1 -Because 'the technician OU is the only line the command may not re-break'
        }
    }

    Context 'what the snippet still says after the prose was shortened' {

        # THE GUARD ON A PROSE EDIT. Re-breaking a comment is one keystroke from
        # breaking the document - a hash lost off the front of a continuation, a
        # value pulled onto a line of its own - and every length assertion above
        # is about SHAPE rather than about the file parsing.
        #
        # So this parses it, against the SHIPPED definition read through
        # Import-HDTWizardDocument: the same reader Start-HDTDeployment uses on a
        # share, because the share is a copy of the templates (rule 8).

        BeforeAll {
            Import-Module -Name powershell-yaml -ErrorAction Stop

            $script:shippedPage = @(New-HDTSummaryTestPageSet -Name 'the shipped wizard')
            $script:shippedSummary = Get-HDTWizardSummary -Page $script:shippedPage -Value $script:realistic
            $script:parsed = ConvertFrom-Yaml -Yaml ([string] $script:shippedSummary.Snippet) -Ordered
            $script:setBlock = @($script:parsed['rules'])[0]['set']
        }

        It 'parses as YAML at all, which is the whole promise of a paste' {
            $script:parsed | Should -Not -BeNullOrEmpty
            [int] $script:parsed['schemaVersion'] | Should -Be 1
        }

        It 'is one fallback rule with no condition, so it matches every machine' {
            @($script:parsed['rules']).Count | Should -Be 1
            [string] @($script:parsed['rules'])[0]['name'] | Should -BeExactly 'Unattended'
            @($script:parsed['rules'])[0].Contains('when') | Should -BeFalse
        }

        It 'sets exactly the keys the definition and the answers imply, no more and no fewer' {
            $expected = @(Get-HDTSummaryExpectedKey -Page $script:shippedPage -Value $script:realistic)

            ((@($script:setBlock.Keys) | Sort-Object) -join ', ') |
                Should -BeExactly ((@($expected) | Sort-Object) -join ', ')
        }

        It 'round-trips every answered value, so no quoting choice changed one' {
            $wrong = @()

            foreach ($key in @($script:realistic.Keys)) {
                if (-not $script:setBlock.Contains($key)) { continue }
                if ([string] $script:setBlock[$key] -ne [string] $script:realistic[$key]) { $wrong += $key }
            }

            ($wrong -join ', ') | Should -BeExactly ''
        }

        It 'writes no secret the definition declares, still' {
            $secret = @(Get-HDTSummarySecretVariable -Page $script:shippedPage)

            @($secret).Count | Should -BeGreaterThan 0

            $written = @($secret | Where-Object { $script:setBlock.Contains($_) })

            ($written -join ', ') | Should -BeExactly ''
        }

        It 'names each secret in a comment instead, so nobody wonders whether it was collected' {
            $missing = @(Get-HDTSummarySecretVariable -Page $script:shippedPage |
                    Where-Object { [string] $script:shippedSummary.Snippet -notlike ('*{0}*' -f $_) })

            ($missing -join ', ') | Should -BeExactly ''
        }

        It 'omits a variable nobody answered rather than writing it empty' {
            # HDTJoinWorkgroup is declared by the shipped ComputerDetail page and
            # deliberately unanswered: a rule setting it to nothing RESOLVES it,
            # starving every later rule (DESIGN 3.1).
            $script:setBlock.Contains('HDTJoinWorkgroup') | Should -BeFalse
        }

        It 'still hides every page, by the blunt key and by each page key of its own' {
            [bool] $script:setBlock['HDTSkipWizard'] | Should -BeTrue

            $missing = @($script:shippedPage |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_.Skip) } |
                    ForEach-Object { [string] $_.Skip } |
                    Where-Object { -not $script:setBlock.Contains($_) })

            ($missing -join ', ') | Should -BeExactly ''
        }

        It 'still says the Welcome screen is set somewhere else, and where' {
            [string] $script:shippedSummary.Snippet | Should -BeLike '*WELCOME*'
            [string] $script:shippedSummary.Snippet | Should -BeLike '*bootstrap.json*'
            [string] $script:shippedSummary.Snippet | Should -BeLike '*HDTSkipWelcome*'
            [string] $script:shippedSummary.Snippet | Should -BeLike '*-PromptForCredential*'
        }

        It 'still says where to put the file' {
            [string] $script:shippedSummary.Snippet | Should -BeLike '*rules.yaml*'
            [string] $script:shippedSummary.Snippet | Should -BeLike '*deployment share*'
        }
    }
}
