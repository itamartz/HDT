# A DEPLOYMENT SHARE IS A SHARE, which is what MDT's New Deployment Share
# wizard means by the name: it asks for a folder AND a share name, creates the
# SMB share, and DeployRoot is \\<server>\<share> derived from the two. HDT
# asked for the UNC instead - a box somebody had to fill in by hand with a path
# to a share nothing had created.
#
# THE SERVER IS THE COMPUTER NAME, NOT AN IP ADDRESS, and this repository has
# the argument written down twice: the lab host's address is a DHCP lease that
# moves when the Wi-Fi changes, and DeployRoot is baked into the boot image.
# A name survives what an octet does not. MDT derives \\%servername%\Share$ for
# the same reason.
#
# THE $ IS NOT DECORATION. MDT's default share name ends in one, which hides it
# from browsing - a deployment share holds Control\share-credential.json, and
# that file is obfuscated rather than encrypted.
#
# NOTHING HERE TOUCHES SMB. Creating the share is New-HDTWorkspaceShare's job,
# through an injected ISmbService; this is the decision it and the dialog both
# read.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTWorkspaceShareName' {

    Context 'what it suggests' {

        It 'names the share after the folder, with the dollar MDT uses' {
            $answer = Get-HDTWorkspaceShareName -Path 'C:\HDTLab\Share' -ServerName 'LAP-AMMSO01'

            [string] $answer.ShareName | Should -BeExactly 'Share$'
        }

        It 'derives the deploy root from the computer name and the share' {
            $answer = Get-HDTWorkspaceShareName -Path 'C:\HDTLab\Share' -ServerName 'LAP-AMMSO01'

            [string] $answer.DeployRoot | Should -BeExactly '\\LAP-AMMSO01\Share$'
        }

        It 'takes a share name it was given rather than inventing one' {
            $answer = Get-HDTWorkspaceShareName -Path 'C:\HDTLab\Share' -ShareName 'HDTShare$' `
                -ServerName 'LAP-AMMSO01'

            [string] $answer.ShareName | Should -BeExactly 'HDTShare$'
            [string] $answer.DeployRoot | Should -BeExactly '\\LAP-AMMSO01\HDTShare$'
        }

        It 'adds the dollar to a name given without one' {
            # Hidden by default, because of what is in Control\.
            $answer = Get-HDTWorkspaceShareName -Path 'C:\ws' -ShareName 'HDTShare' -ServerName 'HOST'

            [string] $answer.ShareName | Should -BeExactly 'HDTShare$'
        }
    }

    Context 'what it refuses' {

        It 'refuses <Bad>, which is not a share name' -ForEach @(
            @{ Bad = 'Share name' }
            @{ Bad = 'Share\Sub' }
            @{ Bad = 'Share*' }
            @{ Bad = ('a' * 81) }
        ) {
            $answer = Get-HDTWorkspaceShareName -Path 'C:\ws' -ShareName $Bad -ServerName 'HOST'

            [bool] $answer.IsValid | Should -BeFalse
            [string] $answer.Message | Should -Not -BeNullOrEmpty
        }

        It 'accepts one that is only a dollar sign away from a folder name' {
            (Get-HDTWorkspaceShareName -Path 'C:\ws' -ShareName 'HDT-Share_2$' -ServerName 'HOST').IsValid |
                Should -BeTrue
        }
    }

    Context 'a machine that will not say its name' {

        It 'says so rather than producing \\\\\\ ' {
            # A deploy root with an empty server in it is the shape that reaches
            # the boot image and fails at Welcome, hours later.
            $answer = Get-HDTWorkspaceShareName -Path 'C:\ws' -ServerName ''

            [bool] $answer.IsValid | Should -BeFalse
            [string] $answer.DeployRoot | Should -BeExactly ''
        }
    }
}

Describe 'New-HDTWorkspaceShare' {

    BeforeAll {
        $script:newSmb = {
            New-HDTFakeSmbService
        }
    }

    It 'is exported by Hephaestus' {
        Get-Command -Name 'New-HDTWorkspaceShare' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'creates the share over the folder it was given' {
        $smb = & $script:newSmb

        $made = New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -ShareName 'HDTShare$' `
            -ServerName 'LAP-AMMSO01' -SmbService $smb -Elevated $true -Confirm:$false

        $smb.GetOperationName() | Should -Contain 'NewShare'
        [string] $made.DeployRoot | Should -BeExactly '\\LAP-AMMSO01\HDTShare$'
    }

    It 'grants read to the account that will deploy, and not to everyone' {
        # A DEPLOYMENT SHARE IS NOT A PUBLIC ONE. Control\share-credential.json
        # is obfuscated rather than encrypted, so read access is the whole of
        # the deployment account.
        $smb = & $script:newSmb

        [void] (New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -ShareName 'HDTShare$' `
                -ServerName 'LAP-AMMSO01' -Account 'LAP-AMMSO01\svc-hdt-deploy' `
                -SmbService $smb -Elevated $true -Confirm:$false)

        $smb.GetOperationName() | Should -Contain 'GrantShareAccess'
    }

    # THE OTHER HALF OF THE ACL. SMB gates the connection, NTFS gates the file,
    # and the effective right is the more restrictive of the two - so a share
    # permission on its own produces a share the deployment account can reach
    # and cannot read. Until this existed, HDT granted the first half and left
    # the second to three icacls lines in docs/share-account.md that nothing
    # ran, and Test-HDTShareAcl then reported the result as Critical.
    It 'grants NTFS read at the workspace root, not only the share permission' {
        $smb = & $script:newSmb
        $fs = New-HDTFakeFileSystem -Directory @('C:\HDTLab\Share', 'C:\HDTLab\Share\Logs', 'C:\HDTLab\Share\Captures')

        [void] (New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -ShareName 'HDTShare$' `
                -ServerName 'LAP-AMMSO01' -Account 'LAP-AMMSO01\svc-hdt-deploy' `
                -SmbService $smb -FileSystem $fs -Elevated $true -Confirm:$false)

        $grant = @($fs.Operations | Where-Object { $_.Operation -eq 'GrantAccess' })

        @($grant).Count | Should -Be 3
        [string] $grant[0].Arguments[0] | Should -BeExactly 'C:\HDTLab\Share'
        [string] $grant[0].Arguments[2] | Should -BeExactly 'Read'
    }

    # LOGS AND CAPTURES ARE THE ONLY TWO IT MAY WRITE TO, which is the posture
    # Test-HDTShareAcl judges: write anywhere else is a Warning, and the account
    # still has to send its logs home and land a capture.
    It 'grants modify on Logs and Captures, and nowhere else' {
        $smb = & $script:newSmb
        $fs = New-HDTFakeFileSystem -Directory @('C:\HDTLab\Share', 'C:\HDTLab\Share\Logs', 'C:\HDTLab\Share\Captures')

        [void] (New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -ShareName 'HDTShare$' `
                -ServerName 'LAP-AMMSO01' -Account 'LAP-AMMSO01\svc-hdt-deploy' `
                -SmbService $smb -FileSystem $fs -Elevated $true -Confirm:$false)

        $modify = @($fs.Operations |
                Where-Object { $_.Operation -eq 'GrantAccess' -and [string] $_.Arguments[2] -eq 'Modify' } |
                ForEach-Object { [string] $_.Arguments[0] })

        $modify | Should -Be @('C:\HDTLab\Share\Logs', 'C:\HDTLab\Share\Captures')
    }

    # NO ACCOUNT, NO GRANT - on either ACL. A share created with nobody named
    # reaches nobody until an administrator decides who, and writing an NTFS row
    # for an account nobody gave would be deciding that for them.
    It 'touches no ACL when it was given no account' {
        $smb = & $script:newSmb
        $fs = New-HDTFakeFileSystem -Directory @('C:\HDTLab\Share', 'C:\HDTLab\Share\Logs', 'C:\HDTLab\Share\Captures')

        [void] (New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -ShareName 'HDTShare$' `
                -ServerName 'LAP-AMMSO01' -SmbService $smb -FileSystem $fs -Elevated $true -Confirm:$false)

        $fs.GetOperationName() | Should -Not -Contain 'GrantAccess'
    }

    It 'grants nothing under -WhatIf' {
        $smb = & $script:newSmb
        $fs = New-HDTFakeFileSystem -Directory @('C:\HDTLab\Share', 'C:\HDTLab\Share\Logs', 'C:\HDTLab\Share\Captures')

        [void] (New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -ShareName 'HDTShare$' `
                -ServerName 'LAP-AMMSO01' -Account 'LAP-AMMSO01\svc-hdt-deploy' `
                -SmbService $smb -FileSystem $fs -Elevated $true -WhatIf)

        $fs.GetOperationName() | Should -Not -Contain 'GrantAccess'
    }

    It 'writes nothing under -WhatIf' {
        $smb = & $script:newSmb

        [void] (New-HDTWorkspaceShare -Path 'C:\HDTLab\Share' -ShareName 'HDTShare$' `
                -ServerName 'LAP-AMMSO01' -SmbService $smb -Elevated $true -WhatIf)

        $smb.GetOperationName() | Should -Not -Contain 'NewShare'
    }

    It 'refuses a share name that is not one, before it touches SMB' {
        $smb = & $script:newSmb

        { New-HDTWorkspaceShare -Path 'C:\ws' -ShareName 'Share name' -ServerName 'HOST' `
                -SmbService $smb -Elevated $true -Confirm:$false } | Should -Throw

        $smb.GetOperationName() | Should -Not -Contain 'NewShare'
    }

    It 'refuses without elevation, and says which console to reopen' {
        # WITHOUT THIS the failure is an access error from inside the SmbShare
        # module naming a CIM class, AFTER the folder has been written - so the
        # share is the only half missing and nothing says which half.
        $smb = & $script:newSmb
        $message = ''

        try {
            New-HDTWorkspaceShare -Path 'C:\ws' -ShareName 'HDTShare$' -ServerName 'HOST' `
                -SmbService $smb -Elevated $false -Confirm:$false
        } catch {
            $message = [string] $_.Exception.Message
        }

        $message | Should -BeLike '*administrator*'
        $smb.GetOperationName() | Should -Not -Contain 'NewShare'
    }

    It 'says that before it says anything about the name' {
        # "Reopen elevated" is the whole answer; a share name complaint on top
        # of it is noise, and the name may well be fine.
        $smb = & $script:newSmb
        $message = ''

        try {
            New-HDTWorkspaceShare -Path 'C:\ws' -ShareName 'not a share name' -ServerName 'HOST' `
                -SmbService $smb -Elevated $false -Confirm:$false
        } catch {
            $message = [string] $_.Exception.Message
        }

        $message | Should -BeLike '*administrator*'
    }

    It 'says what to do when the name is already a share on this machine' {
        # Not an exception from the SMB module about an object that exists: the
        # sentence has to say the name is taken and that the folder is fine.
        $smb = New-HDTFakeSmbService -ExistingShare @('HDTShare$')

        { New-HDTWorkspaceShare -Path 'C:\ws' -ShareName 'HDTShare$' -ServerName 'HOST' `
                -SmbService $smb -Elevated $true -Confirm:$false } | Should -Throw -ExpectedMessage '*already*'
    }
}
