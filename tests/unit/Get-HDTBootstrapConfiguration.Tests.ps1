# bootstrap.json - the ONE file in the boot image that tells the engine where its
# content is and which provider reaches it.
#
# 05-04's Update-HDTBootImage writes it to X:\HDT\bootstrap.json; this is the
# reader. Everything about it is read on a machine with NO OPERATOR AT THE
# KEYBOARD, which is why a malformed document must produce a sentence naming the
# file rather than a raw ConvertFrom-Json exception: that sentence is the last
# thing anybody will ever see about the run.
#
# The fixtures are AUTHORED, not captured, and tests/fixtures/README.md says so -
# nothing has ever written one of these files, because the writer is 05-04.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/bootstrap'
    $script:bootstrapPath = 'X:\HDT\bootstrap.json'

    # The fixture password, in clear, so a test can prove the credential the
    # reader hands back is the one the boot image carries.
    $script:fixturePassword = 'Fixture-P@ssw0rd-01'
    $script:fixtureProtected = 'JMuHPVvrPBjfPgboyM1UjETROKiE1tnYozPAtYSsozJPsnalvz9Yulkm7aJtG/GC'

    # A fake filesystem holding one fixture at X:\HDT\bootstrap.json.
    $script:seed = {
        param([string] $Name)

        $text = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath $Name) -Raw

        return (New-HDTFakeFileSystem -File @{ $script:bootstrapPath = $text })
    }

    # An arbitrary document, written as JSON, for the rules no fixture covers.
    $script:seedObject = {
        param([hashtable] $Document)

        $text = ConvertTo-Json -InputObject $Document -Depth 5

        return (New-HDTFakeFileSystem -File @{ $script:bootstrapPath = $text })
    }

    $script:errorOf = {
        param([scriptblock] $Action)

        $record = $null
        try { & $Action } catch { $record = $_ }

        return $record
    }
}

