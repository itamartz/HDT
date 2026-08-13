# THE Smb PROVIDER AGAINST A REAL SMB SERVER - which on this host is this host.
#
# WHAT THIS DOES NOT DO, AND WHY. No VM in phase 05 deploys over SMB.
# PROJECT.md rule 2 puts every HDT test VM on the isolated 'HDT Lab' switch, and
# SPIKES S6 records that a VM there CANNOT REACH A SHARE ON THE HOST - the host's
# vNIC on that side is not routed to it. Moving a test VM to a switch that could
# reach the share would break the rule that exists to keep HDT's PXE work away
# from CM01's PXE responder. So the Smb provider is proven in two places and
# neither of them is a deployment:
#
#   - every decision - the guest refusal, SMB1, the dialect warning, the
#     re-entrancy, what it maps when it refuses - in tests/unit against
#     New-HDTFakeSmbService;
#   - the MECHANISM here: New-SmbMapping, Get-SmbConnection, Get-SmbClientConfiguration
#     and Remove-SmbMapping, host to host over LOOPBACK.
#
# LOOPBACK, NOT THE LAN ADDRESS. SPIKES S6 records that inbound SMB on this host
# was blocked by default - zero File and Printer Sharing rules enabled - and
# opening a firewall port is not something a test gets to do. \\localhost never
# leaves the machine.
#
# 'refuses a share it authenticated to as guest' IS DELIBERATELY NOT HERE.
# Producing a real guest connection means turning on EnableInsecureGuestLogons,
# which is a change to the developer's security posture, and no test gets to make
# one. That refusal is proven in
# tests/unit/New-HDTSmbContentProvider.Tests.ps1 - 'refuses a connection that came
# back as Guest', and the three around it.
#
# The share is HDTIntegration$ over a folder this file creates under
# C:\HDTLab\scratch\smb, and AfterAll removes both and asserts the share is gone.

BeforeDiscovery {
    # WHAT -Skip: READS, AND IT CAN ONLY BE COMPUTED HERE. -Skip: on a Context is
    # bound while Pester is discovering, so a variable set in BeforeAll is not
    # merely stale there - it does not exist, and under ./build.ps1's StrictMode
    # discovery dies with "the variable cannot be retrieved". That is SPIKES
    # S9.15 from the other side, and it happened to this very file on its first
    # run through build.ps1.
    #
    # The condition is therefore computed TWICE, from the same two inputs: here
    # for -Skip:, and again in BeforeAll for the body.
    $script:skipSmb = -not (
        ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator) -and
        ($null -ne (Get-Command -Name 'New-SmbShare' -ErrorAction SilentlyContinue)))
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # Recomputed, never read across the phase boundary (SPIKES S9.15).
    $script:isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    $script:hasSmbCmdlet = $null -ne (Get-Command -Name 'New-SmbShare' -ErrorAction SilentlyContinue)
    $script:skipSmb = -not ($script:isElevated -and $script:hasSmbCmdlet)

    $script:shareName = 'HDTIntegration$'
    $script:shareRoot = Join-Path -Path 'C:\HDTLab\scratch\smb' -ChildPath ('run-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $script:remotePath = '\\localhost\{0}' -f $script:shareName
    $script:shareCreated = $false

    if (-not $script:isElevated) {
        Write-Warning 'SmbContentProvider.Integration.Tests.ps1 skipped: creating an SMB share needs an elevated session.'
    }

    if ($script:isElevated -and $script:hasSmbCmdlet) {
        try {
            New-Item -Path $script:shareRoot -ItemType Directory -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path -Path $script:shareRoot -ChildPath 'workspace.yaml'),
                "schemaVersion: 1`nid: HDT-INTEGRATION`n")

            New-Item -Path (Join-Path -Path $script:shareRoot -ChildPath 'OperatingSystems\Win11-Integration\sources') -ItemType Directory -Force | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:shareRoot -ChildPath 'OperatingSystems\Win11-Integration\sources\install.wim'),
                'not a real WIM, but a real file with real bytes to hash')

            # An existing share from a previous interrupted run is removed first,
            # by name and by name only.
            Get-SmbShare -Name $script:shareName -ErrorAction SilentlyContinue | Remove-SmbShare -Force -ErrorAction SilentlyContinue

            $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            New-SmbShare -Name $script:shareName -Path $script:shareRoot -FullAccess $me | Out-Null
            $script:shareCreated = $true
        } catch {
            Write-Warning ("SmbContentProvider.Integration.Tests.ps1 skipped: the throwaway share could not be created ({0}). No firewall rule is opened to work around this." -f $_.Exception.Message)
        }
    }
}

