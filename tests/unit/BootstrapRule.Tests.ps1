# ONE BOOT IMAGE, MANY SHARES - which is what MDT's Bootstrap.ini is for and
# what HDT could not do.
#
# MDT'S Bootstrap.ini IS NOT A SETTINGS FILE, IT IS A RULES FILE. ZTIGather runs
# it in WinPE BEFORE the share is connected, with the full priority engine:
#
#   [Settings]
#   Priority=DefaultGateway, Default
#   [DefaultGateway]
#   192.0.2.1=Site-A
#   [Site-A]
#   DeployRoot=\\SERVER-A\DeploymentShare$
#
# That is how one image serves many sites. HDT carried ONE deployRoot, baked
# into bootstrap.json verbatim, because rules.yaml lives ON the share and
# nothing in it can choose the share.
#
# THE SAME GRAMMAR, A SMALLER VOCABULARY. bootstrap-rules.yaml is a rules.yaml -
# same when:, same set:, same first-match-wins - so there is one rule language
# to learn rather than two. What it may SET is an allow-list, because it runs
# before there is a share, a workspace or a task sequence: a rule that set
# HDTComputerName here would be setting it from a file that cannot see the
# document that decides computer names.
#
# NO CREDENTIALS, DELIBERATELY, AND THAT IS A DIVERGENCE FROM MDT.
# Bootstrap.ini carries UserID and UserPassword in clear text and DESIGN 14
# lists that as one of MDT's known exposures that HDT narrows. The account
# stays in Control\share-credential.json, written by Set-HDTShareCredential.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:path = 'X:\HDT\bootstrap-rules.yaml'

    function Get-HDTTestBootstrapRule {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($Line -join "`r`n") }
        return Import-HDTBootstrapRuleDocument -Path $script:path -FileSystem $fs
    }

    # Two sites by gateway, and a fallback - MDT's Priority=DefaultGateway,
    # Default written as rules.
    $script:siteLine = [string[]] @(
        'schemaVersion: 1'
        'rules:'
        '  - name: Site A'
        '    when: { HDTDefaultGateway: "192.0.2.1" }'
        '    set:'
        '      HDTDeployRoot: \\SERVER-A\HdtShare'
        ''
        '  - name: Site B by MAC'
        '    when: { HDTMacAddress: "00:15:5D:*" }'
        '    set:'
        '      HDTDeployRoot: \\SERVER-B\HdtShare'
    )
}