Describe 'Get-HDTBootstrapConfiguration' {

    Context 'the document 05-04 will write' {

        It 'accepts the fixture 05-04 will write' {
            $fs = & $script:seed 'valid-smb.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.SchemaVersion | Should -Be 1
            $bootstrap.WorkspaceId | Should -BeExactly 'HDT-LAB'
            $bootstrap.Provider | Should -BeExactly 'Smb'
            $bootstrap.DeployRoot | Should -BeExactly '\\HDTSRV01\HdtShare'
            $bootstrap.ContentMarker | Should -BeExactly 'rules.yaml'
            $bootstrap.SequenceId | Should -BeExactly 'STD-CLIENT'
            $bootstrap.PromptForCredential | Should -BeFalse
            $bootstrap.LogLevel | Should -BeExactly 'Info'
            $bootstrap.UserName | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
            $bootstrap.HasCredential | Should -BeTrue
            $bootstrap.BuildId | Should -BeExactly 'b3f1c0a2-8d64-4f11-9c2e-0a5d7e1f4b90'
            $bootstrap.BuiltUtc | Should -BeExactly '2026-08-13T09:14:22Z'
            $bootstrap.Path | Should -BeExactly $script:bootstrapPath
        }

        It 'reads through the injected filesystem' {
            $fs = & $script:seed 'valid-smb.json'

            $null = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $fs.GetOperationName() | Should -Be @('TestPath', 'ReadAllText')
        }

        It 'builds the credential on demand' {
            $fs = & $script:seed 'valid-smb.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs
            $credential = $bootstrap.GetCredential()

            $credential | Should -BeOfType ([System.Management.Automation.PSCredential])
            $credential.UserName | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
            $credential.GetNetworkCredential().Password | Should -BeExactly $script:fixturePassword
        }

        It 'does not return the protected secret in a property that gets logged' {
            # THE RESULT IS LOGGED. A run that wrote its own bootstrap object into
            # RESULT.json or a log record would put the share password on the
            # share, which is exactly what DESIGN 6.3's least-privilege account
            # exists to bound rather than to excuse.
            $fs = & $script:seed 'valid-smb.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            [string] $bootstrap | Should -Not -BeLike ('*{0}*' -f $script:fixtureProtected)
            [string] $bootstrap | Should -Not -BeLike ('*{0}*' -f $script:fixturePassword)

            (ConvertTo-Json -InputObject $bootstrap -Depth 4) |
                Should -Not -BeLike ('*{0}*' -f $script:fixtureProtected)
            (ConvertTo-Json -InputObject $bootstrap -Depth 4) |
                Should -Not -BeLike ('*{0}*' -f $script:fixturePassword)
        }

        It 'returns no credential when the document carries none' {
            $fs = & $script:seed 'valid-local.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.HasCredential | Should -BeFalse
            $bootstrap.UserName | Should -BeExactly ''
            $bootstrap.GetCredential() | Should -BeNullOrEmpty
        }
    }

    Context 'the defaults' {

        It 'defaults contentMarker to rules.yaml' {
            # DESIGN 3.3's file, which sits at the root of every workspace. It is
            # what identifies a workspace root when the volume is DISCOVERED
            # rather than configured.
            $fs = & $script:seed 'valid-local.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.ContentMarker | Should -BeExactly 'rules.yaml'
        }

        It 'applies Info as the default log level' {
            $fs = & $script:seed 'valid-local.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.LogLevel | Should -BeExactly 'Info'
        }

        It 'honours an explicit log level' {
            $fs = & $script:seed 'valid-local-volume-relative.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.LogLevel | Should -BeExactly 'Debug'
        }

        It 'returns PromptForCredential false when the key is absent' {
            $fs = & $script:seedObject @{
                schemaVersion = 1
                provider      = 'Local'
                deployRoot    = 'D:\Share'
            }

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.PromptForCredential | Should -BeFalse
        }

        It 'accepts an empty sequenceId' {
            # DESIGN 3's answer to "which task sequence does this machine get" is
            # the rules, so an image that names none is not an image that is
            # broken.
            $fs = & $script:seed 'valid-local.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.SequenceId | Should -BeExactly ''
        }

        It 'defaults schemaVersion to 1 when the key is absent' {
            $fs = & $script:seedObject @{
                provider   = 'Local'
                deployRoot = 'D:\Share'
            }

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.SchemaVersion | Should -Be 1
        }
    }

    Context 'the deployRoot' {

        It 'accepts a rooted local deployRoot' {
            # What a build host uses. It is not an error for it to be absent at
            # boot either - Resolve-HDTDeployRoot falls back to the probe.
            $fs = & $script:seed 'valid-local.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.Provider | Should -BeExactly 'Local'
            $bootstrap.DeployRoot | Should -BeExactly 'D:\Share'
        }

        It 'accepts a volume-relative deployRoot for Local' {
            # THE FORM 05-04 WRITES INTO THE IMAGE THE E2E BOOTS. SPIKES S9.1:
            # WinPE gave the content disk C: and the RAM disk X:, so a letter
            # written at build time is a guess about a machine that has not
            # booted yet.
            $fs = & $script:seed 'valid-local-volume-relative.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.Provider | Should -BeExactly 'Local'
            $bootstrap.DeployRoot | Should -BeExactly '\Share'
        }

        It 'reads a boot image with no deployRoot, because a technician can supply one' {
            # THIS USED TO BE A REFUSAL, and the refusal was in the wrong place.
            # An image with no share is not a malformed document - it is an
            # image that has a question for whoever is standing in front of it.
            # Throwing here means the Welcome screen never opens, so the person
            # who could have typed the share never gets asked.
            #
            # The failure still happens if nobody answers: connecting to an
            # empty share fails, loudly, at connect time.
            $fs = & $script:seed 'valid-missing-deployroot.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            [string] $bootstrap.DeployRoot | Should -BeExactly ''
        }

        It 'still refuses a non-UNC deployRoot for Smb' {
            # Volume-relative is a LOCAL idea. It must not weaken the Smb rule:
            # an Smb provider with 'D:\Share' is a boot image that will map
            # nothing and say nothing useful about why.
            $fs = & $script:seedObject @{
                schemaVersion       = 1
                provider            = 'Smb'
                deployRoot          = 'D:\Share'
                promptForCredential = $true
            }

            $record = & $script:errorOf { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Smb*'
            $record.Exception.Message | Should -BeLike '*D:\Share*'
        }

        It 'refuses a volume-relative deployRoot for Smb' {
            $fs = & $script:seedObject @{
                schemaVersion       = 1
                provider            = 'Smb'
                deployRoot          = '\Share'
                promptForCredential = $true
            }

            $record = & $script:errorOf { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'the provider' {

        It 'refuses a provider outside Smb and Local' {
            $fs = & $script:seed 'invalid-unknown-provider.json'

            $record = & $script:errorOf { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:bootstrapPath)
            $record.Exception.Message | Should -BeLike '*Ftp*'
            $record.Exception.Message | Should -BeLike '*Smb*'
            $record.Exception.Message | Should -BeLike '*Local*'
        }

        It 'refuses a missing provider' {
            $fs = & $script:seedObject @{
                schemaVersion = 1
                deployRoot    = 'D:\Share'
            }

            $record = & $script:errorOf { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'the credential' {

        It 'refuses an Smb image built with neither a credential nor a prompt' {
            # The most likely reason a PXE-booted machine sits there doing
            # nothing, and it is decidable at build time.
            $fs = & $script:seedObject @{
                schemaVersion       = 1
                provider            = 'Smb'
                deployRoot          = '\\HDTSRV01\HdtShare'
                promptForCredential = $false
            }

            $record = & $script:errorOf { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*credential*'
            $record.Exception.Message | Should -BeLike '*-PromptForCredential*'
        }

        It 'accepts an absent credential when promptForCredential is true' {
            $fs = & $script:seed 'valid-prompt.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.PromptForCredential | Should -BeTrue
            $bootstrap.HasCredential | Should -BeFalse
        }

        It 'does not require a credential for Local' {
            $fs = & $script:seed 'valid-local.json'

            { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs } | Should -Not -Throw
        }
    }

    Context 'the skip block' {

        # MDT's Bootstrap.ini carries SkipBDDWelcome and CustomSettings.ini
        # carries every other Skip*, and the reason is structural rather than
        # historical: the Welcome screen runs BEFORE the share is reachable, so
        # a rule about it cannot live on the share. HDT has the same split, and
        # this is the in-image half of it (.planning/WPF-FIRST.md, W2).
        #
        # ABSENT IS NOT false. Every image built before the skip block existed
        # has no skip block, and Get-HDTWizardSkip's defaults are what turn that
        # into the unattended path - so the reader has to hand back "the image
        # said nothing" rather than quietly saying "no".

        It 'reads all four rules when the image states them' {
            $fs = & $script:seedObject @{
                schemaVersion = 1
                provider      = 'Local'
                deployRoot    = '\Share'
                skip          = @{ welcome = $true; staticIp = $true; deployRoot = $false; credential = $true }
            }

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            [bool] $bootstrap.Skip.Welcome | Should -BeTrue
            [bool] $bootstrap.Skip.StaticIp | Should -BeTrue
            [bool] $bootstrap.Skip.DeployRoot | Should -BeFalse
            [bool] $bootstrap.Skip.Credential | Should -BeTrue
        }

        It 'reports a rule the image did not state as null, not as false' {
            $fs = & $script:seedObject @{
                schemaVersion = 1
                provider      = 'Local'
                deployRoot    = '\Share'
                skip          = @{ welcome = $false }
            }

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            [bool] $bootstrap.Skip.Welcome | Should -BeFalse
            $bootstrap.Skip.StaticIp | Should -BeNullOrEmpty -Because (
                'an unstated rule is a different fact from a rule set to false')
        }

        It 'still carries a Skip object when the image has no skip block at all' {
            # THE SHAPE EVERY EXISTING IMAGE HAS. A missing Skip property would
            # make Get-HDTWizardSkip throw under StrictMode on the one machine
            # that has no operator.
            $fs = & $script:seed 'valid-local.json'

            $bootstrap = Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs

            $bootstrap.Skip | Should -Not -BeNullOrEmpty
            $bootstrap.Skip.Welcome | Should -BeNullOrEmpty
        }

        It 'ignores a key nobody knows, rather than refusing to boot over it' {
            # A newer builder writing a fifth rule must not stop an older engine
            # from deploying. It reads the four it knows.
            $fs = & $script:seedObject @{
                schemaVersion = 1
                provider      = 'Local'
                deployRoot    = '\Share'
                skip          = @{ welcome = $true; summary = $true }
            }

            { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs } | Should -Not -Throw
            [bool] (Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs).Skip.Welcome |
                Should -BeTrue
        }
    }

    Context 'when the file cannot be read' {

        It 'names the file for a truncated document' {
            # NOT A RAW ConvertFrom-Json EXCEPTION. Nobody is watching when this
            # fails, and "Invalid JSON primitive" names nothing.
            $fs = & $script:seed 'unparseable-truncated.json'

            $record = & $script:errorOf { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:bootstrapPath)
        }

        It 'names the file when it is not there at all' {
            $fs = New-HDTFakeFileSystem

            $record = & $script:errorOf { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:bootstrapPath)
        }

        It 'names the file for an empty document' {
            $fs = New-HDTFakeFileSystem -File @{ $script:bootstrapPath = '' }

            $record = & $script:errorOf { Get-HDTBootstrapConfiguration -Path $script:bootstrapPath -FileSystem $fs }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'the command itself' {

        It 'is exported with comment-based help' {
            # Get-Help falls back to a fuzzy search, so the NAME is asserted
            # first (tests/helpers/README.md section 12).
            $help = Get-Help -Name Get-HDTBootstrapConfiguration -ErrorAction Stop

            $help.Name | Should -BeExactly 'Get-HDTBootstrapConfiguration'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
