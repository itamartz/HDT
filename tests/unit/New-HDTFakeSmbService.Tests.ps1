# The ISmbService double, and the reason the Smb provider's decisions are
# provable on a machine with no share (DESIGN 6.3, DESIGN 12.2.1).
#
# Four methods, all of them thin over the SmbShare module - which DESIGN 5.1
# records as PRESENT in WinPE, unlike NetTCPIP and NetAdapter:
#
#   NewMapping(remotePath, userName, password)
#   RemoveMapping(remotePath)
#   GetConnection(serverName) -> ServerName, ShareName, UserName, Dialect,
#                                Encrypted, Signed
#   GetClientConfiguration()  -> EnableInsecureGuestLogons, RequireSecuritySignature
#
# -Connection SEEDS WHAT A MAPPING WILL BECOME. That is how the guest case is
# staged: seed a row whose UserName is Guest, and the provider must refuse the
# connection it just made rather than deploy from a share it authenticated to as
# nobody.
#
# THE PASSWORD IS NOT IN THE RECORDING. $Operations is printed verbatim in a
# Pester failure message, and a journal that carried the deployment password
# would put it in every failure dump (tests/helpers/README.md section 4).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:remotePath = '\\hdtserver\HdtShare'
    $script:password = 'P@ssw0rd-not-in-a-log'
}