AfterAll {
    # Runs on failure too. Both deletes name exactly what this file created.
    Get-SmbMapping -RemotePath $script:remotePath -ErrorAction SilentlyContinue | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
    Get-SmbShare -Name $script:shareName -ErrorAction SilentlyContinue | Remove-SmbShare -Force -ErrorAction SilentlyContinue

    if ($script:shareRoot -and (Test-Path -LiteralPath $script:shareRoot)) {
        Remove-Item -LiteralPath $script:shareRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (@(Get-SmbShare -Name $script:shareName -ErrorAction SilentlyContinue).Count -ne 0) {
        throw "SmbContentProvider.Integration.Tests.ps1 left the share '$script:shareName' behind. Remove it: Remove-SmbShare -Name '$script:shareName' -Force"
    }
}

Describe 'New-HDTSmbContentProvider against a real SMB share' {

    BeforeEach {
        # Whether the share COULD be created is a discovery-time question
        # (elevation, and the SmbShare module); whether it WAS is only knowable
        # after BeforeAll ran. This is the run-phase half, and it skips rather
        # than opening a firewall port or turning a security setting off.
        if (-not $script:shareCreated) {
            Set-ItResult -Skipped -Because 'the throwaway loopback share could not be created on this machine'
        }
    }

    Context 'loopback' -Skip:$skipSmb {

        BeforeAll {
            $script:content = New-HDTSmbContentProvider -Root $script:remotePath -AllowAnonymous
        }

        AfterAll {
            if ($null -ne $script:content) { $script:content.Disconnect() }
        }

        It 'connects and returns the root' {
            # -AllowAnonymous means "this machine's own identity", said out loud.
            # There is no second account to authenticate as on a developer's box,
            # and inventing one is a change to the machine, not a test.
            $script:content.Connect() | Should -BeExactly $script:remotePath
        }

        It 'reports the dialect the server negotiated' {
            $smb = New-HDTSmbService
            $row = @($smb.GetConnection('localhost') | Where-Object { $_.ShareName -eq $script:shareName })

            $row.Count | Should -BeGreaterThan 0
            Write-Information ("SMB loopback negotiated: dialect={0} encrypted={1} signed={2} user={3}" -f
                $row[0].Dialect, $row[0].Encrypted, $row[0].Signed, $row[0].UserName) -InformationAction Continue

            $row[0].Dialect | Should -Not -BeNullOrEmpty
        }

        It 'reports the SMB client configuration' {
            $configuration = (New-HDTSmbService).GetClientConfiguration()

            Write-Information ("SMB client: EnableInsecureGuestLogons={0} RequireSecuritySignature={1}" -f
                $configuration.EnableInsecureGuestLogons, $configuration.RequireSecuritySignature) -InformationAction Continue

            $configuration.EnableInsecureGuestLogons | Should -BeOfType ([bool])
        }

        It 'finds content that was staged' {
            $script:content.Connect() | Out-Null

            $script:content.TestContent('OperatingSystems\Win11-Integration\sources\install.wim') | Should -BeTrue
        }

        It 'reports false for content that is not there' {
            $script:content.TestContent('OperatingSystems\NoSuchOs\sources\install.wim') | Should -BeFalse
        }

        It 'resolves a UNC path the real filesystem can find' {
            $resolved = $script:content.ResolveContent('OperatingSystems\Win11-Integration\sources\install.wim')

            $resolved | Should -BeExactly ('{0}\OperatingSystems\Win11-Integration\sources\install.wim' -f $script:remotePath)
            Test-Path -LiteralPath $resolved | Should -BeTrue
        }

        It 'copies bytes that hash identical to the source' {
            $destination = Join-Path -Path $script:shareRoot -ChildPath 'copied-install.wim'

            $script:content.CopyContent('OperatingSystems\Win11-Integration\sources\install.wim', $destination) |
                Should -BeExactly $destination

            $source = Join-Path -Path $script:shareRoot -ChildPath 'OperatingSystems\Win11-Integration\sources\install.wim'
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash |
                Should -BeExactly (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        }

        It 'creates the destination directory it was given' {
            $destination = Join-Path -Path $script:shareRoot -ChildPath 'staged\deeper\install.wim'

            $script:content.CopyContent('OperatingSystems\Win11-Integration\sources\install.wim', $destination) | Out-Null

            Test-Path -LiteralPath $destination | Should -BeTrue
        }

        It 'refuses a path that escapes the root, against a real share' {
            $record = $null
            try { $script:content.ResolveContent('..\..\Windows\System32\config\SAM') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
        }

        It 'maps once when Connect is called twice' {
            $script:content.Connect() | Out-Null
            $script:content.Connect() | Out-Null

            @($script:content.SmbService.Operations | Where-Object { $_.Operation -eq 'NewMapping' }).Count |
                Should -Be 1
        }

        It 'removes the mapping on Disconnect' {
            $provider = New-HDTSmbContentProvider -Root $script:remotePath -AllowAnonymous
            $provider.Connect() | Out-Null

            # Asserted on the mapping's own RemotePath, not on a count: SPIKES
            # S9.15b - @($null).Count is 1, so a count alone would pass for no
            # mapping at all.
            @(Get-SmbMapping -RemotePath $script:remotePath -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.RemotePath }) | Should -Contain $script:remotePath

            $provider.Disconnect()

            @(Get-SmbMapping -RemotePath $script:remotePath -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It 'refuses a root that is not UNC, against the real adapter' {
            $provider = New-HDTSmbContentProvider -Root $script:shareRoot -AllowAnonymous

            { $provider.Connect() } | Should -Throw -ExpectedMessage '*HDTConfigurationError*'
        }

        It 'refuses to connect with no credential and no -AllowAnonymous' {
            $provider = New-HDTSmbContentProvider -Root $script:remotePath

            { $provider.Connect() } | Should -Throw -ExpectedMessage '*HDTSecurityError*'
        }
    }

    Context 'the credential round trip on a real share' -Skip:$skipSmb {

        It 'writes and reads the deployment credential over SMB' {
            # Control\share-credential.json, written through the real filesystem
            # adapter to a UNC path and read back - which is what a boot image
            # build does.
            $secure = New-Object System.Security.SecureString
            foreach ($character in 'P@ssw0rd-integration'.ToCharArray()) { $secure.AppendChar($character) }
            $credential = New-Object System.Management.Automation.PSCredential 'CONTOSO\svc-hdt-deploy', $secure

            Set-HDTShareCredential -WorkspaceRoot $script:remotePath -Credential $credential -Confirm:$false

            $read = Get-HDTShareCredential -WorkspaceRoot $script:remotePath

            $read.UserName | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
            $read.Password | Should -BeExactly 'P@ssw0rd-integration'

            $onDisk = [System.IO.File]::ReadAllText((Join-Path -Path $script:shareRoot -ChildPath 'Control\share-credential.json'))
            $onDisk | Should -Not -BeLike '*P@ssw0rd-integration*'

            # UTF-8, no BOM (tests/helpers/README.md F11), on the real bytes.
            $byte = [System.IO.File]::ReadAllBytes((Join-Path -Path $script:shareRoot -ChildPath 'Control\share-credential.json'))
            @($byte[0], $byte[1], $byte[2]) | Should -Not -Be @(239, 187, 191)
        }
    }

    Context 'the ACL check on a real share' -Skip:$skipSmb {

        It 'reads real access rules and judges them without throwing' {
            $accessRule = @{ '.' = Get-HDTShareAccessRule -Path $script:shareRoot }

            @($accessRule['.']).Count | Should -BeGreaterThan 2
            $accessRule['.'][0].Identity | Should -Not -BeNullOrEmpty

            $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $result = Test-HDTShareAcl -WorkspaceRoot $script:shareRoot -Identity $me -AccessRule $accessRule

            # This developer's own account is an administrator on this machine
            # and the folder is under their profile's reach, so the expected
            # answer here is NOT Compliant - and saying so is the point. The
            # check is asserted to run and to judge, not to approve.
            $result.Compliant | Should -BeOfType ([bool])
            @($result.Finding | ForEach-Object { $_.Severity }) | Should -Contain 'Critical'
        }

        It 'returns $null from the adapter for a path it cannot read' {
            Get-HDTShareAccessRule -Path 'C:\HDTLab\scratch\smb\no-such-folder-here' | Should -BeNullOrEmpty
        }
    }
}
