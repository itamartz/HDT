# The Smb IContentProvider - DESIGN 6's network transport, and DESIGN 6.3's
# refusals.
#
# THIS FILE IS WHERE "THE ENGINE REFUSES GUEST FALLBACK" IS EITHER TRUE OR A
# SENTENCE IN A DESIGN DOCUMENT. A PXE-booted machine carries the deployment
# account's password in its boot image; if the server hands back a guest session
# instead - because the account was disabled, the password rotated, or somebody
# turned on insecure guest logons - then every file the deployment reads came
# from a share it did not authenticate to. HDT stops instead, names the server,
# and tears the mapping down.
#
# Every decision here is provable against New-HDTFakeSmbService, on a machine
# with no server, no domain account and nothing mapped. The real SmbShare
# mechanism is proven host-to-host in
# tests/integration/SmbContentProvider.Integration.Tests.ps1 - and PROJECT.md
# rule 2 plus SPIKES S6 mean NO VM IN THIS PHASE DEPLOYS OVER SMB: HDT test VMs
# live on the isolated 'HDT Lab' switch, which cannot reach a share on the host.
#
# The resolution Contexts use the same It names as
# New-HDTLocalContentProvider.Tests.ps1, so the two files can be diffed.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = '\\hdtserver\HdtShare'

    # WHAT Connect ANSWERS WITH. The share is mapped to a letter - MDT's model,
    # and the only shape cmd.exe can hold as a working directory - so the root a
    # step resolves against is a drive, not the UNC path. Z: because nothing in
    # the fake has taken it.
    $script:drive = 'Z:\'

    # Built a character at a time rather than with ConvertTo-SecureString
    # -AsPlainText, which PSScriptAnalyzer refuses outright
    # (PSAvoidUsingConvertToSecureStringWithPlainText) and which would need a
    # suppression in every test file that names a password.
    $script:newCredential = {
        param([string] $UserName, [string] $Plain)

        $secure = New-Object System.Security.SecureString
        foreach ($character in $Plain.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()

        return (New-Object System.Management.Automation.PSCredential $UserName, $secure)
    }

    $script:emptyCredential = {
        param([string] $UserName)

        return (New-Object System.Management.Automation.PSCredential $UserName,
            (New-Object System.Security.SecureString))
    }

    $script:row = {
        param([string] $UserName, [string] $Dialect, [bool] $Encrypted)

        return [pscustomobject] @{
            ServerName = 'hdtserver'
            ShareName  = 'HdtShare'
            UserName   = $UserName
            Dialect    = $Dialect
            Encrypted  = $Encrypted
            Signed     = $true
        }
    }

    # The warning stream of a ScriptMethod call, which is the only way to see a
    # Write-Warning raised inside one: -WarningVariable is a cmdlet parameter and
    # a method call has none.
    # WHAT Connect NOTICED, READ OFF THE PROVIDER RATHER THAN OFF STREAM 3.
    # These used to be Write-Warning, and a deployed machine showed the cost:
    # "the connection to '192.168.2.42' is not encrypted" was printed on a
    # PowerShell console that had landed over the Deployment Summary, while the
    # run log for that deployment said nothing about it. The provider records
    # them; the payload writes them with Write-HDTLog.
    #
    # STREAM 3 IS STILL CAPTURED, and asserted empty below: a Write-Warning that
    # crept back in would otherwise pass every assertion here by being invisible.
    $script:connectWithWarning = {
        param([object] $Provider)

        $output = $($Provider.Connect()) 3>&1

        return [pscustomobject] @{
            Warning = @($Provider.Warning)
            Stream  = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            Value   = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        }
    }
}

