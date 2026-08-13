# THE ONE PLACE A PROVIDER NAME BECOMES A PROVIDER.
#
# A two-branch factory and nothing else, so the WinPE entry point does not carry
# a switch of its own and DESIGN 6's future Http transport lands in one file
# rather than in every caller.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = '\\hdtserver\HdtShare'

    # A character at a time rather than ConvertTo-SecureString -AsPlainText,
    # which PSScriptAnalyzer refuses outright.
    $script:newCredential = {
        param([string] $UserName, [string] $Plain)

        $secure = New-Object System.Security.SecureString
        foreach ($character in $Plain.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()

        return (New-Object System.Management.Automation.PSCredential $UserName, $secure)
    }

    $script:row = {
        param([string] $UserName)

        return [pscustomobject] @{
            ServerName = 'hdtserver'
            ShareName  = 'HdtShare'
            UserName   = $UserName
            Dialect    = '3.1.1'
            Encrypted  = $true
            Signed     = $true
        }
    }

    $script:errorOf = {
        param([scriptblock] $Action)

        $record = $null
        try { & $Action } catch { $record = $_ }

        return $record
    }
}

Describe 'New-HDTContentProvider' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -Directory @('E:\HDTMedia')
        $script:credential = & $script:newCredential 'CONTOSO\svc-hdt-deploy' 'P@ssw0rd-not-in-a-log'
    }

    It 'builds a Local provider for Local' {
        $provider = New-HDTContentProvider -Provider Local -Root 'E:\HDTMedia' -FileSystem $script:fileSystem

        $provider.Root | Should -BeExactly 'E:\HDTMedia'
        $provider.ServiceName | Should -BeExactly 'ContentProvider'
        $provider.Connect() | Should -BeExactly 'E:\HDTMedia'

        # Local reaches the disk directly: no mapping, and nothing to map with.
        $script:fileSystem.GetOperationName() | Should -Contain 'TestPath'
    }

    It 'builds an Smb provider for Smb' {
        $smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy')

        $provider = New-HDTContentProvider -Provider Smb -Root $script:root `
            -Credential $script:credential -SmbService $smb -FileSystem $script:fileSystem

        $provider.Root | Should -BeExactly $script:root
        $provider.ServiceName | Should -BeExactly 'ContentProvider'

        $provider.Connect() | Should -BeExactly $script:root
        @($smb.GetOperationName()) | Should -Contain 'NewMapping'
    }

    It 'exposes the same five members whichever it built' {
        # DESIGN 6.2: media generation is "a content projection plus a provider
        # swap, not a parallel code path". A step never branches on transport,
        # so neither may a caller of this factory.
        $smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy')

        $local = New-HDTContentProvider -Provider Local -Root 'E:\HDTMedia' -FileSystem $script:fileSystem
        $remote = New-HDTContentProvider -Provider Smb -Root $script:root `
            -Credential $script:credential -SmbService $smb -FileSystem $script:fileSystem

        foreach ($provider in @($local, $remote)) {
            # Get-Member -MemberType Method does NOT list a ScriptMethod
            # (tests/helpers/README.md F2).
            $member = @($provider | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('ResolveContent', 'TestContent', 'CopyContent', 'Connect', 'Disconnect')) {
                $member | Should -Contain $name
            }
        }
    }

    It 'passes the credential to the Smb provider' {
        $smb = New-HDTFakeSmbService -Connection @(& $script:row 'CONTOSO\svc-hdt-deploy')

        $provider = New-HDTContentProvider -Provider Smb -Root $script:root `
            -Credential $script:credential -SmbService $smb -FileSystem $script:fileSystem

        $null = $provider.Connect()

        $mapping = @($smb.Operations | Where-Object { $_.Operation -eq 'NewMapping' })[0]

        [string] $mapping.Arguments[0] | Should -BeExactly $script:root
        [string] $mapping.Arguments[1] | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
    }

    It 'passes -AllowAnonymous through to the Smb provider' {
        $smb = New-HDTFakeSmbService -Connection @(& $script:row 'HDTSERVER\itamartz')

        $provider = New-HDTContentProvider -Provider Smb -Root $script:root -AllowAnonymous `
            -SmbService $smb -FileSystem $script:fileSystem

        $provider.Connect() | Should -BeExactly $script:root
    }

    It 'passes the shared journal through to the provider it builds' {
        $journal = [System.Collections.ArrayList]::new()

        $provider = New-HDTContentProvider -Provider Local -Root 'E:\HDTMedia' `
            -FileSystem $script:fileSystem -Journal $journal

        $null = $provider.Connect()

        @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
            Should -Contain 'ContentProvider.Connect'
    }

    It 'refuses an unknown provider name' {
        $record = & $script:errorOf { New-HDTContentProvider -Provider 'CarrierPigeon' -Root 'E:\HDTMedia' }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        $record.Exception.Message | Should -BeLike '*CarrierPigeon*'
        $record.Exception.Message | Should -BeLike '*Smb*'
        $record.Exception.Message | Should -BeLike '*Local*'
    }

    It 'names Http as not implemented in v1' {
        # DESIGN 6 says the interface exists SO THAT a cloud transport can land
        # later. A caller asking for it deserves that sentence, not "unknown".
        $record = & $script:errorOf { New-HDTContentProvider -Provider Http -Root 'https://hdt.contoso.com/share' }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        $record.Exception.Message | Should -BeLike '*Http*'
        $record.Exception.Message | Should -BeLike '*v1*'
    }

    It 'is exported with comment-based help' {
        $help = Get-Help -Name New-HDTContentProvider -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTContentProvider'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'is a factory and nothing else' {
        # Two branches, and no third. The whole reason this file exists is so a
        # payload does not carry a switch; a factory that grew resolution logic
        # of its own would put the decision back in two places.
        $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/New-HDTContentProvider.ps1'
        $text = Get-Content -LiteralPath $path -Raw

        $text | Should -BeLike '*New-HDTLocalContentProvider*'
        $text | Should -BeLike '*New-HDTSmbContentProvider*'
        $text | Should -Not -BeLike '*New-HDTFake*'
    }
}