Describe 'Import-HDTBootstrapRuleDocument' {

    It 'reads a document in the rules.yaml grammar' {
        $document = Get-HDTTestBootstrapRule -Line $script:siteLine

        $document.SchemaVersion | Should -Be 1
        @($document.Rule).Count | Should -Be 2
        @($document.Rule)[0].Name | Should -BeExactly 'Site A'
    }

    It 'accepts <Variable>, which is decided before there is a share' -ForEach @(
        @{ Variable = 'HDTDeployRoot' }
        @{ Variable = 'HDTUserId' }
        @{ Variable = 'HDTUserDomain' }
        @{ Variable = 'HDTUserPassword' }
    ) {
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Only'
            '    set:'
            ('      {0}: "value"' -f $Variable)
        )

        { Get-HDTTestBootstrapRule -Line $line } | Should -Not -Throw
    }


    It 'refuses <Variable>, which nothing here is early enough to affect' -ForEach @(
        @{ Variable = 'HDTSkipWizard' }
        @{ Variable = 'HDTKeyboardLocale' }
        @{ Variable = 'HDTUILanguage' }
    ) {
        # THE ORDER IN Start-HDTDeployment SETTLES IT, and two of these were on
        # the list because the comment beside them was wrong rather than because
        # anybody checked:
        #
        #   step 6   the address loop, the gather, AND the Welcome screen
        #   step 6b  this file
        #   step 10a the technician wizard
        #
        # The Welcome screen has already been drawn by the time this file is
        # read, so a locale set here cannot reach it. The technician wizard runs
        # long after the share is connected, so HDTSkipWizard belongs in
        # rules.yaml ON the share - which is also where MDT put SkipWizard.
        # MDT's Bootstrap.ini carries SkipBDDWelcome, which is the WELCOME
        # screen, and HDT's equivalents come from bootstrap.json rather than
        # from any rule: Get-HDTWizardSkip reads them at build time because the
        # screen runs before there is anything to resolve a rule against.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Too late'
            '    set:'
            ('      {0}: "value"' -f $Variable)
        )

        { Get-HDTTestBootstrapRule -Line $line } |
            Should -Throw -ExpectedMessage '*rules.yaml*'
    }

    It 'refuses one that belongs in rules.yaml, and says where it belongs' {
        # HDTComputerName is decided by the share's own rules; a bootstrap rule
        # setting it would be deciding it from a file that cannot see them.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Too early'
            '    set:'
            '      HDTComputerName: PC-1'
        )

        { Get-HDTTestBootstrapRule -Line $line } |
            Should -Throw -ExpectedMessage '*rules.yaml*'
    }

    It 'names the variable it refused, and the ones it would have taken' {
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Too early'
            '    set:'
            '      HDTTaskSequenceID: LAB-CLIENT'
        )

        { Get-HDTTestBootstrapRule -Line $line } |
            Should -Throw -ExpectedMessage '*HDTTaskSequenceID*'

        { Get-HDTTestBootstrapRule -Line $line } |
            Should -Throw -ExpectedMessage '*HDTDeployRoot*'
    }

    It 'takes the deployment account, because that is what Bootstrap.ini is for' {
        # MDT'S Bootstrap.ini CARRIES UserID, UserDomain AND UserPassword, and
        # one boot image serving many sites needs an account per site as much as
        # it needs a share per site - a rule that chose \\SERVER-B\Share and
        # left SERVER-A's account behind has chosen a share it cannot open.
        #
        # THE PASSWORD IS CLEAR TEXT IN THIS FILE. So is MDT's, and the file
        # travels inside the boot image; anybody holding the image already holds
        # the credential that was baked into it.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Site-B'
            '    set:'
            '      HDTDeployRoot: \\SERVER-B\HdtShare'
            '      HDTUserId: svc-deploy-b'
            '      HDTUserDomain: CONTOSO'
            '      HDTUserPassword: Passw0rd!'
        )

        $document = Get-HDTTestBootstrapRule -Line $line

        @($document.Rule).Count | Should -Be 1
    }

    It 'still refuses the DOMAIN JOIN account, which is a different animal' {
        # HDTDomainAdminPassword joins the machine to a domain, long after the
        # share is open. It belongs in rules.yaml ON the share, where the file
        # is not carried around inside a boot image.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Credentials'
            '    set:'
            '      HDTDomainAdminPassword: Passw0rd!'
        )

        { Get-HDTTestBootstrapRule -Line $line } | Should -Throw
    }

    It 'refuses a deploy root with one backslash, which is a UNC nobody can reach' {
        # FOUND ON THE LAB SHARE, WRITTEN BY HAND: '\192.168.2.29\HDTShare'
        # with a single leading slash. YAML is not to blame - a plain scalar
        # keeps both, and the double-quoted form throws on \S rather than
        # eating one - so it was typed, and nothing noticed.
        #
        # IT WOULD HAVE NOTICED AT THREE IN THE MORNING. The rule matches, WinPE
        # is handed a path that is not a UNC and not a local one either, and the
        # machine deploys from somewhere else or not at all. Refusing here is
        # refusing at the desk.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Lab'
            '    set:'
            '      HDTDeployRoot: \192.168.2.29\HDTShare'
        )

        { Get-HDTTestBootstrapRule -Line $line } | Should -Throw -ExpectedMessage '*192.168.2.29*'
    }

    It 'takes the shapes a machine can actually connect to: <_>' -ForEach @(
        '\\SERVER\HdtShare', '\\192.168.2.29\HDTShare', 'D:\HDTShare') {

        # A LOCAL PATH IS LEGAL: standalone media resolves its own drive, and a
        # variable is expanded before anybody looks at it.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Lab'
            '    set:'
            ('      HDTDeployRoot: {0}' -f $_)
        )

        { Get-HDTTestBootstrapRule -Line $line } | Should -Not -Throw
    }

    It 'refuses a setFrom rule, because there is no share to hold the script' {
        # setFrom names a path under Scripts\ ON THE SHARE. Before the share is
        # connected there is nothing to run, and the failure would be at three
        # in the morning on a machine nobody is watching.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Scripted'
            '    setFrom: Scripts\Get-Site.ps1'
        )

        { Get-HDTTestBootstrapRule -Line $line } |
            Should -Throw -ExpectedMessage '*setFrom*'
    }
}

