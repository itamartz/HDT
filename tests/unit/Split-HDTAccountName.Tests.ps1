# ONE BOX, TYPED THE WAY WINDOWS PROMPTS FOR IT.
#
# The Computer Details page asked for the join account in two boxes - the
# account and the domain it lives in - because that is how MDT's variables are
# shaped (DomainAdmin, DomainAdminDomain). A technician joining a domain does
# not think in two boxes: they think CORP\svc-hdt-join, which is what every
# Windows credential prompt has asked them for.
#
# THE FOURTH FIELD WAS NOT EARNING ITS PLACE. Get-HDTWizardCredential keeps
# UserDomain separate for a reason that is real THERE and absent here: for a
# SHARE, a blank domain means the account is LOCAL to the server, and a
# technician must be able to say that without knowing the convention is to type
# a server name where a domain goes. Joining a domain has no such case - blank
# can only mean the domain being joined - so the box was asking a question with
# one possible answer.
#
# THE VARIABLES DO NOT CHANGE. HDTDomainAdmin and HDTDomainAdminDomain are what
# DESIGN 4.5.3 uses and what MDT names; this splits one typed string into both,
# so the screen got simpler and nothing downstream had to.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Split-HDTAccountName' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Split-HDTAccountName' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'DOMAIN\user, which is what a technician types' {

        It 'takes the domain from the left of the backslash' {
            $split = Split-HDTAccountName -Name 'CORP\svc-hdt-join'

            [string] $split.Domain | Should -BeExactly 'CORP'
            [string] $split.User | Should -BeExactly 'svc-hdt-join'
        }

        It 'handles a fully qualified domain on the left' {
            $split = Split-HDTAccountName -Name 'corp.contoso.com\svc'

            [string] $split.Domain | Should -BeExactly 'corp.contoso.com'
            [string] $split.User | Should -BeExactly 'svc'
        }

        It 'keeps a backslash in the account name out of the domain' {
            # Nothing legitimate has two, but a paste can. The FIRST separator
            # is the domain boundary; everything after it is the account.
            $split = Split-HDTAccountName -Name 'CORP\team\svc'

            [string] $split.Domain | Should -BeExactly 'CORP'
            [string] $split.User | Should -BeExactly 'team\svc'
        }
    }

    Context 'user@domain, which is what the other half of the world types' {

        It 'takes the domain from the right of the at sign' {
            $split = Split-HDTAccountName -Name 'svc-hdt-join@corp.contoso.com'

            [string] $split.Domain | Should -BeExactly 'corp.contoso.com'
            [string] $split.User | Should -BeExactly 'svc-hdt-join'
        }

        It 'prefers the backslash when somehow given both' {
            # 'CORP\svc@corp.contoso.com' is not a form anything asks for, and
            # guessing the at sign would silently change which domain
            # authenticates the join.
            $split = Split-HDTAccountName -Name 'CORP\svc@corp.contoso.com'

            [string] $split.Domain | Should -BeExactly 'CORP'
            [string] $split.User | Should -BeExactly 'svc@corp.contoso.com'
        }
    }

    Context 'a bare account name' {

        It 'leaves the domain empty rather than inventing one' {
            # EMPTY MEANS THE DOMAIN BEING JOINED, and that is resolved where
            # the join happens - not guessed here, where the domain being joined
            # is not even in scope.
            $split = Split-HDTAccountName -Name 'svc-hdt-join'

            [string] $split.User | Should -BeExactly 'svc-hdt-join'
            [string] $split.Domain | Should -BeNullOrEmpty
        }
    }

    Context 'what a technician can type by accident' {

        It 'trims the whitespace around a pasted name' {
            $split = Split-HDTAccountName -Name '  CORP\svc  '

            [string] $split.Domain | Should -BeExactly 'CORP'
            [string] $split.User | Should -BeExactly 'svc'
        }

        It 'returns nothing at all for <_>' -ForEach @('', '   ', '\', '@') {
            $split = Split-HDTAccountName -Name $PSItem

            [string] $split.User | Should -BeNullOrEmpty
            [string] $split.Domain | Should -BeNullOrEmpty
        }

        It 'survives a trailing backslash with no account after it' {
            $split = Split-HDTAccountName -Name 'CORP\'

            [string] $split.Domain | Should -BeExactly 'CORP'
            [string] $split.User | Should -BeNullOrEmpty
        }

        It 'never returns the separator as part of either half' -ForEach @('CORP\svc', 'svc@corp.com') {
            $split = Split-HDTAccountName -Name $PSItem

            [string] $split.User | Should -Not -BeLike '*\*'
            [string] $split.Domain | Should -Not -BeLike '*\*'
        }
    }
}
