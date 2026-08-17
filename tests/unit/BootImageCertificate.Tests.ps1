# CERTIFICATES IN THE BOOT IMAGE, which is the half of a PKI network WinPE
# cannot do without.
#
# A ROOT CA IS WHY AN HTTPS ENDPOINT IS TRUSTED. An internal CA is trusted by
# every domain-joined machine and by nothing that has just booted a WIM: WinPE
# starts with Microsoft's own root store and nothing else in it.
#
# A CLIENT CERTIFICATE IS WHY THE PORT OPENS AT ALL. A switch port under 802.1X
# authenticates the machine before it hands out a lease, and a machine in WinPE
# has no domain identity to authenticate with - which is why MDT and ConfigMgr
# both grew a way to put one in the boot media. Without it the image boots, gets
# no address, and looks like a broken share.
#
# THE TWO ARE DIFFERENT FILES IN DIFFERENT STORES and the commands keep them
# apart: a .cer is a public certificate and goes to Root, a .pfx carries a
# private key and goes to My. Putting a .pfx in the root list would install a
# private key into the trusted root store of every machine that boots the image.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:plainText = @'
schemaVersion: 1
id: HDT-LAB
name: lab share
deployRoot: \\HDT-HOST\HdtShare
bootImage:
  name: HDTPE_x64
  architecture: amd64
'@

    $script:certText = @'
schemaVersion: 1
id: HDT-LAB
name: lab share
deployRoot: \\HDT-HOST\HdtShare
bootImage:
  name: HDTPE_x64
  architecture: amd64
  rootCertificates:
    - Certs\contoso-root.cer
    - Certs\contoso-issuing.cer
  clientCertificate: Certs\winpe-802.1x.pfx
'@

    # A SecureString A CHARACTER AT A TIME, which is what New-HDTContentProvider's
    # suite does and for the same reason: ConvertTo-SecureString -AsPlainText is
    # an analyzer Error, and a suppression on a scriptblock's param block does
    # not reach the call inside it. This needs no suppression at all.
    $script:newSecret = {
        param([string] $Text = 'pfx-secret')

        $secure = New-Object -TypeName System.Security.SecureString
        foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()

        return $secure
    }

    $script:plain = [string[]] @($script:plainText -split "`r?`n")
    $script:declared = [string[]] @($script:certText -split "`r?`n")
}

Describe 'the document' {

    It 'reads the root certificates it declares' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:certText }
        $document = Import-HDTWorkspaceDocument -Path 'C:\ws\workspace.yaml' -FileSystem $fs

        @($document.BootImage.RootCertificate).Count | Should -Be 2
        [string] @($document.BootImage.RootCertificate)[0] | Should -BeExactly 'Certs\contoso-root.cer'
    }

    It 'reads the client certificate it declares' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:certText }
        $document = Import-HDTWorkspaceDocument -Path 'C:\ws\workspace.yaml' -FileSystem $fs

        [string] $document.BootImage.ClientCertificate | Should -BeExactly 'Certs\winpe-802.1x.pfx'
    }

    It 'answers empty for a share that declares neither' {
        # SILENCE IS AN ANSWER, and it is the ordinary one. An image built
        # without certificates is the image most shops build.
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:plainText }
        $document = Import-HDTWorkspaceDocument -Path 'C:\ws\workspace.yaml' -FileSystem $fs

        @($document.BootImage.RootCertificate).Count | Should -Be 0
        [string] $document.BootImage.ClientCertificate | Should -BeExactly ''
    }

    It 'refuses a .pfx in the root list' {
        # THE PRIVATE KEY WOULD GO INTO THE TRUSTED ROOT STORE of every machine
        # that boots the image, which is not a thing anybody asks for on purpose.
        $text = $script:plainText + "`n  rootCertificates:`n    - Certs\winpe.pfx"
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $text }

        { Import-HDTWorkspaceDocument -Path 'C:\ws\workspace.yaml' -FileSystem $fs } |
            Should -Throw '*clientCertificate*'
    }

    It 'refuses a client certificate that is not a .pfx' {
        # A .cer HAS NO PRIVATE KEY, so a machine holding one cannot prove
        # anything with it - and an 802.1X port stays shut.
        $text = $script:plainText + "`n  clientCertificate: Certs\public.cer"
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $text }

        { Import-HDTWorkspaceDocument -Path 'C:\ws\workspace.yaml' -FileSystem $fs } |
            Should -Throw '*private key*'
    }
}

