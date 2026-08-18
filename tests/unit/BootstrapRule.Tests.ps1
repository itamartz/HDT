# ONE BOOT IMAGE, MANY SHARES - which is what MDT's Bootstrap.ini is for and
# what HDT could not do.
#
# MDT'S Bootstrap.ini IS NOT A SETTINGS FILE, IT IS A RULES FILE. ZTIGather runs
# it in WinPE BEFORE the share is connected, with the full priority engine:
#
#   [Settings]
#   Priority=DefaultGateway, Default
#   [DefaultGateway]
#   192.168.2.1=Site-A
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
        '    when: { HDTDefaultGateway: "192.168.2.1" }'
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
        @{ Variable = 'HDTSkipWizard' }
        @{ Variable = 'HDTKeyboardLocale' }
        @{ Variable = 'HDTUILanguage' }
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

    It 'refuses a password, which is where MDT and HDT part company' {
        # Bootstrap.ini carries UserID and UserPassword in clear text. The
        # account lives in Control\share-credential.json here, and the message
        # has to say so rather than just refusing an unknown name.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Credentials'
            '    set:'
            '      HDTDomainAdminPassword: Passw0rd!'
        )

        { Get-HDTTestBootstrapRule -Line $line } |
            Should -Throw -ExpectedMessage '*Set-HDTShareCredential*'
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
        $fact = [ordered] @{ HDTDefaultGateway = '192.168.2.1'; HDTMacAddress = '00:AA:BB:CC:DD:EE' }

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
            '  - name: Unattended site'
            '    when: { HDTDefaultGateway: "192.168.2.1" }'
            '    set:'
            '      HDTDeployRoot: \\SERVER-A\HdtShare'
            '      HDTSkipWizard: true'
        )

        $answer = Resolve-HDTBootstrapRule -RuleDocument (Get-HDTTestBootstrapRule -Line $line) `
            -Fact ([ordered] @{ HDTDefaultGateway = '192.168.2.1' }) -DeployRoot '\\FALLBACK\HdtShare'

        $answer.Variable['HDTSkipWizard'] | Should -Be $true
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
