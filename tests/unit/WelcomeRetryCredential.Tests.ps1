# THE RETYPED PASSWORD THAT WENT NOWHERE.
#
# A technician at a bench boots a machine, the share refuses the credential the
# boot image carries, and the Welcome screen comes up - carrying a share box AND
# the credential quartet Get-HDTWizardField has already prefilled. They retype
# the password, press Next, and watch THE SAME REFUSAL come back. Then they do
# it again, more carefully. The retry re-bound $providerArgument['Root'] and
# nothing else, so the only thing that screen could ever fix was a wrong path;
# every character typed into the account boxes was read off the window by
# Get-HDTWizardHarvest and dropped on the floor.
#
# WHICH IS THE EXACT DEFECT Get-HDTWizardHarvest'S OWN HELP SAYS IT WAS WRITTEN
# TO END - "the Welcome screen was decorative, and a real boot proved it" - one
# window over. Harvesting a value is not consuming it.
#
# THIS FILE RUNS THE PAYLOAD'S OWN CODE RATHER THAN READING IT. The rest of
# tests/unit/StartHDTDeploymentPayload.Tests.ps1 parses Start-HDTDeployment.ps1
# and asserts properties of the text, which is right for "it contains no
# deployment logic" and is exactly the kind of test that let this ship: the
# payload said $providerArgument['Credential'] once, at build time, and a text
# scan was happy. So the two pieces that carry the defect - the $showWelcome
# closure and the connect loop - are lifted out of the file by AST and EXECUTED
# against hand-written fakes.
#
# THE ASSERTION THAT WOULD HAVE CAUGHT IT is the last one: every control
# Get-HDTWizardHarvest collects is cleared in turn, and the outcome has to
# change. A box that is read and thrown away produces the same outcome either
# way, which is what "decorative" looks like from a test.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'

    $script:payloadToken = $null
    $script:payloadError = $null
    $script:payloadAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:payloadPath, [ref] $script:payloadToken, [ref] $script:payloadError)

    # -- the two pieces of the payload this file executes ---------------------
    #
    # BY AST AND NOT BY LINE NUMBER, because the file is edited constantly and a
    # test pinned to line 578 would silently start testing something else.

    $script:showWelcomeSource = ''
    $assignment = @($script:payloadAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$showWelcome'
            }, $true))

    if ($assignment.Count -eq 1) {
        $braced = [string] $assignment[0].Right.Extent.Text
        $script:showWelcomeSource = $braced.Substring(1, $braced.Length - 2)
    }

    $script:connectLoopSource = ''
    $loop = @($script:payloadAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.WhileStatementAst]
            }, $true) | Where-Object { $_.Extent.Text -match "providerArgument\['Root'\]" })

    if ($loop.Count -eq 1) { $script:connectLoopSource = [string] $loop[0].Extent.Text }

    # -- the fakes ------------------------------------------------------------
    #
    # HAND-WRITTEN, NOT Mock. Mock is reserved for the adapter boundary, and a
    # readable failure here is the whole point: the message has to say which box
    # was thrown away.

    $script:welcomeAction = 'Next'
    $script:welcomeValue = @{}
    $script:staticCall = @()
    $script:said = @()
    $script:providerBuilt = @()
    $script:providerSucceedAt = 1
    $script:welcomeShown = 0

    function Show-HDTWizard {
        [CmdletBinding()]
        param(
            [string] $XamlPath, [string] $ThemeXamlPath, [string] $Title,
            [object[]] $Field, [object[]] $Pane, [object[]] $Collect,
            [object] $WizardHost, [object] $FileSystem, [scriptblock] $CommandPrompt
        )

        # THE WINDOW IS NOT WHAT IS UNDER TEST. What matters is that the payload
        # asked for Get-HDTWizardHarvest's list and gets a bag back keyed by the
        # same names a real window would fill.
        return [pscustomobject] @{
            Action   = $script:welcomeAction
            Title    = $Title
            XamlPath = $XamlPath
            Value    = $script:welcomeValue
        }
    }

    function Get-HDTWizardSkip {
        [CmdletBinding()]
        param([object] $Bootstrap, [hashtable] $Variable)

        return [pscustomobject] @{ Welcome = $false; Pane = @() }
    }

    function Get-HDTNetworkConfiguration {
        [CmdletBinding()]
        param([object] $CimProvider)

        return $null
    }

    function Get-HDTWizardField {
        [CmdletBinding()]
        param([object] $NetworkConfiguration, [object] $Bootstrap)

        return @()
    }

    function Hide-HDTShellWindow {
        [CmdletBinding()]
        param([switch] $Restore)

        return $true
    }

    function Start-HDTCommandPrompt {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A hand-written fake of an existing command; it starts nothing and must keep that command''s name.')]
        [CmdletBinding()]
        param([string] $FilePath)

        return [pscustomobject] @{ Started = $true; FilePath = 'X:\Windows\System32\cmd.exe' }
    }

    function Set-HDTStaticAddress {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A hand-written fake. It records what it was asked to do and changes nothing.')]
        [CmdletBinding()]
        param(
            [string] $IPAddress, [string] $SubnetMask, [string] $Gateway = '',
            [string[]] $DnsServer, [object] $InterfaceIndex, [object] $CimProvider
        )

        $script:staticCall += [pscustomobject] @{
            IPAddress  = [string] $IPAddress
            SubnetMask = [string] $SubnetMask
            Gateway    = [string] $Gateway
            DnsServer  = @(@($DnsServer) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
        }

        return [pscustomobject] @{ IPAddress = $IPAddress; Applied = $true }
    }

    function New-HDTContentProvider {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A hand-written fake of an existing command; it changes no state and must keep that command''s name.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
            Justification = 'The parameter takes the same object the real New-HDTContentProvider does; nothing here is a plain-text password.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '',
            Justification = 'It mirrors the real command, which accepts the credential as an object so a fake can be handed one.')]
        [CmdletBinding()]
        param([string] $Provider, [string] $Root, [object] $Credential, [object] $FileSystem)

        $userName = ''
        $password = ''
        if ($null -ne $Credential) {
            $userName = [string] $Credential.UserName
            $password = [string] $Credential.GetNetworkCredential().Password
        }

        $script:providerBuilt += [pscustomobject] @{
            Root     = [string] $Root
            UserName = $userName
            Password = $password
        }

        # WHICH PASS SUCCEEDS is the whole shape of a retry test: the run that
        # matters is the one where pass one is refused and pass two must carry
        # what the technician just typed.
        $shouldFail = ($script:providerBuilt.Count -lt $script:providerSucceedAt)

        # THE CLOSURE IS BUILT INTO A VARIABLE FIRST, and that is not tidiness.
        # In argument mode `-Value { ... }.GetNewClosure()` parses the trailing
        # call as a SEPARATE bareword argument: Add-Member binds it elsewhere,
        # the method is added without its closure, and the fake hands back a
        # STRING. Every connect then failed with "[System.String] does not
        # contain a method named 'Connect'" - a fake that was wrong rather than
        # a caller that was, which is the failure mode CLAUDE.md lists last in
        # its table of surfaces.
        $connect = {
            if ($shouldFail) { throw 'The user name or password is incorrect.' }
            return $true
        }.GetNewClosure()

        # NOT $provider. That is this function's own [string] $Provider parameter
        # - variable names are case-insensitive - so assigning an object to it
        # COERCES IT TO A STRING, and every connect then failed with
        # "[System.String] does not contain a method named 'Connect'". A fake
        # that was wrong rather than a caller that was, which is the last row of
        # CLAUDE.md's table of surfaces.
        $stub = [pscustomobject] @{ Warning = @() }
        $stub | Add-Member -MemberType ScriptMethod -Name Connect -Value $connect

        return $stub
    }

    function Resolve-HDTDeployRoot {
        [CmdletBinding()]
        param([string] $DeployRoot, [string] $Provider, [string[]] $CandidateRoot,
            [string] $Marker, [object] $FileSystem)

        return [pscustomobject] @{ Path = [string] $DeployRoot; Source = 'Welcome' }
    }

    # -- the harnesses --------------------------------------------------------

    function Invoke-HDTWelcomeProbe {
        <#
            .SYNOPSIS
                Runs the payload's own $showWelcome closure against the fakes,
                with a given set of typed-in values.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
            Justification = 'These are the variables the extracted closure reads out of its caller scope; the analyzer cannot follow a scriptblock built from source text.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [hashtable] $Typed = @{},
            [string] $Action = 'Next',
            [string] $EmbeddedShare = '\\OLD-SERVER\HDTShare$'
        )

        $script:welcomeAction = $Action
        $script:welcomeValue = $Typed
        $script:staticCall = @()
        $script:said = @()

        # The variables the closure closes over in Start-HDTDeployment.ps1.
        $bootstrap = [pscustomobject] @{
            Provider      = 'Smb'
            DeployRoot    = $EmbeddedShare
            UserName      = 'OLD-SERVER\svc-hdt-deploy'
            ContentMarker = 'rules.yaml'
            WorkspaceId   = 'probe'
        }
        $cim = [pscustomobject] @{ Name = 'fake ICimProvider' }
        $result = @{}
        $shellHidden = $true
        $WelcomeXamlPath = 'X:\HDT\UI\HDTWelcome.xaml'
        $WizardThemePath = 'X:\HDT\UI\HDTTheme.xaml'
        $closeStatus = { }
        $openStatus = { }
        $say = {
            param([string] $Message, [string] $Level = 'Information')
            $script:said += ('{0}: {1}' -f $Level, $Message)
        }

        $showWelcome = [scriptblock]::Create($script:showWelcomeSource)

        return (& $showWelcome)
    }

    function Invoke-HDTConnectLoopProbe {
        <#
            .SYNOPSIS
                Runs the payload's own connect-and-retry loop against the fakes.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
            Justification = 'These are the variables the extracted loop reads out of its caller scope; the analyzer cannot follow a scriptblock built from source text.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [object[]] $Answer = @(),
            [int] $SucceedOnPass = 2,
            [object] $Embedded,
            [string] $Share = '\\OLD-SERVER\HDTShare$'
        )

        $script:providerBuilt = @()
        $script:providerSucceedAt = $SucceedOnPass
        $script:said = @()

        # ONE ATTEMPT PER PASS. The five the payload defaults to are a transient
        # network, not a wrong password, and they would only add four identical
        # rows and twenty seconds of Start-Sleep to every assertion here.
        $ConnectAttempt = 1

        $bootstrap = [pscustomobject] @{
            Provider = 'Smb'; DeployRoot = $Share; ContentMarker = 'rules.yaml'
        }
        $fileSystem = [pscustomobject] @{ Name = 'fake IFileSystem' }
        $candidateRoot = [string[]] @('X:\')
        $deployRoot = [pscustomobject] @{ Path = $Share; Source = 'Bootstrap' }
        $result = @{}
        $content = $null
        $say = {
            param([string] $Message, [string] $Level = 'Information')
            $script:said += ('{0}: {1}' -f $Level, $Message)
        }

        $providerArgument = @{
            Provider   = 'Smb'
            Root       = [string] $deployRoot.Path
            FileSystem = $fileSystem
        }
        if ($null -ne $Embedded) { $providerArgument['Credential'] = $Embedded }

        # A HASHTABLE THE CLOSURE CARRIES, not a $script: variable. GetNewClosure
        # snapshots the local scope, and a scope-qualified counter read from
        # inside it comes back $null - which fails as an index error a long way
        # from its cause.
        $tally = @{ Shown = 0 }

        $queued = @($Answer)
        $showWelcome = {
            $index = [int] $tally['Shown']
            $tally['Shown'] = $index + 1

            if ($index -lt $queued.Count) { return $queued[$index] }

            # NOBODY IS ANSWERING ANY MORE, which is how a bounded test of an
            # unbounded loop ends: the technician walks away and the run is
            # cancelled rather than looping for ever.
            return [pscustomobject] @{ Retry = $false; DeployRoot = ''; Credential = $null }
        }.GetNewClosure()

        $thrown = ''
        try {
            $connectLoop = [scriptblock]::Create($script:connectLoopSource)
            & $connectLoop
        } catch {
            $thrown = [string] $_.Exception.Message
        }

        return [pscustomobject] @{
            Built            = @($script:providerBuilt)
            Shown            = [int] $tally['Shown']
            ProviderArgument = $providerArgument
            Thrown           = $thrown
            Said             = @($script:said)
        }
    }

    function New-HDTProbeCredential {
        # -Name AND -Secret RATHER THAN -UserName AND -Password, because the
        # analyzer refuses that pair outright and it is right to: a real command
        # taking both is a command handing a password around in clear. Here it
        # is test data with nothing to protect, and renaming costs less than
        # teaching the next reader to ignore a suppression.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'It builds an in-memory credential for a fake; it changes no state.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
            Justification = 'Test data. There is no secret here to protect.')]
        [CmdletBinding()]
        [OutputType([pscredential])]
        param([string] $Name, [string] $Secret)

        return (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                $Name, (ConvertTo-SecureString -String $Secret -AsPlainText -Force)))
    }

    function Get-HDTWelcomeFingerprint {
        <#
            .SYNOPSIS
                Everything the Welcome screen's answer can change, as one
                string - so "this box changed nothing" is one comparison.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([object] $Answer, [object[]] $StaticCall)

        $credential = 'none'
        if ($null -ne $Answer.Credential) {
            $credential = '{0}/{1}' -f $Answer.Credential.UserName,
            $Answer.Credential.GetNetworkCredential().Password
        }

        $static = (@(@($StaticCall) | ForEach-Object {
                    '{0}|{1}|{2}|{3}' -f $_.IPAddress, $_.SubnetMask, $_.Gateway, (@($_.DnsServer) -join ',')
                }) -join ';')

        return ('retry={0} root={1} credential={2} static=[{3}]' -f
            $Answer.Retry, $Answer.DeployRoot, $credential, $static)
    }

    # THE FULL SCREEN, every box carrying something a technician would plausibly
    # have typed. The set-driven assertion clears these one at a time.
    $script:everyBoxFilled = @{
        HDTDeployRootBox  = '\\NEW-SERVER\HDTShare$'
        HDTUseStaticRadio = $true
        HDTIpAddressBox   = '192.0.2.50'
        HDTSubnetMaskBox  = '255.255.255.0'
        HDTGatewayBox     = '192.0.2.1'
        HDTDnsBox         = '192.0.2.10'
        HDTUserIdBox      = 'tech'
        HDTUserDomainBox  = 'CORP'
        HDTPasswordBox    = 'the-retyped-password'
    }
}

