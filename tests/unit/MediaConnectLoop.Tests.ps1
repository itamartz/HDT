# A SHARE BOX OFFERED TO A MACHINE THAT BOOTED FROM A DISC.
#
# The connect-and-retry loop in Start-HDTDeployment.ps1 is right for SMB and has
# been proved right on iron: WinPE has just brought a network up, the switch may
# still be learning, the lease may be seconds old, and the server may have no
# session yet for a client that has only just appeared. Five attempts with a
# 2/4/6/8 second backoff costs twenty seconds and saves a deployment; the Welcome
# screen behind it puts a prefilled share box in front of the one person who can
# correct an address that moved.
#
# NONE OF THAT IS TRUE OF MEDIA. Resolve-HDTDeployRoot has already found the
# content marker on a volume this machine is standing on. If the provider still
# cannot open it, no switch is learning and no lease is settling: retrying buys
# twenty seconds of sleeping and the same answer, and the screen after it asks a
# technician to type a UNC path for a deployment that has no share.
#
# SO EVERY ASSERTION HERE IS WRITTEN IN BOTH DIRECTIONS, and the five UNC ones
# matter most: a change that quietly disables the SMB path passes a test written
# only for the disc, and every share-based deployment in this lab depends on the
# ladder staying exactly as it is.
#
# THE HARNESS IS WelcomeRetryCredential.Tests.ps1's, not a second one. That file
# lifts the payload's own `while` loop out by AST and executes it against
# hand-written fakes, because the rest of StartHDTDeploymentPayload.Tests.ps1
# reads the payload as TEXT and a text scan is what let the last defect ship.
# Two of its traps are carried across with their reasons, because both will bite
# again - see the comments in New-HDTContentProvider below.
#
# Start-Sleep IS MOCKED, NOT REDEFINED. tests/contract/Naming.Contract.Tests.ps1
# enumerates every function defined anywhere under tests/ and requires
# Verb-HDTNoun with an uppercase HDT prefix, so `function Start-Sleep` here would
# fail the gate. It is also the adapter boundary Mock is reserved for: a built-in
# with nothing worth hand-writing, asserted with Should -Invoke and the -Seconds
# it was asked for. This file must never actually sleep.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'

    $script:payloadToken = $null
    $script:payloadError = $null
    $script:payloadAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:payloadPath, [ref] $script:payloadToken, [ref] $script:payloadError)

    # BY AST AND NOT BY LINE NUMBER, because the file is edited constantly and a
    # test pinned to line 1129 would silently start testing something else.
    $script:connectLoopSource = ''
    $loop = @($script:payloadAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.WhileStatementAst]
            }, $true) | Where-Object { $_.Extent.Text -match "providerArgument\['Root'\]" })

    if ($loop.Count -eq 1) { $script:connectLoopSource = [string] $loop[0].Extent.Text }

    # -- the fakes ------------------------------------------------------------

    $script:said = @()
    $script:providerBuilt = @()
    $script:providerSucceedAt = 1

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
        if ($null -ne $Credential) { $userName = [string] $Credential.UserName }

        $script:providerBuilt += [pscustomobject] @{
            Root     = [string] $Root
            Provider = [string] $Provider
            UserName = $userName
        }

        $shouldFail = ($script:providerBuilt.Count -lt $script:providerSucceedAt)

        # THE CLOSURE IS BUILT INTO A VARIABLE FIRST, and that is not tidiness.
        # In argument mode `-Value { ... }.GetNewClosure()` parses the trailing
        # call as a SEPARATE bareword argument: Add-Member binds it elsewhere,
        # the method is added without its closure, and the fake hands back a
        # STRING.
        $connect = {
            if ($shouldFail) { throw 'The device is not ready.' }
            return $true
        }.GetNewClosure()

        # NOT $provider. That is this function's own [string] $Provider parameter
        # - variable names are case-insensitive - so assigning an object to it
        # COERCES IT TO A STRING, and every connect then failed with
        # "[System.String] does not contain a method named 'Connect'". A fake
        # that was wrong rather than a caller that was.
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

    function New-HDTProbeCredential {
        # -Name AND -Secret RATHER THAN -UserName AND -Password: the analyzer
        # refuses that pair outright, and it is right to.
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

    function Invoke-HDTMediaConnectProbe {
        <#
            .SYNOPSIS
                Runs the payload's own connect-and-retry loop against the fakes,
                under a given deployment method.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
            Justification = 'These are the variables the extracted loop reads out of its caller scope; the analyzer cannot follow a scriptblock built from source text.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [ValidateSet('UNC', 'MEDIA')]
            [string] $Method = 'UNC',

            [object[]] $Answer = @(),

            # 0 IS "NEVER OPENS", which is the run every assertion here is
            # about. 1 is "opens on the first attempt".
            [int] $SucceedOnPass = 0,

            [string] $Root = '\\OLD-SERVER\HDTShare$',

            [string[]] $Volume = @('X:\', 'D:\', 'E:\')
        )

        $script:providerBuilt = @()
        $script:providerSucceedAt = $SucceedOnPass
        if ($SucceedOnPass -le 0) { $script:providerSucceedAt = [int]::MaxValue }
        $script:said = @()

        # THE PAYLOAD'S OWN DEFAULT, not the 1 WelcomeRetryCredential sets. The
        # attempt count IS the thing under test here, so it cannot be dodged -
        # which is why Start-Sleep is mocked instead.
        $ConnectAttempt = 5

        $deploymentMethod = $Method

        $providerName = 'Smb'
        if ($Method -eq 'MEDIA') { $providerName = 'Local' }

        $bootstrap = [pscustomobject] @{
            Provider = $providerName; DeployRoot = $Root; ContentMarker = 'rules.yaml'
        }
        $fileSystem = [pscustomobject] @{ Name = 'fake IFileSystem' }
        $candidateRoot = [string[]] @($Volume)
        $deployRoot = [pscustomobject] @{ Path = $Root; Source = 'Bootstrap' }
        $result = @{}
        $content = $null
        $say = {
            param([string] $Message, [string] $Level = 'Information')
            $script:said += ('{0}: {1}' -f $Level, $Message)
        }

        $providerArgument = @{
            Provider   = $providerName
            Root       = [string] $deployRoot.Path
            FileSystem = $fileSystem
        }

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
            # unbounded loop ends.
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
            Result           = $result
        }
    }
}