Describe 'New-HDTFakeSmbService' {

    Context 'mapping' {

        It 'adds a connection when it maps' {
            $smb = New-HDTFakeSmbService

            @($smb.GetConnection('hdtserver')).Count | Should -Be 0

            $smb.NewMapping($script:remotePath, 'CONTOSO\svc-hdt-deploy', $script:password)

            @($smb.GetConnection('hdtserver')).Count | Should -Be 1
        }

        It 'removes it when it unmaps' {
            $smb = New-HDTFakeSmbService
            $smb.NewMapping($script:remotePath, 'CONTOSO\svc-hdt-deploy', $script:password)

            $smb.RemoveMapping($script:remotePath)

            @($smb.GetConnection('hdtserver')).Count | Should -Be 0
        }

        It 'returns the seeded identity for the mapped server' {
            $smb = New-HDTFakeSmbService -Connection @(
                [pscustomobject] @{ ServerName = 'hdtserver'; ShareName = 'HdtShare'; UserName = 'hdtserver\Guest'; Dialect = '3.1.1'; Encrypted = $false; Signed = $true })

            $smb.NewMapping($script:remotePath, 'CONTOSO\svc-hdt-deploy', $script:password)

            @($smb.GetConnection('hdtserver'))[0].UserName | Should -BeExactly 'hdtserver\Guest'
        }

        It 'reports the identity it was mapped with when nothing was seeded' {
            $smb = New-HDTFakeSmbService
            $smb.NewMapping($script:remotePath, 'CONTOSO\svc-hdt-deploy', $script:password)

            $row = @($smb.GetConnection('hdtserver'))[0]
            $row.UserName | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
            $row.ShareName | Should -BeExactly 'HdtShare'
            $row.Dialect | Should -BeExactly '3.1.1'
        }

        It 'produces no connection for a server the seeds did not name' {
            # SEEDING IS AUTHORITATIVE. Once a test has said what a mapping
            # becomes, a mapping to some other server becomes nothing - which is
            # how "the mapping did not take" is staged, and that is a case the
            # provider has to have an answer for.
            $smb = New-HDTFakeSmbService -Connection @(
                [pscustomobject] @{ ServerName = 'someone-else'; ShareName = 'Other'; UserName = 'CONTOSO\svc'; Dialect = '3.1.1'; Encrypted = $true; Signed = $true })

            $smb.NewMapping($script:remotePath, 'CONTOSO\svc-hdt-deploy', $script:password)

            @($smb.GetConnection('hdtserver')).Count | Should -Be 0
        }

        It 'returns an empty list for a server that was never mapped' {
            $smb = New-HDTFakeSmbService

            @($smb.GetConnection('someone-else')).Count | Should -Be 0
        }

        It 'does not throw from RemoveMapping when nothing was mapped' {
            $smb = New-HDTFakeSmbService

            { $smb.RemoveMapping($script:remotePath) } | Should -Not -Throw
        }
    }

    Context 'client configuration' {

        It 'reports insecure guest logons as disabled by default' {
            $smb = New-HDTFakeSmbService

            $smb.GetClientConfiguration().EnableInsecureGuestLogons | Should -BeFalse
        }

        It 'reports the seeded client configuration' {
            $smb = New-HDTFakeSmbService -ClientConfiguration @{ EnableInsecureGuestLogons = $true; RequireSecuritySignature = $true }

            $smb.GetClientConfiguration().EnableInsecureGuestLogons | Should -BeTrue
            $smb.GetClientConfiguration().RequireSecuritySignature | Should -BeTrue
        }
    }

    Context 'recording' {

        It 'names itself SmbService' {
            (New-HDTFakeSmbService).ServiceName | Should -BeExactly 'SmbService'
        }

        It 'records NewMapping with the remote path and the user name' {
            $smb = New-HDTFakeSmbService
            $smb.NewMapping($script:remotePath, 'CONTOSO\svc-hdt-deploy', $script:password)

            $smb.GetOperationName() | Should -Be @('NewMapping')
            [string] $smb.Operations[0].Arguments[0] | Should -BeExactly $script:remotePath
            [string] $smb.Operations[0].Arguments[1] | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
        }

        It 'does not record the password' {
            $smb = New-HDTFakeSmbService
            $smb.NewMapping($script:remotePath, 'CONTOSO\svc-hdt-deploy', $script:password)

            $printed = ($smb.Operations | Out-String) + ($smb.Operations[0].Arguments -join ' ')
            $printed | Should -Not -BeLike ('*{0}*' -f $script:password)
        }

        It 'records the read-only calls too' {
            $smb = New-HDTFakeSmbService
            $smb.GetConnection('hdtserver') | Out-Null
            $smb.GetClientConfiguration() | Out-Null

            $smb.GetOperationName() | Should -Be @('GetConnection', 'GetClientConfiguration')
        }

        It 'does not record seeding' {
            $smb = New-HDTFakeSmbService -Connection @(
                [pscustomobject] @{ ServerName = 'hdtserver'; ShareName = 'HdtShare'; UserName = 'CONTOSO\svc'; Dialect = '3.1.1'; Encrypted = $true; Signed = $true })

            @($smb.Operations).Count | Should -Be 0
        }
    }

    Context 'seeded failures' {

        It 'throws the seeded failure from NewMapping' {
            $smb = New-HDTFakeSmbService -Failure @{ NewMapping = 'The network path was not found.' }

            $record = $null
            try { $smb.NewMapping($script:remotePath, 'CONTOSO\svc', $script:password) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception | Should -BeOfType ([System.InvalidOperationException])
            $record.Exception.Message | Should -BeExactly 'The network path was not found.'
        }

        It 'records NewMapping before it throws' {
            $smb = New-HDTFakeSmbService -Failure @{ NewMapping = 'The network path was not found.' }

            try { $smb.NewMapping($script:remotePath, 'CONTOSO\svc', $script:password) } catch { $null = $_ }

            $smb.GetOperationName() | Should -Be @('NewMapping')
        }

        It 'maps nothing when NewMapping throws' {
            $smb = New-HDTFakeSmbService -Failure @{ NewMapping = 'The network path was not found.' }

            try { $smb.NewMapping($script:remotePath, 'CONTOSO\svc', $script:password) } catch { $null = $_ }

            @($smb.GetConnection('hdtserver')).Count | Should -Be 0
        }
    }

    Context 'the real machine' {

        It 'touches no real SMB client' {
            # tests/helpers/README.md section 7. A fake that fell through to
            # Get-SmbConnection would report this developer's own mappings.
            $smb = New-HDTFakeSmbService

            @($smb.GetConnection('localhost')).Count | Should -Be 0
        }
    }
}