Describe 'the Welcome screen answer' {

    It 'is a closure this test could lift out of the payload' {
        # If this fails, everything below is testing nothing - so it says so
        # rather than passing vacuously.
        $script:showWelcomeSource | Should -Not -BeNullOrEmpty
    }

    It 'composes the retyped account into a credential' {
        $answer = Invoke-HDTWelcomeProbe -Typed @{
            HDTDeployRootBox = '\\OLD-SERVER\HDTShare$'
            HDTUserIdBox     = 'tech'
            HDTUserDomainBox = 'CORP'
            HDTPasswordBox   = 'the-retyped-password'
        }

        $answer.Credential | Should -Not -BeNullOrEmpty
        $answer.Credential.UserName | Should -Be 'CORP\tech'
        $answer.Credential.GetNetworkCredential().Password | Should -Be 'the-retyped-password'
    }

    It 'reads a domain typed into the user box rather than doubling it' {
        # Split-HDTAccountName's job, and the reason this file does not parse a
        # backslash of its own: CORP\CORP\tech is what hand-rolling it produces.
        $answer = Invoke-HDTWelcomeProbe -Typed @{
            HDTDeployRootBox = '\\OLD-SERVER\HDTShare$'
            HDTUserIdBox     = 'CORP\tech'
            HDTUserDomainBox = ''
            HDTPasswordBox   = 'the-retyped-password'
        }

        $answer.Credential.UserName | Should -Be 'CORP\tech'
    }

    It 'reads a UPN typed into the user box' {
        $answer = Invoke-HDTWelcomeProbe -Typed @{
            HDTDeployRootBox = '\\OLD-SERVER\HDTShare$'
            HDTUserIdBox     = 'tech@corp.contoso.com'
            HDTPasswordBox   = 'the-retyped-password'
        }

        $answer.Credential.UserName | Should -Be 'corp.contoso.com\tech'
    }

    It 'treats a blank domain as an account local to the server the share names' {
        # Get-HDTWizardCredential's rule, and a technician must be able to say
        # "this account is LOCAL to that server" without knowing the convention
        # is to type a server name where a domain goes.
        $answer = Invoke-HDTWelcomeProbe -Typed @{
            HDTDeployRootBox = '\\NEW-SERVER\HDTShare$'
            HDTUserIdBox     = 'tech'
            HDTUserDomainBox = ''
            HDTPasswordBox   = 'the-retyped-password'
        }

        $answer.Credential.UserName | Should -Be 'NEW-SERVER\tech'
    }

    It 'answers no credential at all when the boxes were cleared' {
        # THE PRECEDENCE, ASSERTED: empty is "keep what this run already has",
        # never "connect with nothing". $null is how the loop is told to leave
        # $providerArgument['Credential'] alone.
        $answer = Invoke-HDTWelcomeProbe -Typed @{
            HDTDeployRootBox = '\\NEW-SERVER\HDTShare$'
            HDTUserIdBox     = ''
            HDTUserDomainBox = ''
            HDTPasswordBox   = ''
        }

        $answer.Credential | Should -BeNullOrEmpty
        $answer.DeployRoot | Should -Be '\\NEW-SERVER\HDTShare$'
    }

    It 'answers no credential for half of one' {
        # A user with no password cannot be composed at all, and half a typed
        # credential is not a better guess than the one already in hand.
        $withoutPassword = Invoke-HDTWelcomeProbe -Typed @{
            HDTDeployRootBox = '\\NEW-SERVER\HDTShare$'
            HDTUserIdBox     = 'tech'
            HDTPasswordBox   = ''
        }

        $withoutUser = Invoke-HDTWelcomeProbe -Typed @{
            HDTDeployRootBox = '\\NEW-SERVER\HDTShare$'
            HDTUserIdBox     = ''
            HDTPasswordBox   = 'the-retyped-password'
        }

        $withoutPassword.Credential | Should -BeNullOrEmpty
        $withoutUser.Credential | Should -BeNullOrEmpty
    }

    It 'never puts the password in anything it says out loud' {
        [void] (Invoke-HDTWelcomeProbe -Typed $script:everyBoxFilled)

        (@($script:said) -join "`n") | Should -Not -Match 'the-retyped-password'
    }

    It 'applies the static address the technician typed' {
        # Set-HDTStaticAddress had no caller anywhere in the product, so the
        # network pane was decorative in exactly the way the credential pane was.
        [void] (Invoke-HDTWelcomeProbe -Typed $script:everyBoxFilled)

        @($script:staticCall).Count | Should -Be 1
        $script:staticCall[0].IPAddress | Should -Be '192.0.2.50'
        $script:staticCall[0].SubnetMask | Should -Be '255.255.255.0'
        $script:staticCall[0].Gateway | Should -Be '192.0.2.1'
        @($script:staticCall[0].DnsServer) | Should -Contain '192.0.2.10'
    }

    It 'leaves the network alone when the static radio was not chosen' {
        # A box holding the DHCP lease it was PREFILLED with is not a request to
        # nail that address down - Get-HDTWizardHarvest says so about this exact
        # control.
        $typed = @{} + $script:everyBoxFilled
        $typed['HDTUseStaticRadio'] = $false

        [void] (Invoke-HDTWelcomeProbe -Typed $typed)

        @($script:staticCall).Count | Should -Be 0
    }
}

