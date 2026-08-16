# Test-HDTApplicationDetection answers one question: is this application already
# installed? DESIGN 8 - "detection rules let the engine skip already-installed
# apps; MDT has no first-class detection, so reruns reinstall everything."
#
# NO RULE MEANS NOT DETECTED, WHICH MEANS INSTALL. That is not a degenerate case
# to tidy away: it is the documented behaviour for an application that declares
# no detect: block, and the whole reason the roadmap made detection optional. The
# engine never infers a rule, because a guessed rule reporting an app installed
# when it is not silently skips work the sequence asked for.
#
# A DETECTION SCRIPT THAT THROWS IS "NOT INSTALLED", NEVER A FAILED DEPLOYMENT.
# The question it was asked is "is this here?", and a script that cannot answer
# has not discovered a reason to scrap the build - it has failed to find the
# application, which is the same outcome as not finding it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $script:wowUninstallKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $script:productCode = '{23170F69-40C1-2702-2409-000001000000}'
    $script:agentPath = 'C:\Program Files\Contoso\Agent\agent.exe'

    function New-HDTTestDetect {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory detection rule fixture; it changes no state.')]
        param([hashtable] $Property)

        return [pscustomobject] $Property
    }
}

Describe 'Test-HDTApplicationDetection' {

    Context 'an application that declares no rule' {

        It 'reports not installed for $null, so the step installs it' {
            Test-HDTApplicationDetection -Detect $null | Should -BeFalse
        }

        It 'asks no service anything' {
            # The check is free for the applications that opted out of it.
            $fileSystem = New-HDTFakeFileSystem
            $registry = New-HDTFakeRegistryService

            $null = Test-HDTApplicationDetection -Detect $null -FileSystem $fileSystem -Registry $registry

            @($fileSystem.GetOperationName()).Count | Should -Be 0
            @($registry.GetOperationName()).Count | Should -Be 0
        }
    }

    Context 'msiProduct' {

        BeforeEach {
            $script:detect = New-HDTTestDetect -Property @{
                Type        = 'msiProduct'
                ProductCode = $script:productCode
            }
        }

        It 'reports installed when the uninstall key is present' {
            $registry = New-HDTFakeRegistryService -Value @{
                ('{0}\{1}' -f $script:uninstallKey, $script:productCode) = @{ DisplayName = '7-Zip 24.09 x64' }
            }

            Test-HDTApplicationDetection -Detect $script:detect -Registry $registry | Should -BeTrue
        }

        It 'reports installed for a 32-bit product on a 64-bit machine' {
            # A 32-bit MSI registers under WOW6432Node, and an engine that looked
            # only at the native view would reinstall it on every deployment.
            $registry = New-HDTFakeRegistryService -Value @{
                ('{0}\{1}' -f $script:wowUninstallKey, $script:productCode) = @{ DisplayName = '7-Zip 24.09 x86' }
            }

            Test-HDTApplicationDetection -Detect $script:detect -Registry $registry | Should -BeTrue
        }

        It 'reports not installed when neither view holds the product code' {
            $registry = New-HDTFakeRegistryService -Value @{
                ('{0}\{{OTHER-PRODUCT}}' -f $script:uninstallKey) = @{ DisplayName = 'Something else' }
            }

            Test-HDTApplicationDetection -Detect $script:detect -Registry $registry | Should -BeFalse
        }

        It 'looks in the native view before the WOW6432Node one' {
            $registry = New-HDTFakeRegistryService

            $null = Test-HDTApplicationDetection -Detect $script:detect -Registry $registry

            @($registry.Operations)[0].Arguments[0] |
                Should -BeExactly ('{0}\{1}' -f $script:uninstallKey, $script:productCode)
        }
    }

    Context 'file' {

        It 'reports installed when the file is there and no version is required' {
            $fileSystem = New-HDTFakeFileSystem -File @{ $script:agentPath = 'binary' }
            $detect = New-HDTTestDetect -Property @{ Type = 'file'; Path = $script:agentPath; Version = '' }

            Test-HDTApplicationDetection -Detect $detect -FileSystem $fileSystem | Should -BeTrue
        }

        It 'reports not installed when the file is absent' {
            $fileSystem = New-HDTFakeFileSystem
            $detect = New-HDTTestDetect -Property @{ Type = 'file'; Path = $script:agentPath; Version = '' }

            Test-HDTApplicationDetection -Detect $detect -FileSystem $fileSystem | Should -BeFalse
        }

        It 'reports installed when the file version meets the floor' {
            $fileSystem = New-HDTFakeFileSystem -File @{ $script:agentPath = 'binary' } `
                -Version @{ $script:agentPath = '4.2.0.0' }
            $detect = New-HDTTestDetect -Property @{ Type = 'file'; Path = $script:agentPath; Version = '4.2.0.0' }

            Test-HDTApplicationDetection -Detect $detect -FileSystem $fileSystem | Should -BeTrue
        }

        It 'reports installed when the file version exceeds the floor' {
            $fileSystem = New-HDTFakeFileSystem -File @{ $script:agentPath = 'binary' } `
                -Version @{ $script:agentPath = '5.0.1.3' }
            $detect = New-HDTTestDetect -Property @{ Type = 'file'; Path = $script:agentPath; Version = '4.2.0.0' }

            Test-HDTApplicationDetection -Detect $detect -FileSystem $fileSystem | Should -BeTrue
        }

        It 'reports NOT installed for a stale build below the floor' {
            # THE WHOLE POINT OF THE VERSION HALF. The file is there, so a path
            # test alone would report installed and the sequence would skip the
            # upgrade it exists to perform.
            $fileSystem = New-HDTFakeFileSystem -File @{ $script:agentPath = 'binary' } `
                -Version @{ $script:agentPath = '4.1.9.0' }
            $detect = New-HDTTestDetect -Property @{ Type = 'file'; Path = $script:agentPath; Version = '4.2.0.0' }

            Test-HDTApplicationDetection -Detect $detect -FileSystem $fileSystem | Should -BeFalse
        }

        It 'does not read the version when the rule states none' {
            $fileSystem = New-HDTFakeFileSystem -File @{ $script:agentPath = 'binary' }
            $detect = New-HDTTestDetect -Property @{ Type = 'file'; Path = $script:agentPath; Version = '' }

            $null = Test-HDTApplicationDetection -Detect $detect -FileSystem $fileSystem

            $fileSystem.GetOperationName() | Should -Not -Contain 'GetVersion'
        }

        It 'expands a variable token in the path' {
            $fileSystem = New-HDTFakeFileSystem -File @{ $script:agentPath = 'binary' }
            $detect = New-HDTTestDetect -Property @{
                Type    = 'file'
                Path    = '%ProgramFiles%\Contoso\Agent\agent.exe'
                Version = ''
            }

            $variable = @{ ProgramFiles = 'C:\Program Files' }

            Test-HDTApplicationDetection -Detect $detect -FileSystem $fileSystem -Variable $variable |
                Should -BeTrue
        }
    }

    Context 'registry' {

        It 'reports installed when the key exists and the rule names no value' {
            $registry = New-HDTFakeRegistryService -Value @{ 'HKLM:\SOFTWARE\Contoso\Shell' = @{} }
            $detect = New-HDTTestDetect -Property @{
                Type  = 'registry'
                Key   = 'HKLM:\SOFTWARE\Contoso\Shell'
                Value = ''
                Data  = ''
            }

            Test-HDTApplicationDetection -Detect $detect -Registry $registry | Should -BeTrue
        }

        It 'reports not installed when the key is absent' {
            $registry = New-HDTFakeRegistryService
            $detect = New-HDTTestDetect -Property @{
                Type  = 'registry'
                Key   = 'HKLM:\SOFTWARE\Contoso\Shell'
                Value = ''
                Data  = ''
            }

            Test-HDTApplicationDetection -Detect $detect -Registry $registry | Should -BeFalse
        }

        It 'reports installed when the named value is present' {
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Contoso\Vpn' = @{ Version = '9.1' }
            }
            $detect = New-HDTTestDetect -Property @{
                Type  = 'registry'
                Key   = 'HKLM:\SOFTWARE\Contoso\Vpn'
                Value = 'Version'
                Data  = ''
            }

            Test-HDTApplicationDetection -Detect $detect -Registry $registry | Should -BeTrue
        }

        It 'reports not installed when the named value is missing from a key that exists' {
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Contoso\Vpn' = @{ Other = 'x' }
            }
            $detect = New-HDTTestDetect -Property @{
                Type  = 'registry'
                Key   = 'HKLM:\SOFTWARE\Contoso\Vpn'
                Value = 'Version'
                Data  = ''
            }

            Test-HDTApplicationDetection -Detect $detect -Registry $registry | Should -BeFalse
        }

        It 'reports installed when the data matches' {
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Contoso\Vpn' = @{ Version = '9.1' }
            }
            $detect = New-HDTTestDetect -Property @{
                Type  = 'registry'
                Key   = 'HKLM:\SOFTWARE\Contoso\Vpn'
                Value = 'Version'
                Data  = '9.1'
            }

            Test-HDTApplicationDetection -Detect $detect -Registry $registry | Should -BeTrue
        }

        It 'reports not installed when the data differs' {
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Contoso\Vpn' = @{ Version = '8.4' }
            }
            $detect = New-HDTTestDetect -Property @{
                Type  = 'registry'
                Key   = 'HKLM:\SOFTWARE\Contoso\Vpn'
                Value = 'Version'
                Data  = '9.1'
            }

            Test-HDTApplicationDetection -Detect $detect -Registry $registry | Should -BeFalse
        }
    }

    Context 'script' {

        It 'reports installed when the script returns something truthy' {
            $invoker = New-HDTFakeScriptInvoker -Result @{ 'Detect-ContosoLob.ps1' = $true }
            $detect = New-HDTTestDetect -Property @{ Type = 'script'; Path = 'Detect-ContosoLob.ps1' }

            Test-HDTApplicationDetection -Detect $detect -ScriptInvoker $invoker | Should -BeTrue
        }

        It 'reports not installed when the script returns something falsy' {
            $invoker = New-HDTFakeScriptInvoker -Result @{ 'Detect-ContosoLob.ps1' = $false }
            $detect = New-HDTTestDetect -Property @{ Type = 'script'; Path = 'Detect-ContosoLob.ps1' }

            Test-HDTApplicationDetection -Detect $detect -ScriptInvoker $invoker | Should -BeFalse
        }

        It 'reports not installed when the script throws, rather than failing the deployment' {
            # The script was asked "is this here?" and could not answer. That is
            # not a reason to scrap an otherwise good build.
            # An unseeded path is one the invoker cannot run - the same shape a
            # detection script that is missing from Scripts\ has in production.
            $invoker = New-HDTFakeScriptInvoker -Result @{ 'Detect-Something-Else.ps1' = $true }
            $detect = New-HDTTestDetect -Property @{ Type = 'script'; Path = 'Detect-ContosoLob.ps1' }

            Test-HDTApplicationDetection -Detect $detect -ScriptInvoker $invoker | Should -BeFalse
        }

        It 'hands the variables to the script' {
            $invoker = New-HDTFakeScriptInvoker -Result @{ 'Detect-ContosoLob.ps1' = $true }
            $detect = New-HDTTestDetect -Property @{ Type = 'script'; Path = 'Detect-ContosoLob.ps1' }

            $null = Test-HDTApplicationDetection -Detect $detect -ScriptInvoker $invoker `
                -Variable @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' }

            @($invoker.Operations)[0].Arguments[1].HDTSerialNumber | Should -BeExactly 'FIXTURE-SERIAL-0001'
        }
    }

    Context 'what it refuses' {

        It 'names the service a rule needs when it was not supplied' {
            # A rule the caller cannot answer is a wiring mistake in the engine,
            # not an application that is absent - so it throws rather than
            # quietly reporting "not installed" and reinstalling every time.
            $detect = New-HDTTestDetect -Property @{
                Type        = 'msiProduct'
                ProductCode = $script:productCode
            }

            { Test-HDTApplicationDetection -Detect $detect } | Should -Throw -ExpectedMessage '*Registry*'
        }

        It 'refuses a detection type it cannot run' {
            $detect = New-HDTTestDetect -Property @{ Type = 'wmi' }

            { Test-HDTApplicationDetection -Detect $detect } | Should -Throw -ExpectedMessage '*wmi*'
        }
    }
}
