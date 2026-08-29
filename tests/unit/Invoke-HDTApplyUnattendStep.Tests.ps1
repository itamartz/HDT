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

        # AN IMAGE SERVICE, BECAUSE A REAL RUN ALWAYS HAS ONE. Start-HDTDeployment
        # builds the catalog with -Image, and the step needs it to apply the
        # staged document to the offline image - which is what runs the
        # offlineServicing pass the shipped template declares.
        $script:image = New-HDTFakeImageService

        $script:newContextFor = {
            param([System.Collections.IDictionary] $Variable, [object] $State)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Image $script:image

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTComputerName'] = 'HDT-M3-01'
            $live['HDTTaskSequenceID'] = $script:sequenceId

            # THE ONE PASSWORD, WHICH A REAL SHARE ALWAYS RESOLVES. The fallback
            # rule of rules.yaml carries it (DESIGN 4.5.2, MDT's [Default]), so a
            # deployment reaching this step without one does not exist - and the
            # step now refuses rather than minting a secret nobody would know.
            # A fixture that wants the refusal passes an empty string.
            $live['HDTAdminPassword'] = 'Fixture-P@ssw0rd'

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

        It 'refuses a computer name longer than 15 characters' {
            # FOUND BY DEPLOYING A REAL MACHINE (04-04). The sample rules.yaml's
            # fallback sets HDTComputerName to 'PC-%HDTSerialNumber%', and a
            # Hyper-V VM's serial is 32 characters - so the unattend carried a
            # 35-character ComputerName. WINDOWS SETUP SILENTLY IGNORED IT and
            # named the machine WIN-N91191NN153.
            #
            # That is the worst shape a defect can take: the deployment
            # succeeded, every step reported Completed, and the machine came up
            # with a name nobody chose and no log mentioned. A 15-character
            # NetBIOS limit is not an edge case - it is every machine whose name
            # comes from a serial number.
            $context = & $script:newContextFor ([ordered] @{ HDTComputerName = 'PC-1884-9397-3639-6194-7223-8141-25' }) $script:state

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Data['errorId'] | Should -BeExactly 'HDTConfigurationError'
            $result.Message | Should -BeLike '*PC-1884-9397-3639-6194-7223-8141-25*'
            $result.Message | Should -BeLike '*15*'
        }

        It 'writes nothing when it refuses the name' {
            $context = & $script:newContextFor ([ordered] @{ HDTComputerName = 'PC-1884-9397-3639-6194-7223-8141-25' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            $script:fileSystem.TestPath($script:pantherPath) | Should -BeFalse
        }

        It 'refuses a computer name with a character Windows will not take' {
            foreach ($name in @('HDT M3 01', 'HDT_M3*01', 'HDT.M3.01')) {
                $context = & $script:newContextFor ([ordered] @{ HDTComputerName = $name }) $script:state

                $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

                $result.Status | Should -BeExactly 'Failed' -Because ("'{0}' is not a legal computer name" -f $name)
            }
        }

        It 'accepts a legal 15 character name' {
            $context = & $script:newContextFor ([ordered] @{ HDTComputerName = 'HDT-M3-01-12345' }) $script:state

            (Invoke-HDTApplyUnattendStep -Step $script:step -Context $context).Status | Should -BeExactly 'Completed'
        }

        It 'says nothing about a computer name the document never asked for' {
            # A template with no %HDTComputerName% token is not the place to
            # enforce a naming rule.
            $script:fileSystem.SeedFile($script:templatePath, '<?xml version="1.0"?><unattend />')

            $context = & $script:newContextFor ([ordered] @{ HDTComputerName = 'PC-1884-9397-3639-6194-7223-8141-25' }) $script:state

            (Invoke-HDTApplyUnattendStep -Step $script:step -Context $context).Status | Should -BeExactly 'Completed'
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

    Context 'characters a technician can type' {

        # AN ANSWER FILE IS XML, AND A PASSWORD IS NOT.
        #
        # Substitution used to drop the resolved value into the document with no
        # escaping at all, and that was safe for exactly as long as every
        # password was MINTED. New-HDTDeploymentPassword's alphabet excluded
        # < > & " ' and per cent signs on purpose, so a minted secret went in
        # without escaping - and the comment recording that guarantee was
        # deleted along with the command itself.
        #
        # NOTHING MINTS ONE ANY MORE. DESIGN 4.5.2 settled it: "the
        # administrator sets the password; HDT does not invent one." So every
        # password in this document is now a string a human typed into the
        # wizard or wrote into rules.yaml, over which HDT has no alphabet at
        # all - and 'Pa&ss' produced an answer file Windows Setup could not
        # parse, twice over, because the secret appears under UserAccounts AND
        # inside AutoLogon.
        #
        # THE FIX IS AT SUBSTITUTION, NOT IN A PASSWORD RULE. Escaping protects
        # every value the document ever carries - an organisation named
        # 'Smith & Sons' as much as a password - and cannot be forgotten by
        # whoever adds the next token. Refusing legal Windows passwords at a
        # bench would be the worse trade.

        BeforeEach {
            $script:hostileSecret = 'a&b<c>d"e' + "'" + 'f'

            $script:readUnattendValue = {
                param([string] $XPath)

                $written = $script:fileSystem.ReadAllText($script:pantherPath)

                $doc = New-Object -TypeName System.Xml.XmlDocument
                $doc.LoadXml($written)

                $ns = New-Object -TypeName System.Xml.XmlNamespaceManager -ArgumentList $doc.NameTable
                $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')

                return @(@($doc.SelectNodes($XPath, $ns)) | ForEach-Object { $_.InnerText })
            }
        }

        It 'stages a document that still parses when the password carries XML metacharacters' {
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = $script:hostileSecret }) $script:state

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            { [xml] $script:fileSystem.ReadAllText($script:pantherPath) } | Should -Not -Throw
        }

        It 'round-trips those characters to exactly what was typed, in both places Setup reads' {
            # PARSING IS NOT ENOUGH. A document that parses because the value was
            # mangled deploys a machine whose password nobody can type.
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = $script:hostileSecret }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            $account = @(& $script:readUnattendValue '//u:UserAccounts/u:AdministratorPassword/u:Value')
            $autoLogon = @(& $script:readUnattendValue '//u:AutoLogon/u:Password/u:Value')

            @($account).Count | Should -Be 1
            @($autoLogon).Count | Should -Be 1
            $account[0] | Should -BeExactly $script:hostileSecret
            $autoLogon[0] | Should -BeExactly $script:hostileSecret
        }

        It 'escapes a value once and not twice' {
            # AN AMPERSAND MUST REACH THE DISK AS ONE ENTITY. Escaping the
            # already-escaped text would write the entity for the entity, and
            # hand Windows a five-character password nobody typed.
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = 'a&b' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)

            $written | Should -BeLike '*a&amp;b*'
            $written | Should -Not -BeLike '*a&amp;amp;b*'
        }

        It 'leaves a per cent sign in a password as the character that was typed' {
            # THE TOKEN GRAMMAR IS PER CENT SIGNS, and a password is allowed to
            # contain them. Without handling, 'Pa%%w0rd' collapses to one per
            # cent sign, and a password naming a variable expands into somebody
            # else's value - or, naming its own, raises a cycle error halfway
            # through a deployment.
            $secret = 'Pa%%w0rd%HDTComputerName%'

            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = $secret }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            $account = @(& $script:readUnattendValue '//u:UserAccounts/u:AdministratorPassword/u:Value')

            $account[0] | Should -BeExactly $secret
        }

        It 'escapes every substituted value, not only the password' {
            # THE REASON THE FIX IS AT SUBSTITUTION. A token added tomorrow is
            # covered without anybody remembering to cover it.
            $script:fileSystem.SeedFile('Z:\Deploy\TaskSequences\DEMO-M3\org.xml',
                '<unattend><RegisteredOrganization>%HDTOrgName%</RegisteredOrganization></unattend>')

            $step = & $script:newStep ([ordered] @{ template = 'org.xml' })
            $context = & $script:newContextFor ([ordered] @{ HDTOrgName = 'Smith & Sons <Holdings>' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $step -Context $context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)

            { [xml] $written } | Should -Not -Throw
            ([xml] $written).unattend.RegisteredOrganization | Should -BeExactly 'Smith & Sons <Holdings>'
        }
    }

    Context 'the answer file this module actually ships' {

        # THE TEMPLATE New-HDTWorkspace SEEDS, not a fixture standing in for it.
        # Every other case in this file runs against the SPIKES S7 capture,
        # which is the right reference for BEHAVIOUR and the wrong one for
        # catching an element somebody added to the shipped file afterwards -
        # which is exactly what happened on 2026-08-28.

        BeforeEach {
            $script:shippedTemplate = Get-Content -Raw -LiteralPath (
                Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/unattend.xml')

            $script:fileSystem.SeedFile('Z:\Deploy\TaskSequences\DEMO-M3\shipped.xml', $script:shippedTemplate)
        }

        It 'parses as XML for a full set of wizard answers' {
            $answer = [ordered] @{
                HDTComputerName   = 'HDT-M3-01'
                HDTFullName       = 'Smith & Sons'
                HDTOrgName        = 'Smith & Sons <Holdings>'
                HDTProductKey     = ''
                HDTTimeZone       = 'GMT Standard Time'
                HDTKeyboardLocale = '0409:00000409'
                HDTSystemLocale   = 'en-US'
                HDTUILanguage     = 'en-US'
                HDTUserLocale     = 'en-US'
                HDTAdminPassword  = 'a&b<c>d"e' + "'" + 'f'
            }

            $step = & $script:newStep ([ordered] @{ template = 'shipped.xml' })
            $context = & $script:newContextFor $answer $script:state

            $result = Invoke-HDTApplyUnattendStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            { [xml] $script:fileSystem.ReadAllText($script:pantherPath) } | Should -Not -Throw
        }

        It 'leaves no unexpanded token behind for a full set of wizard answers' {
            # A LEFTOVER TOKEN IS A MACHINE NAMED AFTER ONE. The ProductKey
            # element is REMOVED rather than left empty when no key is supplied,
            # so an absent key is not a leftover.
            $answer = [ordered] @{
                HDTComputerName   = 'HDT-M3-01'
                HDTFullName       = 'Fabrikam'
                HDTOrgName        = 'Fabrikam'
                HDTProductKey     = ''
                HDTTimeZone       = 'GMT Standard Time'
                HDTKeyboardLocale = '0409:00000409'
                HDTSystemLocale   = 'en-US'
                HDTUILanguage     = 'en-US'
                HDTUserLocale     = 'en-US'
                HDTAdminPassword  = 'Passw0rd-fixture!'
            }

            $step = & $script:newStep ([ordered] @{ template = 'shipped.xml' })
            $context = & $script:newContextFor $answer $script:state

            Invoke-HDTApplyUnattendStep -Step $step -Context $context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)

            @([regex]::Matches($written, '%[A-Za-z_][A-Za-z0-9_]*%')) | Should -BeNullOrEmpty
        }
    }

    Context 'the product key' {

        # THE ELEMENT CANNOT BE LEFT EMPTY AND CANNOT BE LEFT LITERAL. Windows
        # reads ProductKey in the specialize pass; an empty one fails the pass
        # and the literal '%HDTProductKey%' fails it too, so the only safe shape
        # for a machine nobody supplied a key for is NO ELEMENT AT ALL - which
        # is how every deployment behaved before the token existed, and how a
        # KMS or LTSC build has to keep behaving.

        BeforeEach {
            $script:keyedTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup">
      <ComputerName>%HDTComputerName%</ComputerName>
      <ProductKey>%HDTProductKey%</ProductKey>
    </component>
  </settings>
</unattend>
'@
        }

        It 'substitutes a key that was supplied' {
            $fs = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:keyedTemplate }
            $script:fileSystem = $fs
            $context = & $script:newContextFor ([ordered] @{ HDTProductKey = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' }) $script:state

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            [string] $fs.File[$script:pantherPath] | Should -BeLike '*<ProductKey>VK7JG-NPHTM-C97JM-9MPGT-3V66T</ProductKey>*'
        }

        It 'trims a key pasted with surrounding space' {
            $fs = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:keyedTemplate }
            $script:fileSystem = $fs
            $context = & $script:newContextFor ([ordered] @{ HDTProductKey = '  VK7JG-NPHTM-C97JM-9MPGT-3V66T  ' }) $script:state

            $null = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            [string] $fs.File[$script:pantherPath] | Should -BeLike '*<ProductKey>VK7JG-NPHTM-C97JM-9MPGT-3V66T</ProductKey>*'
        }

        It 'removes the element entirely when nothing supplied a key' {
            $fs = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:keyedTemplate }
            $script:fileSystem = $fs
            $context = & $script:newContextFor $null $script:state

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            [string] $fs.File[$script:pantherPath] | Should -Not -BeLike '*ProductKey*'
        }

        It 'removes the element when the key resolved to whitespace' {
            $fs = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:keyedTemplate }
            $script:fileSystem = $fs
            $context = & $script:newContextFor ([ordered] @{ HDTProductKey = '   ' }) $script:state

            $null = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            [string] $fs.File[$script:pantherPath] | Should -Not -BeLike '*ProductKey*'
        }

        It 'leaves the rest of the document alone when it removes the element' {
            $fs = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:keyedTemplate }
            $script:fileSystem = $fs
            $context = & $script:newContextFor $null $script:state

            $null = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            [string] $fs.File[$script:pantherPath] | Should -BeLike '*<ComputerName>HDT-M3-01</ComputerName>*'
        }

        It 'never removes a key an author hard-coded into the template' {
            # THE TRAP THIS AVOIDS. Stripping every ProductKey element would
            # delete the literal key of a template that carries one and never
            # mentions the variable - a sequence that worked, silently
            # deactivated. Only the element holding the UNRESOLVED TOKEN goes.
            $literal = $script:keyedTemplate -replace '%HDTProductKey%', 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
            $fs = New-HDTFakeFileSystem -File @{ $script:templatePath = $literal }
            $script:fileSystem = $fs
            $context = & $script:newContextFor $null $script:state

            $null = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            [string] $fs.File[$script:pantherPath] | Should -BeLike '*<ProductKey>W269N-WFGWX-YVC9B-4J6C9-T83GX</ProductKey>*'
        }

        It 'does not report the token as unresolved when it removed the element' {
            # The warning counts tokens nothing supplied. An element that was
            # deliberately removed is not an unsupplied token, and reporting it
            # would train a technician to ignore the line that matters.
            $fs = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:keyedTemplate }
            $script:fileSystem = $fs
            $context = & $script:newContextFor $null $script:state

            $null = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $record = @(Get-HDTLogRecord -FileSystem $fs -Path 'X:\HDT\Logs\HDT.jsonl')
            @($record | Where-Object { [string] $_.message -like '*HDTProductKey*' }).Count | Should -Be 0
        }

        It 'never writes the key to the log' {
            $fs = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:keyedTemplate }
            $script:fileSystem = $fs
            $context = & $script:newContextFor ([ordered] @{ HDTProductKey = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' }) $script:state

            $null = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            [string] $fs.File['X:\HDT\Logs\HDT.jsonl'] | Should -Not -BeLike '*VK7JG*'
        }
    }

    Context 'secrets' {

        It 'substitutes HDTAdminPassword for the token' {
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = 'Authored-01!' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            $script:fileSystem.ReadAllText($script:pantherPath) | Should -BeLike '*Authored-01!*'
        }

        It 'refuses when nothing supplies it, rather than inventing one' {
            # ONE PASSWORD, AND THE ADMINISTRATOR SET IT (DESIGN 4.5.2). This step
            # used to mint a random secret here, which deployed a machine nobody
            # could log into - the failure the design rejected randomisation over,
            # and the one that matters most when a deployment stops halfway.
            #
            # The alternative is worse still: leaving the token unresolved deploys
            # a machine whose Administrator password is the literal
            # '%HDTAdminPassword%', identical on every machine this share builds,
            # and it would ship green.
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = '' }) $script:state

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTAdminPassword*'
        }

        It 'names where to set it, because that is the whole fix' {
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = '' }) $script:state

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Message | Should -BeLike '*rules.yaml*'
        }

        It 'stages nothing when it refuses' {
            # A half-written answer file is worse than none: Setup would read it.
            $fresh = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:unattendXml }
            $catalog = New-HDTServiceCatalog -FileSystem $fresh -Clock $script:clock

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fresh -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTComputerName'] = 'HDT-M3-01'
            $live['HDTTaskSequenceID'] = $script:sequenceId
            $live['HDTAdminPassword'] = ''

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot $script:workspaceRoot -Variable $live -Service $catalog -Log $log

            [void] (Invoke-HDTApplyUnattendStep -Step $script:step -Context $context)

            $fresh.TestPath($script:pantherPath) | Should -BeFalse
        }

        It 'writes the same secret everywhere the document asks for it' {
            # The fixture carries %HDTAdminPassword% twice - Setup reads
            # UserAccounts and AutoLogon separately - and both must be the same
            # secret or the machine cannot log itself on.
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = 'Authored-01!' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            $written = $script:fileSystem.ReadAllText($script:pantherPath)

            @([regex]::Matches($written, [regex]::Escape('Authored-01!'))).Count | Should -Be 2
        }

        It 'writes a document that still parses as XML' {
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = 'Authored-01!' }) $script:state

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $context | Out-Null

            { [xml] $script:fileSystem.ReadAllText($script:pantherPath) } | Should -Not -Throw
        }

        It 'tolerates a run with no state document' {
            $context = & $script:newContextFor ([ordered] @{ HDTAdminPassword = 'Authored-01!' }) $null

            $result = Invoke-HDTApplyUnattendStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            $script:fileSystem.ReadAllText($script:pantherPath) | Should -Not -BeLike '*%HDTAdminPassword%*'
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
            $secret = 'Fixture-P@ssw0rd'

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

            $secret = 'Fixture-P@ssw0rd'

            $script:fileSystem.ReadAllText('X:\HDT\Logs\HDT.jsonl') | Should -Not -BeLike ('*{0}*' -f $secret)
            $script:fileSystem.ReadAllText('X:\HDT\Logs\HDT.log') | Should -Not -BeLike ('*{0}*' -f $secret)
        }

        It 'never writes the password to the step log' {
            $script:context.SetStep(4, 'Apply Unattend', 'ApplyUnattend', 'X:\HDT\Logs\Steps\004-Apply-Unattend.log')

            Invoke-HDTApplyUnattendStep -Step $script:step -Context $script:context | Out-Null

            $secret = 'Fixture-P@ssw0rd'
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

# STAGING AN ANSWER FILE IS HALF OF APPLYING ONE.
#
# The offlineServicing pass - which is where the driver path lives, and the only
# pass that installs drivers from a folder - is processed when the document is
# APPLIED TO AN OFFLINE IMAGE, and by nothing else. Setup reading Panther on
# first boot runs specialize and oobeSystem; it does not run offlineServicing.
#
# So a document that declares offlineServicing and is only staged is a document
# whose driver paths are decoration. Both authorities make the call:
#
#   MDT  LTIApply.wsf:1021-1043   dism.exe /Image:<vol>\ /Apply-Unattend:<panther> /ScratchDir:<scratch>
#   PSD  PSDConfigure.ps1:151     Use-WindowsUnattend -UnattendPath ... -Path "<vol>:\" -ScratchDirectory ...
#
# HDT made neither until this was written. These tests are the proof it does.

Describe 'Invoke-HDTApplyUnattendStep applies the document offline' {

    BeforeEach {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        # THE REAL SHIPPED TEMPLATE, not a hand-written stand-in. It is the
        # document that actually declares offlineServicing, so deleting that
        # declaration has to break this test too.
        $script:shippedUnattend = [System.IO.File]::ReadAllText(
            (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/unattend.xml'))

        # The S7 capture declares no offlineServicing pass at all - it is the
        # 'nothing to apply' case, and it is a real document rather than an
        # invented one.
        $script:capturedUnattend = [System.IO.File]::ReadAllText(
            (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/unattend/win11-client.xml'))

        $script:templatePath = 'Z:\Deploy\TaskSequences\DEMO-M3\unattend.xml'
        $script:pantherPath = 'W:\Windows\Panther\unattend.xml'

        $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:shippedUnattend }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 1, 0, 0, [System.DateTimeKind]::Utc))
        $script:image = New-HDTFakeImageService

        $script:newContext = {
            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Image $script:image

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTComputerName'] = 'HDT-M3-01'
            $live['HDTTaskSequenceID'] = 'DEMO-M3'
            $live['HDTAdminPassword'] = 'Fixture-P@ssw0rd'

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:applyStep = & $script:newStep ([ordered] @{ template = 'unattend.xml' })
    }

    It 'applies the staged document to the offline image' {
        $result = Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext)

        $result.Status | Should -BeExactly 'Completed'

        $applied = @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyUnattend' })

        # The citation stays in this comment and out of the -Because string:
        # NoMdtDependency.Contract scans string literals and skips comments,
        # which is the right way round - a name in a string can be something
        # this code actually reaches for, and a name in a comment cannot.
        # MDT LTIApply.wsf:1043 makes this exact call.
        @($applied).Count | Should -Be 1 -Because (
            'staging alone never runs offlineServicing, so the driver path in the shipped template ' +
            'would be decoration, and the deployment would install none of the drivers it staged.')

        # THE IMAGE ROOT IS THE OS VOLUME, and the document applied is the one
        # that was just staged - not the template back on the share. MDT copies
        # into Panther first and applies THAT, and its comment says why: the
        # \Drivers path in the answer file is relative to the image root.
        $applied[0].Arguments[0] | Should -BeExactly 'W:\'
        $applied[0].Arguments[1] | Should -BeExactly $script:pantherPath
    }

    It 'applies it only after it has been staged' {
        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        # DISM reads the file off the disk, so a call made before the write
        # would apply either a stale document or none at all.
        $script:fileSystem.TestPath($script:pantherPath) | Should -BeTrue

        $written = @($script:fileSystem.Operations |
                Where-Object { $_.Operation -eq 'WriteAllText' -and $_.Arguments[0] -eq $script:pantherPath })

        @($written).Count | Should -Be 1
    }

    It 'gives DISM a scratch directory off the RAM disk' {
        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        $applied = @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyUnattend' })

        # WinPE boots on an X: RAM disk with no room to expand a driver package,
        # which is why MDT and PSD both hand DISM a scratch folder on the local
        # disk rather than letting it default to TEMP.
        [string] $applied[0].Arguments[2] | Should -BeLike 'W:\*'
    }

    It 'reports a failed apply rather than swallowing it' {
        $script:image.SeedFailure('ApplyUnattend', 'Error: 0x800f081e')

        $result = Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext)

        # A DEPLOYMENT THAT CONTINUES HERE IS A MACHINE WITH NO DRIVERS and a
        # green log. The staging succeeded; the thing that installs from it did
        # not, and only the step knows that.
        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*0x800f081e*'
    }

    It 'reports what DISM says while the offlineServicing pass is running' {
        # THE STEP THAT LOOKED HUNG, AND THE RUN THAT PROVED IT WAS NOT.
        # LT-7FJ45S2, run-20260829-172208: step 7, Apply Windows Settings, sat
        # on the progress card for over three minutes with nothing changing. It
        # was working - that was the first image with the driver-ordering fix,
        # so dism was genuinely running offlineServicing over 133 .inf packages
        # instead of scanning an empty folder - but the step wrote nothing
        # between its start and its end, so the screen could not say so. Worse,
        # elapsed on that card is derived from the first and last record in the
        # log, so the clock stopped with it.
        #
        # THE MECHANISM IS ApplyImage'S, UNCHANGED. The adapter hands every line
        # dism prints to a callback; the callback decides which of them is a
        # percentage and writes step.progress. Nothing here is a second channel
        # (DESIGN 11.1) and nothing here is invented - it is the same shape the
        # apply step has had since the step bar was built.
        #
        # THE FIXTURE IS REAL DISM OUTPUT AND IT IS NOT THIS VERB'S. Applying an
        # unattend needs an offline Windows image to apply it TO, so the
        # transcript cannot be captured on a developer's machine without
        # deploying one first. dism-offline-servicing-output.txt is
        # /Online /Cleanup-Image /ScanHealth captured on this host: the same
        # servicing stack, the same meter, 4.9% to 100.0% over 116 seconds, one
        # repaint per pipeline object. What is under test here is the step's
        # THROTTLING and the parser, and neither cares which verb drew the bar.
        $line = [System.IO.File]::ReadAllLines(
            (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-offline-servicing-output.txt'))

        $script:image = New-HDTFakeImageService -UnattendOutput $line

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        $percent = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                ForEach-Object { [int] $_.data.percent })

        # MORE THAN ONE, AND IT ENDS AT A HUNDRED. Three minutes of silence
        # became a number that moves; the stride is asserted separately.
        @($percent).Count | Should -BeGreaterThan 1
        $percent[-1] | Should -Be 100
    }

    It 'reports every five points rather than every line the tool prints' {
        # dism repaints its meter about a hundred times. A record per repaint is
        # a hundred log writes and a hundred re-reads of the log by the display,
        # on a machine part-way through building a computer, to move a bar by
        # one pixel. Five is the granularity a bar on a wall is read at.
        $line = @([System.IO.File]::ReadAllLines(
                (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-offline-servicing-output.txt')))

        $script:image = New-HDTFakeImageService -UnattendOutput $line

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        $percent = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                ForEach-Object { [int] $_.data.percent })

        $meterCount = @($line | Where-Object { $_ -match '%' }).Count

        # BOUNDED, AND BOUNDED BY THE STRIDE RATHER THAN BY THE TOOL: far fewer
        # records than meter repaints, and never two at the same number.
        @($percent).Count | Should -BeLessThan $meterCount
        @($percent).Count | Should -BeLessOrEqual 21

        for ($i = 1; $i -lt @($percent).Count; $i++) {
            $percent[$i] | Should -BeGreaterThan $percent[$i - 1]
        }
    }

    It 'names the image root in the progress record' {
        $line = [System.IO.File]::ReadAllLines(
            (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-offline-servicing-output.txt'))

        $script:image = New-HDTFakeImageService -UnattendOutput $line

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        $record = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress')

        [string] $record[0].component | Should -BeExactly 'ApplyUnattend'
        [string] $record[0].data.imageRoot | Should -BeExactly 'W:\'
    }

    It 'writes nothing when the tool prints no meter at all' {
        # A dism build that prints only its banner, and the reason the parser is
        # asked rather than the line count: a bar driven by how chatty a tool is
        # would be a bar that lied.
        $script:image = New-HDTFakeImageService -UnattendOutput @(
            'Deployment Image Servicing and Management tool', 'Version: 10.0.26100.8521', '',
            'The operation completed successfully.')

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress') |
            Should -BeNullOrEmpty
    }

    It 'drives the progress display while the pass is still running' {
        # END TO END: the step logs, the display re-reads the log, and what
        # reaches the screen is what the log says.
        $display = New-HDTFakeProgressHost

        $line = [System.IO.File]::ReadAllLines(
            (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-offline-servicing-output.txt'))

        $script:image = New-HDTFakeImageService -UnattendOutput $line

        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
            -Image $script:image -Progress $display

        $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $live['HDTOSVolume'] = 'W'
        $live['HDTComputerName'] = 'HDT-M3-01'
        $live['HDTTaskSequenceID'] = 'DEMO-M3'
        $live['HDTAdminPassword'] = 'Fixture-P@ssw0rd'

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
            -Variable $live -Service $catalog -Log $log

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context $context | Out-Null

        @($display.Operations | Where-Object { $_ -eq 'Update' }).Count | Should -BeGreaterThan 1
    }

    It 'keeps the progress it made when the pass then fails' {
        # A pass that died at 60% died somewhere different from one that never
        # started, and the log is the only place a technician can tell them
        # apart afterwards.
        $line = @([System.IO.File]::ReadAllLines(
                (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-offline-servicing-output.txt')))

        $script:image = New-HDTFakeImageService -UnattendOutput $line[0..120]
        $script:image.SeedFailure('ApplyUnattend', 'Error: 0x800f081e')

        $result = Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext)

        $result.Status | Should -BeExactly 'Failed'

        @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress') |
            Should -Not -BeNullOrEmpty
    }

    It 'still applies the unattend with the same three arguments' {
        # The progress channel is an addition, not a change: what the step asks
        # the service to do is what it always asked.
        $line = [System.IO.File]::ReadAllLines(
            (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-offline-servicing-output.txt'))

        $script:image = New-HDTFakeImageService -UnattendOutput $line

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        $applied = @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyUnattend' })

        @($applied).Count | Should -Be 1
        @($applied[0].Arguments).Count | Should -Be 3
        [string] $applied[0].Arguments[0] | Should -BeExactly 'W:\'
    }

    It 'beats a heartbeat while dism says nothing at all' {
        # THE DEFECT THE METER ABOVE DID NOT CLOSE, AND THE RUN THAT PROVED IT.
        # LT-D5M1NN3 run-20260829-223623 was deployed from a boot image built
        # AFTER the meter was wired to this step. Step 7 emitted step.start at
        # seq 189 and its next record 153 seconds later. In that same run
        # ApplyImage emitted TWENTY step.progress records - so the wiring works
        # and the callback resolves; dism.exe simply prints no percentage for
        # /Apply-Unattend. A scraper cannot fix a tool that is silent.
        #
        # SO THE ADAPTER POLLS, AND THE POLL IS WHAT REPORTS. UnattendTick is
        # the fake's stand-in for the half-second slices a real polled dism
        # would have spent saying nothing.
        $script:clock = New-HDTFakeClock `
            -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc)) `
            -TickMillisecond 16000

        $script:image = New-HDTFakeImageService -UnattendTick 3

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        $beat = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                Where-Object { $null -ne $_.data.PSObject.Properties['heartbeat'] })

        @($beat).Count | Should -BeGreaterThan 0
        [string] $beat[0].component | Should -BeExactly 'ApplyUnattend'
    }

    It 'says how long it has been running rather than inventing a percentage' {
        # A NUMBER DERIVED FROM ELAPSED TIME WOULD BE A BAR THAT LIED, which is
        # the one thing worse than a bar that stops. What is genuinely known
        # here is that the pass is still running and for how long, so that is
        # what the record says - and it carries NO percent, so it cannot drag
        # the step bar backwards from wherever real progress left it.
        $script:clock = New-HDTFakeClock `
            -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc)) `
            -TickMillisecond 16000

        $script:image = New-HDTFakeImageService -UnattendTick 2

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        $beat = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                Where-Object { $null -ne $_.data.PSObject.Properties['heartbeat'] })

        $beat[0].data.PSObject.Properties['percent'] | Should -BeNullOrEmpty
        [int] $beat[0].data.elapsedSecond | Should -BeGreaterThan 0
        [string] $beat[0].message | Should -BeLike '*still running after*'
    }

    It 'writes no heartbeat for a pass that returns before the first poll' {
        # THE RATION, AND IT IS WHAT KEEPS EVERY OTHER TEST IN THIS FILE
        # UNCHANGED. A pass with nothing to service returns in well under half a
        # second; the adapter never ticks, so nothing is written. A heartbeat
        # that fired regardless would put a line in the log of every deployment
        # for a step that took no time at all.
        $script:image = New-HDTFakeImageService

        Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext) | Out-Null

        @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                Where-Object { $null -ne $_.data.PSObject.Properties['heartbeat'] }) |
            Should -BeNullOrEmpty
    }

    It 'does not apply a document that declares no offlineServicing pass' {
        $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:templatePath = $script:capturedUnattend }

        $result = Invoke-HDTApplyUnattendStep -Step $script:applyStep -Context (& $script:newContext)

        $result.Status | Should -BeExactly 'Completed'

        # NOTHING TO APPLY IS NOT A REASON TO OPEN A SERVICING SESSION. The S7
        # capture is specialize and oobeSystem only, and both of those are read
        # by Setup off Panther on first boot.
        @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyUnattend' }) |
            Should -BeNullOrEmpty
    }
}