Describe 'a share that refused the credential' {

    It 'is a loop this test could lift out of the payload' {
        $script:connectLoopSource | Should -Not -BeNullOrEmpty
    }

    It 'reconnects with the password the technician retyped, not the one that was rejected' {
        # THE REGRESSION. A technician is told the credential was rejected,
        # retypes it into the box the screen put in front of them, and pass two
        # went back with the SAME rejected account - so the retry could only ever
        # fix a wrong path. If this fails, that is what a technician at a bench
        # is looking at.
        $probe = Invoke-HDTConnectLoopProbe -SucceedOnPass 2 `
            -Embedded (New-HDTProbeCredential -Name 'OLD-SERVER\svc-hdt-deploy' -Secret 'the-rejected-password') `
            -Answer @(
            [pscustomobject] @{
                Retry      = $true
                DeployRoot = ''
                Credential = (New-HDTProbeCredential -Name 'CORP\tech' -Secret 'the-retyped-password')
            }
        )

        @($probe.Built).Count | Should -Be 2
        $probe.Built[0].UserName | Should -Be 'OLD-SERVER\svc-hdt-deploy'

        $probe.Built[1].UserName | Should -Be 'CORP\tech' -Because 'pass two must connect as the account that was just retyped'
        $probe.Built[1].Password | Should -Be 'the-retyped-password' -Because 'the retyped password was read off the window and then discarded'
    }

    It 'reconnects with the share path the technician retyped' {
        # THE ONE THING THAT ALREADY WORKED. It has to keep working.
        $probe = Invoke-HDTConnectLoopProbe -SucceedOnPass 2 `
            -Embedded (New-HDTProbeCredential -Name 'OLD-SERVER\svc' -Secret 'p') `
            -Answer @(
            [pscustomobject] @{
                Retry      = $true
                DeployRoot = '\\NEW-SERVER\HDTShare$'
                Credential = $null
            }
        )

        $probe.Built[1].Root | Should -Be '\\NEW-SERVER\HDTShare$'
    }

    It 'reconnects with both when both were corrected at once' {
        $probe = Invoke-HDTConnectLoopProbe -SucceedOnPass 2 `
            -Embedded (New-HDTProbeCredential -Name 'OLD-SERVER\svc' -Secret 'the-rejected-password') `
            -Answer @(
            [pscustomobject] @{
                Retry      = $true
                DeployRoot = '\\NEW-SERVER\HDTShare$'
                Credential = (New-HDTProbeCredential -Name 'NEW-SERVER\tech' -Secret 'the-retyped-password')
            }
        )

        $probe.Built[1].Root | Should -Be '\\NEW-SERVER\HDTShare$'
        $probe.Built[1].UserName | Should -Be 'NEW-SERVER\tech'
        $probe.Built[1].Password | Should -Be 'the-retyped-password'
    }

    It 'keeps the embedded account when the technician cleared the boxes' {
        # THE PRECEDENCE THAT PROTECTS A WORKING ZERO-TOUCH IMAGE. Empty boxes
        # must not become an anonymous connect: DESIGN 6.3 refuses a guest
        # session, so the failure would arrive as a security refusal describing
        # an account nobody chose.
        $probe = Invoke-HDTConnectLoopProbe -SucceedOnPass 2 `
            -Embedded (New-HDTProbeCredential -Name 'OLD-SERVER\svc-hdt-deploy' -Secret 'the-embedded-password') `
            -Answer @(
            [pscustomobject] @{
                Retry      = $true
                DeployRoot = '\\NEW-SERVER\HDTShare$'
                Credential = $null
            }
        )

        $probe.Built[1].UserName | Should -Be 'OLD-SERVER\svc-hdt-deploy'
        $probe.Built[1].Password | Should -Be 'the-embedded-password'
    }

    It 'shows the screen again when the second attempt is refused as well' {
        # THE BOUND. The outer loop is while ($true): every refusal puts the
        # technician back in front of the screen, for as long as they keep
        # answering it. What ends the run is Cancel, not a count - because a
        # count would power a machine off in front of somebody who was fixing it.
        $probe = Invoke-HDTConnectLoopProbe -SucceedOnPass 3 `
            -Embedded (New-HDTProbeCredential -Name 'OLD-SERVER\svc' -Secret 'the-rejected-password') `
            -Answer @(
            [pscustomobject] @{
                Retry      = $true
                DeployRoot = ''
                Credential = (New-HDTProbeCredential -Name 'CORP\tech' -Secret 'the-first-guess')
            }
            [pscustomobject] @{
                Retry      = $true
                DeployRoot = ''
                Credential = (New-HDTProbeCredential -Name 'CORP\tech' -Secret 'the-second-guess')
            }
        )

        $probe.Shown | Should -Be 2 -Because 'a second refusal must return the technician to the screen, not end the run'
        $probe.Thrown | Should -BeNullOrEmpty
        @($probe.Built).Count | Should -Be 3
        $probe.Built[2].Password | Should -Be 'the-second-guess'
    }

    It 'ends the run when the technician leaves the screen instead of answering' {
        $probe = Invoke-HDTConnectLoopProbe -SucceedOnPass 99 `
            -Embedded (New-HDTProbeCredential -Name 'OLD-SERVER\svc' -Secret 'p') `
            -Answer @()

        $probe.Thrown | Should -BeLike '*HDTDeploymentCancelled*'
    }
}