Describe 'Resolve-HDTBootstrapRule' {

    BeforeAll {
        $script:document = Get-HDTTestBootstrapRule -Line $script:siteLine
    }

    It 'picks the share the gateway says' {
        $fact = [ordered] @{ HDTDefaultGateway = '192.0.2.1'; HDTMacAddress = '00:AA:BB:CC:DD:EE' }

        $answer = Resolve-HDTBootstrapRule -RuleDocument $script:document -Fact $fact `
            -DeployRoot '\\FALLBACK\HdtShare'

        $answer.DeployRoot | Should -BeExactly '\\SERVER-A\HdtShare'
        $answer.RuleName | Should -BeExactly 'Site A'
        $answer.Source | Should -BeExactly 'Rule'
    }

    It 'matches on the MAC the same way, which is MDT s second priority' {
        $fact = [ordered] @{ HDTDefaultGateway = '10.0.0.1'; HDTMacAddress = '00:15:5D:01:02:03' }

        $answer = Resolve-HDTBootstrapRule -RuleDocument $script:document -Fact $fact `
            -DeployRoot '\\FALLBACK\HdtShare'

        $answer.DeployRoot | Should -BeExactly '\\SERVER-B\HdtShare'
        $answer.RuleName | Should -BeExactly 'Site B by MAC'
    }

    It 'falls back to what the image was built with when no rule matches' {
        # MDT's [Default] DeployRoot. An image whose rules match nothing still
        # deploys, from the share it was built for.
        $fact = [ordered] @{ HDTDefaultGateway = '172.16.0.1'; HDTMacAddress = '00:AA:BB:CC:DD:EE' }

        $answer = Resolve-HDTBootstrapRule -RuleDocument $script:document -Fact $fact `
            -DeployRoot '\\FALLBACK\HdtShare'

        $answer.DeployRoot | Should -BeExactly '\\FALLBACK\HdtShare'
        $answer.Source | Should -BeExactly 'BootImage'
        $answer.RuleName | Should -BeExactly ''
    }

    It 'takes the first match, so the rules read top to bottom like every other' {
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: First'
            '    when: { HDTIsLaptop: true }'
            '    set:'
            '      HDTDeployRoot: \\FIRST\HdtShare'
            ''
            '  - name: Second'
            '    when: { HDTIsLaptop: true }'
            '    set:'
            '      HDTDeployRoot: \\SECOND\HdtShare'
        )

        $answer = Resolve-HDTBootstrapRule -RuleDocument (Get-HDTTestBootstrapRule -Line $line) `
            -Fact ([ordered] @{ HDTIsLaptop = $true }) -DeployRoot '\\FALLBACK\HdtShare'

        $answer.DeployRoot | Should -BeExactly '\\FIRST\HdtShare'
        $answer.RuleName | Should -BeExactly 'First'
    }

    It 'carries the other settings it resolved, so the caller can apply them' {
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Site with its own account'
            '    when: { HDTDefaultGateway: "192.0.2.1" }'
            '    set:'
            '      HDTDeployRoot: \\SERVER-A\HdtShare'
            '      HDTUserId: svc-hdt-a'
        )

        $answer = Resolve-HDTBootstrapRule -RuleDocument (Get-HDTTestBootstrapRule -Line $line) `
            -Fact ([ordered] @{ HDTDefaultGateway = '192.0.2.1' }) -DeployRoot '\\FALLBACK\HdtShare'

        $answer.Variable['HDTUserId'] | Should -BeExactly 'svc-hdt-a'
    }

    It 'accepts no document at all, because most images have none' {
        # An image built before this existed, or a share with one deployRoot.
        $answer = Resolve-HDTBootstrapRule -RuleDocument $null -Fact ([ordered] @{}) `
            -DeployRoot '\\FALLBACK\HdtShare'

        $answer.DeployRoot | Should -BeExactly '\\FALLBACK\HdtShare'
        $answer.Source | Should -BeExactly 'BootImage'
    }

    It 'expands a variable against the facts, like every other rule document' {
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Per model'
            '    set:'
            '      HDTDeployRoot: \\SERVER\%HDTModel%'
        )

        $answer = Resolve-HDTBootstrapRule -RuleDocument (Get-HDTTestBootstrapRule -Line $line) `
            -Fact ([ordered] @{ HDTModel = 'Latitude' }) -DeployRoot '\\FALLBACK\HdtShare'

        $answer.DeployRoot | Should -BeExactly '\\SERVER\Latitude'
    }
}

Describe 'the account a bootstrap rule chooses' {

    It 'comes back composed, so the payload builds a credential and decides nothing' {
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Site-B'
            '    when:'
            '      HDTDefaultGateway: 192.168.9.1'
            '    set:'
            '      HDTDeployRoot: \\SERVER-B\HdtShare'
            '      HDTUserId: svc-deploy-b'
            '      HDTUserDomain: CONTOSO'
            '      HDTUserPassword: Passw0rd!'
        )

        $chosen = Resolve-HDTBootstrapRule -RuleDocument (Get-HDTTestBootstrapRule -Line $line) `
            -Fact ([ordered] @{ HDTDefaultGateway = '192.168.9.1' }) -DeployRoot '\\SERVER-A\HdtShare'

        [string] $chosen.DeployRoot | Should -BeExactly '\\SERVER-B\HdtShare'
        [string] $chosen.UserName | Should -BeExactly 'CONTOSO\svc-deploy-b'
        [string] $chosen.Password | Should -BeExactly 'Passw0rd!'
        [string] $chosen.CredentialSource | Should -BeExactly 'Rule'
    }

    It 'leaves the account alone when the rules named none' {
        # A RULE THAT CHOSE ONLY A SHARE KEEPS THE IMAGE'S ACCOUNT. The
        # commonest site rule is one line, and it must not blank the credential
        # the image was built with.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Site-B'
            '    set:'
            '      HDTDeployRoot: \\SERVER-B\HdtShare'
        )

        $chosen = Resolve-HDTBootstrapRule -RuleDocument (Get-HDTTestBootstrapRule -Line $line) `
            -Fact ([ordered] @{}) -DeployRoot '\\SERVER-A\HdtShare'

        [string] $chosen.UserName | Should -BeNullOrEmpty
        [string] $chosen.CredentialSource | Should -BeExactly 'BootImage'
    }

    It 'takes a local account, with no domain in front of it' {
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Workgroup'
            '    set:'
            '      HDTUserId: svc-deploy'
            '      HDTUserPassword: Passw0rd!'
        )

        $chosen = Resolve-HDTBootstrapRule -RuleDocument (Get-HDTTestBootstrapRule -Line $line) `
            -Fact ([ordered] @{}) -DeployRoot '\\SERVER-A\HdtShare'

        [string] $chosen.UserName | Should -BeExactly 'svc-deploy'
    }

    It 'is in the map under MDT s own names' -ForEach @(
        @{ HDTName = 'HDTUserId'; MdtName = 'UserID' }
        @{ HDTName = 'HDTUserDomain'; MdtName = 'UserDomain' }
        @{ HDTName = 'HDTUserPassword'; MdtName = 'UserPassword' }) {

        $entry = @(Get-HDTVariableMap | Where-Object { $_.HDTName -eq $HDTName })

        $entry.Count | Should -Be 1
        [string] $entry[0].MdtName | Should -BeExactly $MdtName
    }
}

Describe 'the variable a bootstrap rule exists to set' {

    It 'is in the map, so the catalogue and Get-HDTVariableMap both name it' {
        $entry = @(Get-HDTVariableMap | Where-Object { $_.HDTName -eq 'HDTDeployRoot' })

        $entry.Count | Should -Be 1
        $entry[0].Writable | Should -BeTrue
        $entry[0].MdtName | Should -BeExactly 'DeployRoot'
    }

    It 'is not the engine-owned one, which is the RESOLVED root' {
        # _HDTDeployRoot is what the engine ended up using - a share, or a
        # folder on standalone media. HDTDeployRoot is what a rule ASKED for.
        @(Get-HDTVariableMap | Where-Object { $_.HDTName -eq '_HDTDeployRoot' }).Count | Should -Be 1
    }
}
