# DESIGN 6.3's mitigation, and the reason it is a command rather than a
# paragraph: "least privilege is the mitigation, and it is enforced, not just
# documented ... Update-HDTBootImage runs this check and warns loudly when the
# account is over-privileged - a domain admin credential in a boot image is a
# domain compromise, and that is the failure worth catching."
#
# THE EXPECTED POSTURE (DESIGN 2.1 and 6.3):
#
#   workspace root   Read only
#   Logs\            Write (or Modify)
#   Captures\        Write (or Modify)
#   everything else  no more than Read
#
# IT NEVER THROWS AND NEVER BLOCKS A BUILD. DESIGN 6.3 says warn. A share whose
# ACL cannot be read - a UNC the builder has no rights to - produces one
# Information finding saying so, not a failure: an admin whose boot image build
# died because the checker could not read an ACL would turn the checker off.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = '\\hdtserver\HdtShare'
    $script:identity = 'CONTOSO\svc-hdt-deploy'

    $script:rule = {
        param([string] $Identity, [string] $Rights, [string] $Type)

        return [pscustomobject] @{
            Identity    = $Identity
            Rights      = $Rights
            Type        = $Type
            IsInherited = $false
        }
    }

    # The posture DESIGN 6.3 describes, as the checker is given it.
    $script:compliantAccessRule = {
        $read = & $script:rule $script:identity 'ReadAndExecute, Synchronize' 'Allow'
        $write = & $script:rule $script:identity 'Modify, Synchronize' 'Allow'

        return @{
            '.'                = @($read)
            'TaskSequences'    = @($read)
            'OperatingSystems' = @($read)
            'Applications'     = @($read)
            'Drivers'          = @($read)
            'Boot'             = @($read)
            'Control'          = @($read)
            'Scripts'          = @($read)
            'Modules'          = @($read)
            'Logs'             = @($write)
            'Captures'         = @($write)
        }
    }
}

