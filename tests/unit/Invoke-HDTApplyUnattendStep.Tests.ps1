# The unattend, staged where SPIKES S7 proved Setup consumes it.
#
#   <target>:\Windows\Panther\unattend.xml
#
# THAT PATH IS THE VERIFIED ONE AND NOTHING ELSE IS. S7 deployed a real Windows
# 11 machine from a document staged there: ComputerName applied in the specialize
# pass, OOBE skipped, the built-in Administrator enabled, FirstLogonCommands run
# and autologon armed with the password held as an LSA secret.
#
# THE PASSWORD IS THE REASON THIS FILE IS LONG. The expansion substitutes
# %HDTAdminPassword%, and there are exactly three places it can come from:
#
#   1. a resolved HDTAdminPassword variable;
#   2. the run state's deploymentPassword;
#   3. a freshly minted one, WRITTEN BACK TO THE STATE.
#
# Step 3 is not tidiness. Invoke-HDTTaskSequence mints the deployment password
# only when a step returns RebootRequested, and DEMO-M3 has no Restart step - so
# without it the token stays unresolved, Expand-HDTVariableToken leaves it
# literal, and HDT deploys a machine whose local Administrator password is the
# string '%HDTAdminPassword%', identical on every machine it ever builds. That is
# worse than a failed step and it would have shipped green.
#
# And the document is never logged, at any level.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # The S7 document itself, read off disk so the fixture and this test cannot
    # drift apart.
    $script:fixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/unattend/win11-client.xml'
    $script:unattendXml = Get-Content -LiteralPath $script:fixturePath -Raw

    $script:workspaceRoot = 'Z:\Deploy'
    $script:sequenceId = 'DEMO-M3'
    $script:templatePath = 'Z:\Deploy\TaskSequences\DEMO-M3\unattend.xml'
    $script:pantherPath = 'W:\Windows\Panther\unattend.xml'

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 4; Name = 'Apply Unattend'; Type = 'ApplyUnattend'; TimeoutMinutes = 0; Log = $null; Property = $bag
        }
    }
}