Describe 'a content root that will not open' {

    BeforeAll {
        # NEVER LET THIS FILE SLEEP. Twenty seconds per UNC assertion, and the
        # count and the -Seconds are what is being asserted anyway.
        Mock -CommandName Start-Sleep -MockWith { }
    }

    It 'is a loop this test could lift out of the payload' {
        # If this fails, everything below is testing nothing - so it says so
        # rather than passing vacuously.
        $script:connectLoopSource | Should -Not -BeNullOrEmpty
    }

    Context 'under UNC, where the cause is usually an address that moved' {

        It 'tries five times before it gives up' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'UNC'

            # Five on the first pass, then the Welcome screen, then five more on
            # the second pass before the technician walks away.
            @($probe.Built | Select-Object -First 5).Count | Should -Be 5
        }

        It 'backs off 2, 4, 6 and 8 seconds between them' {
            $null = Invoke-HDTMediaConnectProbe -Method 'UNC' -Answer @(
                [pscustomobject] @{ Retry = $false; DeployRoot = ''; Credential = $null })

            foreach ($second in @(2, 4, 6, 8)) {
                $wanted = $second
                Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq $wanted }
            }

            # AND NOT A FIFTH. The gap after the last attempt would be a wait
            # for nothing: there is no sixth attempt to wait for.
            Should -Invoke Start-Sleep -Times 0 -Exactly -ParameterFilter { $Seconds -eq 10 }
        }

        It 'opens the Welcome screen with the share box, so a technician can correct it' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'UNC' -Answer @(
                [pscustomobject] @{ Retry = $false; DeployRoot = ''; Credential = $null })

            $probe.Shown | Should -Be 1
        }

        It 'reconnects with the share the technician typed' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'UNC' -Answer @(
                [pscustomobject] @{ Retry = $true; DeployRoot = '\\NEW-SERVER\HDTShare$'; Credential = $null })

            @($probe.Built | Where-Object { $_.Root -eq '\\NEW-SERVER\HDTShare$' }).Count |
                Should -BeGreaterThan 0
        }

        It 'reconnects with the account the technician retyped' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'UNC' -Answer @(
                [pscustomobject] @{
                    Retry      = $true
                    DeployRoot = '\\NEW-SERVER\HDTShare$'
                    Credential = (New-HDTProbeCredential -Name 'CORP\tech' -Secret 'the-retyped-password')
                })

            @($probe.Built | Where-Object { $_.UserName -eq 'CORP\tech' }).Count | Should -BeGreaterThan 0
        }

        It 'ends the run when the technician leaves the screen without answering' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'UNC'

            $probe.Thrown | Should -BeLike 'HDTDeploymentCancelled*'
        }
    }

    Context 'under MEDIA, where there is nothing to correct' {

        It 'tries once and does not try again' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\'

            @($probe.Built).Count | Should -Be 1
        }

        It 'never sleeps between attempts, because there is no second attempt' {
            $null = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\'

            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'never opens the Welcome screen' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\'

            $probe.Shown | Should -Be 0
        }

        It 'never asks for a UNC path for a machine that booted from a disc' {
            # THE SAME FACT SAID THE OTHER WAY ROUND, and it is the one that
            # would have caught the defect: the screen is not merely skipped,
            # the run never gets as far as offering a share to type.
            $probe = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\'

            $probe.Thrown | Should -Not -BeLike 'HDTDeploymentCancelled*'
            $probe.Shown | Should -Be 0
        }

        It 'fails with what is actually wrong: the content is not on any ready volume' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\'

            $probe.Thrown | Should -BeLike 'HDTContentUnreachable*'
            $probe.Thrown | Should -BeLike '*D:\*'
        }

        It 'names the volumes it considered, so an admin knows what it looked at' {
            # THE WHOLE INVESTIGATION. Resolve-HDTDeployRoot found the marker on
            # one of these and this still could not be opened, so which ones
            # were there is the difference between "the disc was ejected" and
            # "the drive letter moved".
            $probe = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\' -Volume @('X:\', 'D:\', 'E:\')

            foreach ($volume in @('X:\', 'D:\', 'E:\')) {
                $probe.Thrown | Should -BeLike ('*{0}*' -f $volume)
            }
        }

        It 'says the method and that it is why there was no retry' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\'

            $probe.Thrown | Should -BeLike '*MEDIA*'
            $probe.Thrown | Should -BeLike '*no share to correct*'
        }

        It 'carries the underlying error, so the reason is not thrown away' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\'

            $probe.Thrown | Should -BeLike '*The device is not ready.*'
        }

        It 'says the same thing to the log at Warning, for the run whose screen nobody sees' {
            $probe = Invoke-HDTMediaConnectProbe -Method 'MEDIA' -Root 'D:\'

            @($probe.Said | Where-Object { $_ -like 'Warning: *' -and $_ -like '*MEDIA*' }).Count |
                Should -BeGreaterThan 0
        }
    }

    Context 'the two paths are the same code' {

        It 'reaches a root that opens on the first attempt under either method' {
            foreach ($method in @('UNC', 'MEDIA')) {
                $probe = Invoke-HDTMediaConnectProbe -Method $method -SucceedOnPass 1

                @($probe.Built).Count | Should -Be 1
                $probe.Shown | Should -Be 0
                $probe.Thrown | Should -BeExactly ''
                [bool] $probe.Result['connected'] | Should -BeFalse -Because 'the flag is set after the loop, not inside it'
            }
        }

        It 'gates on $deploymentMethod and on no other reading of the provider' {
            # ONE VALUE, DECIDED ONCE IN SECTION 7. A gate that read
            # $bootstrap.Provider here would be a second derivation, and the two
            # can disagree - which is the failure the ROADMAP settled against.
            $comparison = @([System.Management.Automation.Language.Parser]::ParseInput(
                    $script:connectLoopSource, [ref] $null, [ref] $null).FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.BinaryExpressionAst]
                    }, $true) |
                    Where-Object {
                        ([string] $_.Left.Extent.Text) -match "^'(MEDIA|UNC|Local|Smb)'$" -or
                        ([string] $_.Right.Extent.Text) -match "^'(MEDIA|UNC|Local|Smb)'$"
                    })

            @($comparison).Count | Should -BeGreaterThan 0

            $wrongSide = @($comparison | Where-Object {
                    ([string] $_.Left.Extent.Text) -ne '$deploymentMethod' -and
                    ([string] $_.Right.Extent.Text) -ne '$deploymentMethod'
                })

            @($wrongSide | ForEach-Object { $_.Extent.Text }) | Should -Be @()
        }
    }
}