Describe 'Test-HDTShareAcl' {

    Context 'the posture DESIGN 6.3 describes' {

        It 'reports Compliant for the least-privilege posture DESIGN 6.3 describes' {
            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity `
                -AccessRule (& $script:compliantAccessRule)

            $result.Compliant | Should -BeTrue
            @($result.Finding | Where-Object { $_.Severity -ne 'Information' }).Count | Should -Be 0
        }

        It 'accepts Write as well as Modify on Logs' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Logs'] = @(& $script:rule $script:identity 'Write, Synchronize' 'Allow')

            (Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule).Compliant |
                Should -BeTrue
        }

        It 'matches the identity without its domain prefix' {
            $accessRule = & $script:compliantAccessRule

            (Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity 'svc-hdt-deploy' -AccessRule $accessRule).Compliant |
                Should -BeTrue
        }

        It 'ignores rules granted to somebody else' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Drivers'] = @(
                (& $script:rule $script:identity 'ReadAndExecute, Synchronize' 'Allow'),
                (& $script:rule 'BUILTIN\Administrators' 'FullControl' 'Allow'))

            # BUILTIN\Administrators has FullControl on very nearly every share
            # there has ever been. Judging it would make Compliant unreachable
            # and the checker ignorable.
            (Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule).Compliant |
                Should -BeTrue
        }
    }

    Context 'findings' {

        It 'reports FullControl anywhere as Critical' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Applications'] = @(& $script:rule $script:identity 'FullControl' 'Allow')

            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule

            $result.Compliant | Should -BeFalse
            $finding = @($result.Finding | Where-Object { $_.Severity -eq 'Critical' })
            $finding.Count | Should -Be 1
            $finding[0].Message | Should -BeLike '*FullControl*'
            $finding[0].Path | Should -BeLike '*Applications*'
        }

        It 'reports FullControl on Logs as Critical too' {
            # Logs\ is writable; it is not a place to hand out FullControl,
            # which carries ChangePermissions and TakeOwnership with it.
            $accessRule = & $script:compliantAccessRule
            $accessRule['Logs'] = @(& $script:rule $script:identity 'FullControl' 'Allow')

            (Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule).Compliant |
                Should -BeFalse
        }

        It 'reports write outside Logs and Captures as a Warning' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['OperatingSystems'] = @(& $script:rule $script:identity 'Modify, Synchronize' 'Allow')

            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule

            $result.Compliant | Should -BeFalse
            $finding = @($result.Finding | Where-Object { $_.Severity -eq 'Warning' })
            $finding.Count | Should -Be 1
            $finding[0].Path | Should -BeLike '*OperatingSystems*'
        }

        It 'reports write at the workspace root as a Warning' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['.'] = @(& $script:rule $script:identity 'Modify, Synchronize' 'Allow')

            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule

            @($result.Finding | Where-Object { $_.Severity -eq 'Warning' }).Count | Should -Be 1
        }

        It 'reports no read at the root as Critical' {
            # The deployment cannot work at all: this is not over-privilege, it
            # is a share the account cannot read.
            $accessRule = & $script:compliantAccessRule
            $accessRule['.'] = @()

            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule

            $result.Compliant | Should -BeFalse
            @($result.Finding | Where-Object { $_.Severity -eq 'Critical' -and $_.Message -like '*cannot read*' }).Count |
                Should -Be 1
        }

        It 'reports a missing root entry as Critical' {
            $accessRule = & $script:compliantAccessRule
            $accessRule.Remove('.')

            (Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule).Compliant |
                Should -BeFalse
        }

        It 'treats a Deny rule as granting nothing' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Applications'] = @(& $script:rule $script:identity 'FullControl' 'Deny')

            (Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule).Compliant |
                Should -BeTrue
        }

        It 'quotes the domain-admin sentence for an admin group' {
            $accessRule = & $script:compliantAccessRule
            $admin = & $script:rule 'CONTOSO\Domain Admins' 'ReadAndExecute, Synchronize' 'Allow'
            foreach ($key in @($accessRule.Keys)) { $accessRule[$key] = @($admin) }

            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity 'CONTOSO\Domain Admins' -AccessRule $accessRule

            $result.Compliant | Should -BeFalse
            $finding = @($result.Finding | Where-Object { $_.Severity -eq 'Critical' -and $_.Message -like '*domain compromise*' })
            $finding.Count | Should -Be 1
        }

        It 'names Enterprise Admins and Administrators too' {
            foreach ($group in @('CONTOSO\Enterprise Admins', 'BUILTIN\Administrators')) {
                $accessRule = & $script:compliantAccessRule
                $rule = & $script:rule $group 'ReadAndExecute, Synchronize' 'Allow'
                foreach ($key in @($accessRule.Keys)) { $accessRule[$key] = @($rule) }

                $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $group -AccessRule $accessRule

                $result.Compliant | Should -BeFalse -Because "$group in a boot image is a compromise"
            }
        }

        It 'sorts findings with Critical first' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['OperatingSystems'] = @(& $script:rule $script:identity 'Modify, Synchronize' 'Allow')
            $accessRule['Applications'] = @(& $script:rule $script:identity 'FullControl' 'Allow')
            $accessRule['Drivers'] = $null

            $severity = @((Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity `
                        -AccessRule $accessRule).Finding | ForEach-Object { $_.Severity })

            $severity[0] | Should -BeExactly 'Critical'
            $severity[-1] | Should -BeExactly 'Information'
        }
    }

    # THE SHAPE A CALLER ACTUALLY HANDS IT. Get-HDTShareAccessRule returns
    # `, ([psobject[]] ...)` - the unary comma that stops a one-row ACL
    # unrolling to a scalar - so `@(Get-HDTShareAccessRule -Path $root)` collects
    # ONE element that is itself the array of rows. Every hand-built fixture
    # above is flat and never saw it.
    #
    # THE FAILURE IT CAUSED WAS A FALSE CRITICAL, which is the worst kind. On a
    # share whose ACL was correct - svc-hdt-deploy:(OI)(CI)(RX) present and
    # readable - the nested row's Identity stringified to 'System.Object[]',
    # matched no account, and the checker reported "cannot read the workspace
    # root". That sends somebody to fix an ACL that was never broken.
    Context 'rows arriving nested, as @(Get-HDTShareAccessRule) hands them over' {

        BeforeAll {
            # A REAL ROOT ACL, CAPTURED FROM OSDTEST01 after New-HDTWorkspaceShare
            # published the share: the account's own grant plus the four rows
            # every folder under C:\ inherits. Several rows is what matters -
            # nesting ONE row still stringifies correctly through member
            # enumeration, which is why every fixture above missed this.
            $script:realRootRow = {
                return [psobject[]] @(
                    & $script:rule $script:identity 'ReadAndExecute, Synchronize' 'Allow'
                    & $script:rule 'BUILTIN\Administrators' 'FullControl' 'Allow'
                    & $script:rule 'NT AUTHORITY\SYSTEM' 'FullControl' 'Allow'
                    & $script:rule 'BUILTIN\Users' 'ReadAndExecute, Synchronize' 'Allow'
                    & $script:rule 'NT AUTHORITY\Authenticated Users' 'Modify, Synchronize' 'Allow'
                )
            }
        }

        It 'judges a compliant share compliant' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['.'] = @(, (& $script:realRootRow))

            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule

            $result.Compliant | Should -BeTrue -Because 'the account has ReadAndExecute at the root; only the shape of the rows changed'
        }

        It 'still finds FullControl through the nesting' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['.'] = @(, ([psobject[]] @(
                        & $script:rule $script:identity 'FullControl' 'Allow'
                        & $script:rule 'NT AUTHORITY\SYSTEM' 'FullControl' 'Allow'
                    )))

            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule

            @($result.Finding | Where-Object { $_.Severity -eq 'Critical' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'an ACL it could not read' {

        It 'never throws for an unreadable ACL' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Captures'] = $null

            { Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule } |
                Should -Not -Throw
        }

        It 'returns an Information finding when it could not read' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Captures'] = $null

            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule

            $finding = @($result.Finding | Where-Object { $_.Severity -eq 'Information' })
            $finding.Count | Should -Be 1
            $finding[0].Path | Should -BeLike '*Captures*'
        }

        It 'stays Compliant when the only finding is Information' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Captures'] = $null

            (Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule $accessRule).Compliant |
                Should -BeTrue
        }

        It 'never throws for an empty access rule table' {
            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity -AccessRule @{}

            $result.Compliant | Should -BeFalse

            # Asserted on the finding rather than on a count: SPIKES S9.15b -
            # @($null).Count is 1, so a count alone passes for a result that
            # carried no findings at all.
            @($result.Finding | ForEach-Object { $_.Severity }) | Should -Contain 'Critical'
        }
    }

    Context 'the result shape' {

        It 'returns Compliant and Finding' {
            $result = Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity `
                -AccessRule (& $script:compliantAccessRule)

            @($result.PSObject.Properties.Name) | Should -Contain 'Compliant'
            @($result.PSObject.Properties.Name) | Should -Contain 'Finding'
            $result.Compliant | Should -BeOfType ([bool])
        }

        It 'gives every finding a Path, a Severity and a Message' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Applications'] = @(& $script:rule $script:identity 'FullControl' 'Allow')

            foreach ($finding in @((Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity `
                            -AccessRule $accessRule).Finding)) {

                $finding.Path | Should -Not -BeNullOrEmpty
                $finding.Severity | Should -BeIn @('Critical', 'Warning', 'Information')
                $finding.Message | Should -Not -BeNullOrEmpty
            }
        }

        It 'names the workspace path in a finding, not the folder key' {
            $accessRule = & $script:compliantAccessRule
            $accessRule['Applications'] = @(& $script:rule $script:identity 'FullControl' 'Allow')

            $finding = @((Test-HDTShareAcl -WorkspaceRoot $script:workspaceRoot -Identity $script:identity `
                        -AccessRule $accessRule).Finding | Where-Object { $_.Path -like '*Applications*' })

            $finding[0].Path | Should -BeExactly '\\hdtserver\HdtShare\Applications'
        }
    }

    Context 'the document DESIGN 6.3 promises' {

        BeforeAll {
            $script:documentPath = Join-Path -Path $script:repoRoot -ChildPath 'docs/share-account.md'
            $script:document = Get-Content -LiteralPath $script:documentPath -Raw

            # The layout the checker judges, read from the one place it is
            # written down (DESIGN 2.1, as Get-HDTWorkspacePath's closed set), so
            # the document and the code cannot drift apart without this going
            # red.
            $script:folder = @((Get-Command Get-HDTWorkspacePath).Parameters['Kind'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                    ForEach-Object { $_.ValidValues })
        }

        It 'exists' {
            Test-Path -LiteralPath $script:documentPath | Should -BeTrue
        }

        It 'names every folder the checker judges' {
            foreach ($name in $script:folder) {
                $script:document | Should -BeLike ('*{0}*' -f $name) -Because "the ACL table has to name $name"
            }
        }

        It 'names the two folders the account may write to' {
            $script:document | Should -BeLike '*Logs*'
            $script:document | Should -BeLike '*Captures*'
        }

        It 'says the stored secret is obfuscation and not security' {
            $script:document | Should -BeLike '*obfuscation*'
        }

        It 'says the boot media carries the password' {
            $script:document | Should -BeLike '*boot media*'
        }

        It 'names Set-HDTShareCredential and Test-HDTShareAcl' {
            $script:document | Should -BeLike '*Set-HDTShareCredential*'
            $script:document | Should -BeLike '*Test-HDTShareAcl*'
        }

        It 'gives the -PromptForCredential option for a build going offsite' {
            $script:document | Should -BeLike '*PromptForCredential*'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Test-HDTShareAcl -ErrorAction Stop

            $help.Name | Should -BeExactly 'Test-HDTShareAcl'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help on the adapter that reads the ACL' {
            $help = Get-Help -Name Get-HDTShareAccessRule -ErrorAction Stop

            $help.Name | Should -BeExactly 'Get-HDTShareAccessRule'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