Describe 'Add-HDTBootImageCertificate' {

    It 'declares a root certificate on a document that had none' {
        $result = Add-HDTBootImageCertificate -Line $script:plain -Path 'Certs\contoso-root.cer' -Confirm:$false

        ($result -join "`n") | Should -BeLike '*rootCertificates:*'
        ($result -join "`n") | Should -BeLike '*Certs\contoso-root.cer*'
    }

    It 'appends to a list that is already there' {
        $result = Add-HDTBootImageCertificate -Line $script:declared -Path 'Certs\partner.cer' -Confirm:$false

        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = ($result -join "`n") }
        $document = Import-HDTWorkspaceDocument -Path 'C:\ws\workspace.yaml' -FileSystem $fs

        @($document.BootImage.RootCertificate).Count | Should -Be 3
    }

    It 'keeps every other line byte-identical' {
        # THE DOCUMENT IS HAND-EDITED AND COMMENTED. A parse-and-re-emit loses
        # the comments, which is why nothing here re-serialises.
        $result = Add-HDTBootImageCertificate -Line $script:declared -Path 'Certs\partner.cer' -Confirm:$false

        foreach ($original in $script:declared) {
            if ([string]::IsNullOrWhiteSpace($original)) { continue }
            @($result) | Should -Contain $original
        }
    }

    It 'refuses the same certificate twice' {
        { Add-HDTBootImageCertificate -Line $script:declared -Path 'Certs\contoso-root.cer' -Confirm:$false } |
            Should -Throw '*already*'
    }

    It 'refuses a .pfx' {
        { Add-HDTBootImageCertificate -Line $script:plain -Path 'Certs\winpe.pfx' -Confirm:$false } |
            Should -Throw '*Set-HDTBootImageClientCertificate*'
    }

    It 'changes nothing under -WhatIf' {
        $result = Add-HDTBootImageCertificate -Line $script:plain -Path 'Certs\contoso-root.cer' -WhatIf

        ($result -join "`n") | Should -Not -BeLike '*rootCertificates*'
    }
}

Describe 'Remove-HDTBootImageCertificate' {

    It 'takes one out and leaves the other' {
        $result = Remove-HDTBootImageCertificate -Line $script:declared -Path 'Certs\contoso-root.cer' -Confirm:$false

        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = ($result -join "`n") }
        $document = Import-HDTWorkspaceDocument -Path 'C:\ws\workspace.yaml' -FileSystem $fs

        @($document.BootImage.RootCertificate).Count | Should -Be 1
        [string] @($document.BootImage.RootCertificate)[0] | Should -BeExactly 'Certs\contoso-issuing.cer'
    }

    It 'takes the key away with the last entry' {
        # AN EMPTY LIST IS A DOCUMENT SAYING "there are certificates" AND NAMING
        # NONE, which the validator refuses.
        $result = Remove-HDTBootImageCertificate -Line $script:declared -Path 'Certs\contoso-root.cer' -Confirm:$false
        $result = Remove-HDTBootImageCertificate -Line $result -Path 'Certs\contoso-issuing.cer' -Confirm:$false

        ($result -join "`n") | Should -Not -BeLike '*rootCertificates*'
    }

    It 'refuses one the document does not declare' {
        { Remove-HDTBootImageCertificate -Line $script:declared -Path 'Certs\nobody.cer' -Confirm:$false } |
            Should -Throw '*does not*'
    }
}

Describe 'Set-HDTBootImageClientCertificate' {

    It 'names the .pfx' {
        $result = Set-HDTBootImageClientCertificate -Line $script:plain -Path 'Certs\winpe.pfx' -Confirm:$false

        ($result -join "`n") | Should -BeLike '*clientCertificate: Certs\winpe.pfx*'
    }

    It 'replaces one that is already named' {
        $result = Set-HDTBootImageClientCertificate -Line $script:declared -Path 'Certs\new.pfx' -Confirm:$false

        ($result -join "`n") | Should -BeLike '*clientCertificate: Certs\new.pfx*'
        ($result -join "`n") | Should -Not -BeLike '*802.1x.pfx*'
    }

    It 'takes it away with -Clear' {
        $result = Set-HDTBootImageClientCertificate -Line $script:declared -Clear -Confirm:$false

        ($result -join "`n") | Should -Not -BeLike '*clientCertificate*'
    }

    It 'refuses anything but a .pfx' {
        { Set-HDTBootImageClientCertificate -Line $script:plain -Path 'Certs\public.cer' -Confirm:$false } |
            Should -Throw '*private key*'
    }
}

Describe 'Set-HDTBootImageCertificatePassword' {

    # THE ONE VALUE THAT CANNOT GO IN workspace.yaml. A .pfx password in the
    # document an administrator commits is a private key's password in git, so
    # it is written where the share credential's is - and obfuscated the same
    # way, with the same warning saying that obfuscation is not security.

    It 'writes the password to the Control folder, not to workspace.yaml' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:certText }

        Set-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\ws' `
            -Password (& $script:newSecret) `
            -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\ws\Control\certificate-password.json') | Should -BeTrue
    }

    It 'stores it obfuscated rather than in plain text' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:certText }

        Set-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\ws' `
            -Password (& $script:newSecret) `
            -FileSystem $fs -Confirm:$false

        $text = [string] $fs.ReadAllText('C:\ws\Control\certificate-password.json')

        $text | Should -Not -BeLike '*pfx-secret*'
        $text | Should -BeLike '*warning*'
    }

    It 'reads back what was written' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:certText }

        Set-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\ws' `
            -Password (& $script:newSecret) `
            -FileSystem $fs -Confirm:$false

        [string] (Get-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\ws' -FileSystem $fs) |
            Should -BeExactly 'pfx-secret'
    }

    It 'answers empty when none was ever written' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:certText }

        [string] (Get-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\ws' -FileSystem $fs) |
            Should -BeExactly ''
    }

    It 'refuses an empty password' {
        # A .pfx WITH NO PASSWORD IS ONE THAT WILL NOT IMPORT. Storing an empty
        # one produces a build that succeeds and a boot that has no identity.
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:certText }

        { Set-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\ws' `
                -Password (New-Object -TypeName System.Security.SecureString) `
                -FileSystem $fs -Confirm:$false } | Should -Throw '*empty*'
    }
}