Describe 'every box the Welcome screen collects' {

    It 'changes what happens next, or it is being read and thrown away' {
        # RULE 8, IN ITS GENERAL FORM. Driven off Get-HDTWizardHarvest rather
        # than a list written here, so the next control added to that screen
        # cannot be silently dropped the way the credential quartet was: clearing
        # it has to change the outcome, and a box nothing consumes cannot.
        $baseline = Invoke-HDTWelcomeProbe -Typed $script:everyBoxFilled
        $baselinePrint = Get-HDTWelcomeFingerprint -Answer $baseline -StaticCall $script:staticCall

        foreach ($control in @(Get-HDTWizardHarvest)) {

            $cleared = @{} + $script:everyBoxFilled
            $empty = ''
            if ([string] $control.Property -eq 'IsChecked') { $empty = $false }
            $cleared[[string] $control.Name] = $empty

            $answer = Invoke-HDTWelcomeProbe -Typed $cleared
            $print = Get-HDTWelcomeFingerprint -Answer $answer -StaticCall $script:staticCall

            $print | Should -Not -Be $baselinePrint -Because (
                "clearing {0} changed nothing, so the Welcome screen reads that box and throws the value away - which is the defect that sent a technician's retyped password nowhere" -f $control.Name)
        }
    }

    It 'is prefilled by Get-HDTWizardField or is a password the technician supplies' {
        # The other half of the round trip, and the reason an empty box means
        # "keep what we have" rather than "the technician meant nothing": the
        # boxes come up FULL, so blank is a deliberate clearing.
        # MODULE-QUALIFIED, because this file defines a fake of the same name for
        # the closure under test and this assertion needs the real one.
        $field = @(Hephaestus\Get-HDTWizardField -NetworkConfiguration ([pscustomobject] @{
                    IPAddress = '192.0.2.9'; SubnetMask = '255.255.255.0'
                    Gateway   = '192.0.2.1'; DnsServerText = '192.0.2.10'
                }) -Bootstrap ([pscustomobject] @{
                    DeployRoot = '\\OLD-SERVER\HDTShare$'; UserName = 'OLD-SERVER\svc'; Password = 'p'
                }))

        $prefilled = @($field | ForEach-Object { [string] $_.Name })

        foreach ($name in @('HDTDeployRootBox', 'HDTUserIdBox', 'HDTUserDomainBox')) {
            $prefilled | Should -Contain $name
        }
    }
}