Describe 'Invoke-HDTApplyUnattendStep' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:unattendXml }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc))

        $script:newContextFor = {
            param([System.Collections.IDictionary] $Variable, [object] $State)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTComputerName'] = 'HDT-M3-01'
            $live['HDTTaskSequenceID'] = $script:sequenceId
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            $argument = @{
                RunId = 'run-0001'; Phase = 'WinPE'; WorkspaceRoot = $script:workspaceRoot
                Variable = $live; Service = $catalog; Log = $log
            }
            if ($null -ne $State) { $argument['State'] = $State }

            return (New-HDTExecutionContext @argument)
        }

        $script:state = New-HDTRunState -SequenceId $script:sequenceId -RunId 'run-0001' -Phase WinPE `
            -Clock $script:clock -Step @()

        $script:context = & $script:newContextFor $null $script:state
        $script:step = & $script:newStep ([ordered] @{ template = 'unattend.xml' })
    }

    Context 'placement' {

        It 'writes to Windows\Panther\unattend.xml on the OS volume' {
            # SPIKES S7's verified path, asserted exactly.
            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            $script:fileSystem.TestPath($script:pantherPath) | Should -BeTrue
        }

        It 'creates the Panther directory first' {
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $written = @($script:fileSystem.Operations |
                    Where-Object { @('CreateDirectory', 'WriteAllText') -contains $_.Operation -and
                        ([string] $_.Arguments[0]) -like 'W:\Windows\Panther*' })

            @($written | ForEach-Object { $_.Operation }) | Should -Be @('CreateDirectory', 'WriteAllText')
        }

        It 'writes through the injected filesystem' {
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            Test-Path -LiteralPath $script:pantherPath | Should -BeFalse
        }

        It 'honours an explicit target drive letter' {
            $step = & $script:newStep ([ordered] @{ template = 'unattend.xml'; target = 'D' })

            Invoke-HDTApplyUnattendStep -Step $step -Context $script:context | Out-Null

            $script:fileSystem.TestPath('D:\Windows\Panther\unattend.xml') | Should -BeTrue
        }

        It 'fails when HDTOSVolume is unset and no target is given' {
            $context = & $script:newContextFor $null $script:state
            $context.Variable['HDTOSVolume'] = ''

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTOSVolume*'
        }

        It 'sets HDTUnattendPath to what it wrote' {
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            [string] $script:context.Variable['HDTUnattendPath'] | Should -BeExactly $script:pantherPath
        }
    }

    Context 'the template' {

        It 'resolves a relative template under the sequence folder' {
            # Built with Get-HDTWorkspacePath: no literal 'TaskSequences'
            # anywhere in the step.
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'ReadAllText' } |
                    ForEach-Object { [string] $_.Arguments[0] }) | Should -Contain $script:templatePath
        }

        It 'resolves it under a UNC workspace root too' {
            $uncTemplate = '\\hdt01\Deploy$\TaskSequences\DEMO-M3\unattend.xml'
            $script:fileSystem.SeedFile($uncTemplate, $script:unattendXml)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug
            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTComputerName'] = 'HDT-M3-01'
            $live['HDTTaskSequenceID'] = $script:sequenceId

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot '\\hdt01\Deploy$' `
                -Variable $live -Service $catalog -Log $log -State $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'ReadAllText' } |
                    ForEach-Object { [string] $_.Arguments[0] }) | Should -Contain $uncTemplate
        }

        It 'uses a rooted template path as given' {
            $rooted = 'Z:\Deploy\Control\golden-unattend.xml'
            $script:fileSystem.SeedFile($rooted, $script:unattendXml)

            $step = & $script:newStep ([ordered] @{ template = $rooted })

            Invoke-HDTApplyUnattendStep -Step $step -Context $script:context | Out-Null

            @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'ReadAllText' } |
                    ForEach-Object { [string] $_.Arguments[0] }) | Should -Contain $rooted
        }

        It 'fails naming the file when the template does not exist' {
            $step = & $script:newStep ([ordered] @{ template = 'no-such-unattend.xml' })

            $result = Invoke-HDTApplyUnattendStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*no-such-unattend.xml*'
        }

        It 'fails when no template is declared' {
            $result = Invoke-HDTApplyUnattendStep -Step (& $script:newStep $null) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*template*'
        }

        It 'expands %HDTComputerName% in the document' {
            # The S7 behaviour: ComputerName applied from the specialize pass.
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)

            $written | Should -BeLike '*<ComputerName>HDT-M3-01</ComputerName>*'
        }

        It 'expands several tokens' {
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = 'Passw0rd-fixture!' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)

            $written | Should -BeLike '*HDT-M3-01*'
            $written | Should -BeLike '*Passw0rd-fixture!*'
        }

        It 'leaves an unresolved token literal and logs it' {
            $script:fileSystem.SeedFile('Z:\Deploy\TaskSequences\DEMO-M3\odd.xml',
                '<unattend><TimeZone>%HDTTimeZoneName%</TimeZone></unattend>')

            $step = & $script:newStep ([ordered] @{ template = 'odd.xml' })

            Invoke-HDTApplyUnattendStep -Step $step -Context $script:context | Out-Null

            $script:fileSystem.ReadAllText($script:pantherPath) | Should -BeLike '*%HDTTimeZoneName%*'

            $record = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' |
                    Where-Object { $_.level -eq 'Warning' -and [string] $_.message -like '*HDTTimeZoneName*' })

            $record | Should -Not -BeNullOrEmpty
        }

        It 'writes the template verbatim when expand is false' {
            $step = & $script:newStep ([ordered] @{ template = 'unattend.xml'; expand = $false })

            Invoke-HDTApplyUnattendStep -Step $step -Context $script:context | Out-Null

            $script:fileSystem.ReadAllText($script:pantherPath) | Should -BeExactly $script:unattendXml
        }

        It 'writes valid XML' {
            # An expansion that breaks the document fails here, not at Setup.
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = 'Passw0rd-fixture!' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            { [xml] $script:fileSystem.ReadAllText($script:pantherPath) } | Should -Not -Throw
        }
    }

    Context 'secrets' {

        It 'substitutes the deployment password for %HDTAdminPassword%' {
            $script:state.deploymentPassword = 'State-Minted-01!'

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $script:fileSystem.ReadAllText($script:pantherPath) | Should -BeLike '*State-Minted-01!*'
        }

        It 'prefers an explicitly resolved HDTAdminPassword variable' {
            $script:state.deploymentPassword = 'State-Minted-01!'
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = 'Authored-01!' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)

            $written | Should -BeLike '*Authored-01!*'
            $written | Should -Not -BeLike '*State-Minted-01!*'
        }

        It 'mints a deployment password when neither the variable nor the state has one' {
            # THE DEMO-M3 CASE EXACTLY: no Restart step, so the loop never minted
            # one, and without this the machine's Administrator password would be
            # the literal string '%HDTAdminPassword%'.
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)

            $written | Should -Not -BeLike '*%HDTAdminPassword%*'
            [string] $script:state.deploymentPassword | Should -Not -BeNullOrEmpty
            $written | Should -BeLike ('*{0}*' -f $script:state.deploymentPassword)
        }

        It 'writes the minted password back to the run state' {
            # So a later Restart arms autologon with the SAME secret: one machine,
            # one secret per run.
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            [string] $script:context.State.deploymentPassword | Should -Not -BeNullOrEmpty
            ([string] $script:context.State.deploymentPassword).Length | Should -BeGreaterOrEqual 16
        }

        It 'writes no literal HDTAdminPassword token into the document' {
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $body = [string] @($script:fileSystem.Operations |
                    Where-Object { $_.Operation -eq 'WriteAllText' -and ([string] $_.Arguments[0]) -eq $script:pantherPath })[0].Arguments[1]

            $body | Should -Not -BeLike '*%HDTAdminPassword%*'
        }

        It 'mints one password for a run, not one per token' {
            # The fixture carries %HDTAdminPassword% twice - Setup reads
            # UserAccounts and AutoLogon separately - and both must be the same
            # secret or the machine cannot log itself on.
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)
            $secret = [string] $script:state.deploymentPassword

            @([regex]::Matches($written, [regex]::Escape($secret))).Count | Should -Be 2
        }

        It 'writes a document that still parses as XML with a minted password' {
            # New-HDTDeploymentPassword's alphabet excludes the five XML-breaking
            # characters on purpose; this is the regression guard on that.
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            { [xml] $script:fileSystem.ReadAllText($script:pantherPath) } | Should -Not -Throw
        }

        It 'tolerates a run with no state document' {
            $context = & $script:newContextFor $null $null

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            $script:fileSystem.ReadAllText($script:pantherPath) | Should -Not -BeLike '*%HDTAdminPassword%*'
        }

        It 'never writes the password to the master log' {
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $secret = [string] $script:state.deploymentPassword

            $script:fileSystem.ReadAllText('X:\HDT\Logs\HDT.jsonl') | Should -Not -BeLike ('*{0}*' -f $secret)
            $script:fileSystem.ReadAllText('X:\HDT\Logs\HDT.log') | Should -Not -BeLike ('*{0}*' -f $secret)
        }

        It 'never writes the password to the step log' {
            $script:context.SetStep(4, 'Apply Unattend', 'ApplyUnattend', 'X:\HDT\Logs\Steps\004-Apply-Unattend.log')

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $secret = [string] $script:state.deploymentPassword
            $stepLog = $script:fileSystem.ReadAllText('X:\HDT\Logs\Steps\004-Apply-Unattend.log')

            $stepLog | Should -Not -BeLike ('*{0}*' -f $secret)
        }

        It 'never writes the document body to the log at any level' {
            # Debug included: the whole document carries the secret twice.
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $raw = $script:fileSystem.ReadAllText('X:\HDT\Logs\HDT.jsonl')

            $raw | Should -Not -BeLike '*AdministratorPassword*'
            $raw | Should -Not -BeLike '*<unattend*'
        }

        It 'logs the path and the byte count' {
            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $raw = $script:fileSystem.ReadAllText('X:\HDT\Logs\HDT.log')

            $raw | Should -BeLike '*W:\Windows\Panther\unattend.xml*'
            $raw | Should -BeLike '*byte*'
        }
    }

    Context 'the step contract' {

        It 'returns Failed rather than throwing for a step with no properties' {
            $result = Invoke-HDTApplyUnattendStep -Step (& $script:newStep $null) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Not -BeNullOrEmpty
        }

        It 'does not rethrow when the write fails' {
            $script:fileSystem.SeedWriteFailure($script:pantherPath, 'The media is write protected.')

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*write protected*'
        }
    }
}

Describe 'Get-HDTApplyUnattendStepDescription' {

    It 'names the template it will stage' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['template'] = 'unattend.xml'

        $step = [pscustomobject] @{ Index = 4; Name = 'Apply Unattend'; Type = 'ApplyUnattend'; Property = $bag }

        Get-HDTApplyUnattendStepDescription -Step $step | Should -BeLike '*unattend.xml*'
    }

    It 'describes a step that names nothing' {
        $step = [pscustomobject] @{ Index = 4; Name = 'Apply Unattend'; Type = 'ApplyUnattend'
            Property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        Get-HDTApplyUnattendStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}