Describe 'New-HDTSmbContentProvider' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:credential = & $script:newCredential 'CONTOSO\svc-hdt-deploy' 'P@ssw0rd-not-in-a-log'
    }

    Context 'what it refuses before it connects' {

        It 'refuses a root that is not UNC' {
            $smb = New-HDTFakeSmbService
            $provider = New-HDTSmbContentProvider -Root 'C:\HDTLab\Share' -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $record = $null
            try { $provider.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*C:\HDTLab\Share*'
        }

        It 'refuses a credential with an empty password' {
            $smb = New-HDTFakeSmbService
            $provider = New-HDTSmbContentProvider -Root $script:root `
                -Credential (& $script:emptyCredential 'CONTOSO\svc-hdt-deploy') `
                -SmbService $smb -FileSystem $script:fileSystem

            $record = $null
            try { $provider.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTSecurityError*'
            $record.Exception.Message | Should -BeLike '*anonymous*'
        }

        It 'refuses to connect with no credential at all' {
            # DESIGN 6.3's refusal to fall back to guest starts here: not
            # supplying a credential is exactly the fallback.
            $smb = New-HDTFakeSmbService
            $provider = New-HDTSmbContentProvider -Root $script:root -SmbService $smb -FileSystem $script:fileSystem

            $record = $null
            try { $provider.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTSecurityError*'
            $record.Exception.Message | Should -BeLike '*AllowAnonymous*'
        }

        It 'connects with no credential when -AllowAnonymous was given' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'HDTSERVER\itamartz' '3.1.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -AllowAnonymous `
                -SmbService $smb -FileSystem $script:fileSystem

            $provider.Connect() | Should -BeExactly $script:drive
        }

        It 'refuses when insecure guest logons are enabled and no credential was given' {
            # HDT REPORTS THE MACHINE'S POSTURE, IT DOES NOT CHANGE IT. Turning
            # a security setting off to make a deployment work is the opposite of
            # what this check is for.
            $smb = New-HDTFakeSmbService -ClientConfiguration @{ EnableInsecureGuestLogons = $true } `
                -Connection @(& $script:row 'HDTSERVER\itamartz' '3.1.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -AllowAnonymous `
                -SmbService $smb -FileSystem $script:fileSystem

            $record = $null
            try { $provider.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTSecurityError*'
            $record.Exception.Message | Should -BeLike '*EnableInsecureGuestLogons*'
        }

        It 'maps nothing when it refuses' {
            # 04-02's "writes nothing when it refuses", and the one that matters
            # most here: a refusal that had already mapped would leave the
            # machine attached to the share it just objected to.
            $smb = New-HDTFakeSmbService
            $provider = New-HDTSmbContentProvider -Root 'C:\HDTLab\Share' -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            try { $provider.Connect() } catch { $null = $_ }

            @($smb.Operations).Count | Should -Be 0
        }

        It 'maps nothing when it has no credential' {
            $smb = New-HDTFakeSmbService
            $provider = New-HDTSmbContentProvider -Root $script:root -SmbService $smb -FileSystem $script:fileSystem

            try { $provider.Connect() } catch { $null = $_ }

            @($smb.GetOperationName()) | Should -Not -Contain 'NewMapping'
        }

        It 'maps nothing when insecure guest logons are enabled' {
            $smb = New-HDTFakeSmbService -ClientConfiguration @{ EnableInsecureGuestLogons = $true }
            $provider = New-HDTSmbContentProvider -Root $script:root -AllowAnonymous `
                -SmbService $smb -FileSystem $script:fileSystem

            try { $provider.Connect() } catch { $null = $_ }

            @($smb.GetOperationName()) | Should -Not -Contain 'NewMapping'
        }
    }

    Context 'the identity it got back' {

        It 'accepts the credential identity it asked for' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '3.1.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $captured = & $script:connectWithWarning $provider

            $captured.Value | Should -Be @($script:drive)
            $captured.Warning.Count | Should -Be 0
        }

        It 'refuses a connection that came back as Guest' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'HDTSERVER\Guest' '3.1.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $record = $null
            try { $provider.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTSecurityError*'
            $record.Exception.Message | Should -BeLike '*guest*'
            $record.Exception.Message | Should -BeLike '*hdtserver*'
        }

        It 'judges the connection row for the share it mapped' {
            # Get-SmbConnection returns a row per share, and IPC$ is always one
            # of them - probed on this host, a loopback mapping produced two
            # rows. Judging whichever happened to be first would make the
            # refusal depend on enumeration order.
            $smb = New-HDTFakeSmbService -Connection @(
                [pscustomobject] @{ ServerName = 'hdtserver'; ShareName = 'IPC$'; UserName = 'HDTSERVER\Guest'; Dialect = '3.1.1'; Encrypted = $true; Signed = $true },
                (& $script:row 'CONTOSO\svc-hdt-deploy' '3.1.1' $true))

            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $provider.Connect() | Should -BeExactly $script:drive
        }

        It 'refuses one that came back as ANONYMOUS LOGON' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'NT AUTHORITY\ANONYMOUS LOGON' '3.1.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            { $provider.Connect() } | Should -Throw -ExpectedMessage '*HDTSecurityError*'
        }

        It 'refuses one whose user name is empty' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row '' '3.1.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            { $provider.Connect() } | Should -Throw -ExpectedMessage '*HDTSecurityError*'
        }

        It 'matches Guest case-insensitively' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'hdtserver\guest' '3.1.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            { $provider.Connect() } | Should -Throw -ExpectedMessage '*HDTSecurityError*'
        }

        It 'disconnects the mapping it refused' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'HDTSERVER\Guest' '3.1.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            try { $provider.Connect() } catch { $null = $_ }

            @($smb.GetOperationName()) |
                Should -Be @('GetUsedDriveLetter', 'NewMapping', 'GetConnection', 'RemoveMapping')
            @($smb.GetConnection('hdtserver')).Count | Should -Be 0
        }

        It 'refuses an SMB1 dialect' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '1.5' $false)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $record = $null
            try { $provider.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTSecurityError*'
            $record.Exception.Message | Should -BeLike '*SMB1*'
        }

        It 'warns but continues on dialect 2.1' {
            # A 2.1 file server is legitimate, and refusing it would be HDT
            # deciding a fleet's infrastructure for it.
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '2.1' $true)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $captured = & $script:connectWithWarning $provider

            $captured.Value | Should -Be @($script:drive)
            $captured.Warning.Count | Should -Be 1
            [string] $captured.Warning[0] | Should -BeLike '*2.1*'
            $captured.Stream.Count | Should -Be 0 -Because 'it is recorded for the log, not printed'
        }

        It 'warns once when the connection is unencrypted' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '3.1.1' $false)
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $captured = & $script:connectWithWarning $provider

            $captured.Warning.Count | Should -Be 1
            [string] $captured.Warning[0] | Should -BeLike '*hdtserver*'
            $captured.Stream.Count | Should -Be 0 -Because 'it is recorded for the log, not printed'
        }

        It 'throws when no connection row came back at all' {
            # The mapping did not take. A provider that shrugged would deploy
            # from whatever the path happened to resolve to.
            $smb = New-HDTFakeSmbService -Connection @(
                [pscustomobject] @{ ServerName = 'someone-else'; ShareName = 'Other'; UserName = 'CONTOSO\svc-hdt-deploy'; Dialect = '3.1.1'; Encrypted = $true; Signed = $true })
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $record = $null
            try { $provider.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*hdtserver*'
        }
    }

    Context 'the interface' {

        BeforeEach {
            $script:smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '3.1.1' $true)
            $script:content = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $script:smb -FileSystem $script:fileSystem
        }

        It 'exposes every method the contract requires' {
            $method = @($script:content | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('ResolveContent', 'TestContent', 'CopyContent', 'Connect', 'Disconnect')) {
                $method | Should -Contain $name
            }
        }

        It 'names itself ContentProvider' {
            $script:content.ServiceName | Should -BeExactly 'ContentProvider'
        }

        It 'exposes a Root' {
            $script:content.Root | Should -BeExactly $script:root
        }

        It 'resolves a relative path against the root' {
            $script:content.ResolveContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim') |
                Should -BeExactly '\\hdtserver\HdtShare\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }

        It 'accepts a forward-slash relative path' {
            $script:content.ResolveContent('OperatingSystems/Win11-LTSC-2024/sources/install.wim') |
                Should -BeExactly '\\hdtserver\HdtShare\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }

        It 'returns a rooted path unchanged' {
            $script:content.ResolveContent('D:\Captures\surface.ffu') | Should -BeExactly 'D:\Captures\surface.ffu'
        }

        It 'refuses a path that escapes the root' {
            # [IO.Path]::GetFullPath clamps '..' at the root of a UNC share
            # rather than reporting the escape - '\\server\Share\..\..\Windows'
            # is '\\server\Share\Windows' on both engines - so the segments are
            # walked by hand and this is the test that says so.
            $record = $null
            try { $script:content.ResolveContent('..\..\Windows\System32\config\SAM') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.ArgumentException])

            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
        }

        It 'allows a .. that stays inside the root' {
            $script:content.ResolveContent('OperatingSystems\..\Applications\7zip\install.cmd') |
                Should -BeExactly '\\hdtserver\HdtShare\Applications\7zip\install.cmd'
        }

        It 'refuses an empty path' {
            { $script:content.ResolveContent('  ') } | Should -Throw -ExpectedMessage '*HDTConfigurationError*'
        }

        It 'does not check existence when it resolves' {
            $script:content.ResolveContent('OperatingSystems\NoSuchOs\sources\install.wim') | Out-Null

            @($script:fileSystem.Operations).Count | Should -Be 0
        }

        It 'reads through the injected filesystem' {
            $script:fileSystem.SeedFile('\\hdtserver\HdtShare\Applications\7zip\install.cmd', 'x')

            $script:content.TestContent('Applications\7zip\install.cmd') | Should -BeTrue
            @($script:fileSystem.Operations | ForEach-Object { $_.Operation }) | Should -Be @('TestPath')
        }

        It 'creates the destination directory before copying' {
            $script:fileSystem.SeedFile('\\hdtserver\HdtShare\Boot\HDTPE_x64.wim', 'WIM')

            $script:content.CopyContent('Boot\HDTPE_x64.wim', 'C:\Stage\HDTPE_x64.wim') | Out-Null

            @($script:fileSystem.Operations | ForEach-Object { $_.Operation }) |
                Should -Be @('TestPath', 'CreateDirectory', 'CopyItem')
        }

        It 'returns the destination from CopyContent' {
            $script:fileSystem.SeedFile('\\hdtserver\HdtShare\Boot\HDTPE_x64.wim', 'WIM')

            $script:content.CopyContent('Boot\HDTPE_x64.wim', 'C:\Stage\HDTPE_x64.wim') |
                Should -BeExactly 'C:\Stage\HDTPE_x64.wim'
        }

        It 'throws for a source that is not there' {
            $record = $null
            try { $script:content.CopyContent('Boot\Absent.wim', 'C:\Stage\Absent.wim') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'records ResolveContent before it can throw' {
            try { $script:content.ResolveContent('..\..\Windows') } catch { $null = $_ }

            @($script:content.GetOperationName()) | Should -Be @('ResolveContent')
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $provider = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService (New-HDTFakeSmbService) -FileSystem (New-HDTFakeFileSystem) -Journal $journal

            $provider.ResolveContent('a.txt') | Out-Null

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('ContentProvider.ResolveContent')
        }
    }

    Context 'connect and disconnect' {

        BeforeEach {
            $script:smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '3.1.1' $true)
            $script:content = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $script:smb -FileSystem $script:fileSystem
        }

        It 'maps once when Connect is called twice' {
            $script:content.Connect() | Out-Null
            $script:content.Connect() | Out-Null

            @($script:smb.Operations | Where-Object { $_.Operation -eq 'NewMapping' }).Count | Should -Be 1
        }

        It 'never throws from Disconnect' {
            # It runs in a finally. A teardown that throws is a teardown that
            # does not finish.
            $smb = New-HDTFakeSmbService -Failure @{ RemoveMapping = 'The network name cannot be found.' }
            $content = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            { $content.Disconnect() } | Should -Not -Throw
        }

        It 'unmaps even when nothing was mapped' {
            $script:content.Disconnect()

            @($script:smb.GetOperationName()) | Should -Contain 'RemoveMapping'
        }

        It 'unmaps what it mapped' {
            $script:content.Connect() | Out-Null
            $script:content.Disconnect()

            @($script:smb.GetConnection('hdtserver')).Count | Should -Be 0
        }

        It 'does not record the password anywhere' {
            $script:content.Connect() | Out-Null

            $printed = ($script:smb.Operations | Out-String) + ($script:content.Operations | Out-String)
            $printed | Should -Not -BeLike '*P@ssw0rd-not-in-a-log*'
        }
    }

    Context 'the drive letter, which is what MDT mapped' {

        # MDT MAPS THE SHARE TO A LETTER AND RUNS EVERYTHING FROM IT, and the
        # reason is not tidiness: cmd.exe REFUSES A UNC WORKING DIRECTORY. It
        # prints "UNC paths are not supported" and moves itself to
        # %SystemRoot%, so an application whose install command names its own
        # installer relatively - which is what every vendor documents - runs in
        # C:\Windows and cannot find it.

        BeforeEach {
            $script:smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '3.1.1' $true)
            $script:content = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $script:smb -FileSystem $script:fileSystem
        }

        It 'maps the share to a drive letter' {
            $script:content.Connect() | Out-Null

            $mapping = @($script:smb.Operations | Where-Object { $_.Operation -eq 'NewMapping' })[0]
            $mapping.Arguments[3] | Should -BeExactly 'Z:'
        }

        It 'takes the first free letter from Z downward' {
            $smb = New-HDTFakeSmbService -UsedDriveLetter @('Z', 'Y') `
                -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '3.1.1' $true)
            $content = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $content.Connect() | Out-Null

            $mapping = @($smb.Operations | Where-Object { $_.Operation -eq 'NewMapping' })[0]
            $mapping.Arguments[3] | Should -BeExactly 'X:'
        }

        It 'refuses when no letter is free' {
            $taken = @([char[]] (67..90) | ForEach-Object { [string] $_ })
            $smb = New-HDTFakeSmbService -UsedDriveLetter $taken `
                -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy' '3.1.1' $true)
            $content = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            $record = $null
            try { $content.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTEnvironmentError*'

            # AND IT MAPPED NOTHING. A refusal that mapped first would leave the
            # share attached to a letter nobody recorded.
            @($smb.GetOperationName()) | Should -Not -Contain 'NewMapping'
        }

        It 'returns the drive from Connect' {
            $script:content.Connect() | Should -BeExactly 'Z:\'
        }

        It 'is the drive while it is connected' {
            $script:content.Connect() | Out-Null

            $script:content.Root | Should -BeExactly 'Z:\'
        }

        It 'resolves content through the drive' {
            $script:content.Connect() | Out-Null

            $script:content.ResolveContent('Applications\7zip\install.cmd') |
                Should -BeExactly 'Z:\Applications\7zip\install.cmd'
        }

        It 'is the UNC path again after Disconnect' {
            $script:content.Connect() | Out-Null
            $script:content.Disconnect()

            $script:content.Root | Should -BeExactly $script:root
            $script:content.ResolveContent('Applications\7zip\install.cmd') |
                Should -BeExactly '\\hdtserver\HdtShare\Applications\7zip\install.cmd'
        }

        It 'unmaps by the remote path, not by the letter' {
            $script:content.Connect() | Out-Null
            $script:content.Disconnect()

            $removal = @($script:smb.Operations | Where-Object { $_.Operation -eq 'RemoveMapping' })[0]
            $removal.Arguments[0] | Should -BeExactly $script:root
        }

        It 'leaves the root as the UNC path when it refuses the connection' {
            $smb = New-HDTFakeSmbService -Connection @(& $script:row 'HDTSERVER\Guest' '3.1.1' $true)
            $content = New-HDTSmbContentProvider -Root $script:root -Credential $script:credential `
                -SmbService $smb -FileSystem $script:fileSystem

            try { $content.Connect() } catch { $null = $_ }

            $content.Root | Should -BeExactly $script:root
        }

        It 'answers for a path under the share it mapped through the drive' {
            # A CALLER THAT ALREADY HOLDS THE UNC PATH IS THE NORMAL CASE, not an
            # odd one: the workspace root a step is given is the share it was
            # told to deploy from, so the application catalog hands paths back
            # under it. Those name the same files the mapping does, and a step
            # that got the UNC form would be handed a folder cmd.exe cannot
            # stand in - which is the whole reason the letter exists.
            $script:content.Connect() | Out-Null

            $script:content.ResolveContent('\\hdtserver\HdtShare\Applications\7Zip-24.09\source') |
                Should -BeExactly 'Z:\Applications\7Zip-24.09\source'
        }

        It 'leaves a rooted path somewhere else alone' {
            # DESIGN 9.3: media registered where it stands is not re-rooted. The
            # share it mapped is not somewhere else - it is the same files by
            # another name - but a captured image on a local disk is.
            $script:content.Connect() | Out-Null

            $script:content.ResolveContent('D:\Captures\surface.ffu') |
                Should -BeExactly 'D:\Captures\surface.ffu'
        }

        It 'answers for the share itself as the drive' {
            $script:content.Connect() | Out-Null

            $script:content.ResolveContent('\\hdtserver\HdtShare') | Should -BeExactly 'Z:\'
        }

        It 'is the UNC path again for a path under the share after Disconnect' {
            $script:content.Connect() | Out-Null
            $script:content.Disconnect()

            $script:content.ResolveContent('\\hdtserver\HdtShare\Applications\7Zip-24.09\source') |
                Should -BeExactly '\\hdtserver\HdtShare\Applications\7Zip-24.09\source'
        }

        It 'exposes the share it mapped as RemoteRoot throughout' {
            $script:content.Connect() | Out-Null

            $script:content.RemoteRoot | Should -BeExactly $script:root
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name New-HDTSmbContentProvider -ErrorAction Stop

            $help.Name | Should -BeExactly 'New-HDTSmbContentProvider'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
