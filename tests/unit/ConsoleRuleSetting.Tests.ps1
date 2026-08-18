# THE RULES TAB, worked out without a window.
#
# MDT PUT CustomSettings.ini ON THE DEPLOYMENT SHARE'S PROPERTIES, in a tab
# called Rules, as text you edit in place. HDT's equivalent is rules.yaml and it
# goes in the same place, on the window that is Deployment Workbench's share
# Properties - because that is where an MDT administrator will look for it.
#
# TEXT, NOT A GRID, AND THAT IS THE HOMAGE. Add-HDTRule, Set-HDTRule and
# Remove-HDTRule exist and a grid could be built on them, but rules.yaml is
# read top to bottom with first match winning per variable, so ORDER and the
# comments explaining it are the document's meaning. MDT admins edit this file
# as text; a grid would hide the one thing they are reasoning about.
#
# IT VALIDATES BEFORE IT SAVES, which the .ini never could. Assert-HDTRuleLine
# is the same gate Add-HDTRule passes through, so a document the engine will
# refuse in WinPE is refused here, at the desk, with the same sentence.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:rulesText = @'
# The lab rules.
schemaVersion: 1
rules:
  - name: Lab subnet
    when: { HDTDefaultGateway: "10.20.30.1" }
    set:
      HDTJoinDomain: lab.contoso.com

  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTSerialNumber%"
'@

    $script:rulesLine = [string[]] @($script:rulesText -split "`r?`n")
    $script:rulesPath = 'C:\HDTLab\Share\rules.yaml'
}

Describe 'Get-HDTConsoleRuleSetting' {

    Context 'a document the engine accepts' {

        BeforeAll {
            $script:setting = Get-HDTConsoleRuleSetting -Line $script:rulesLine -Path $script:rulesPath
        }

        It 'hands the editor the whole file, in order' {
            # Every line, including the comment header and the blank line
            # between the rules: this is a text editor, and a round trip that
            # loses either has eaten the administrator's own notes.
            $script:setting.Text | Should -BeExactly ($script:rulesLine -join "`r`n")
        }

        It 'carries the path it will write back to' {
            $script:setting.Path | Should -BeExactly $script:rulesPath
        }

        It 'names the rules the document declares, in document order' {
            @($script:setting.RuleName) | Should -Be @('Lab subnet', 'Fallback')
        }

        It 'summarises what is in the file' {
            $script:setting.SummaryText | Should -BeExactly '2 rules'
        }

        It 'reports no problem' {
            $script:setting.Problem | Should -BeExactly ''
            $script:setting.IsValid | Should -BeTrue
        }

        It 'saves through the command, not through a file handle of its own' {
            $script:setting.SaveCommand | Should -BeExactly ("Save-HDTRuleDocument -Path '{0}' -Line `$line" -f $script:rulesPath)
        }
    }

    Context 'a document the engine refuses' {

        BeforeAll {
            # A variable that is not named HDTSomething - one of the rules
            # Assert-HDTRuleLine enforces, and one an .ini could never catch.
            $script:badLine = [string[]] @(
                'schemaVersion: 1'
                'rules:'
                '  - name: Broken'
                '    set:'
                '      ComputerName: PC-1'
            )

            $script:bad = Get-HDTConsoleRuleSetting -Line $script:badLine -Path $script:rulesPath
        }

        It 'does not throw, because the window has to show the text either way' {
            # A tab that throws on open leaves an administrator with a file they
            # cannot see and cannot fix.
            $script:bad | Should -Not -BeNullOrEmpty
            $script:bad.Text | Should -BeLike '*ComputerName: PC-1*'
        }

        It 'says so, in the engine s own words' {
            $script:bad.IsValid | Should -BeFalse
            $script:bad.Problem | Should -Not -BeNullOrEmpty
            $script:bad.Problem | Should -BeLike '*ComputerName*'
        }

        It 'still offers the path, so the tab can be reloaded' {
            $script:bad.Path | Should -BeExactly $script:rulesPath
        }
    }

    Context 'a share with no rules.yaml yet' {

        It 'is not an error, and offers the header a new document needs' {
            # New-HDTWorkspace writes one, but a share can be assembled by hand
            # and the tab is where somebody would notice.
            $setting = Get-HDTConsoleRuleSetting -Line @() -Path $script:rulesPath

            $setting.IsValid | Should -BeFalse
            $setting.SummaryText | Should -BeLike '*no rules*'
        }
    }
}

Describe 'Get-HDTConsoleRuleSetting -Bootstrap' {

    # THE SAME TAB, A SMALLER VOCABULARY. bootstrap-rules.yaml is a rules.yaml
    # that runs before there is a share, so the editor is the same editor - and
    # the judgement is the one Update-HDTBootImage will make when it injects it,
    # rather than a second opinion the window invented.

    BeforeAll {
        $script:bootstrapPath = 'C:\HDTLab\Shareootstrap-rules.yaml'

        $script:bootstrapLine = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Site A'
            '    when: { HDTDefaultGateway: "192.168.2.1" }'
            '    set:'
            '      HDTDeployRoot: \\SERVER-A\HdtShare'
        )
    }

    It 'accepts a document that only chooses a share' {
        $setting = Get-HDTConsoleRuleSetting -Line $script:bootstrapLine -Path $script:bootstrapPath -Bootstrap

        $setting.IsValid | Should -BeTrue
        $setting.Problem | Should -BeExactly ''
        @($setting.RuleName) | Should -Be @('Site A')
    }

    It 'refuses what the same document would be allowed in rules.yaml' {
        # A set: this file cannot act on does nothing, silently, on a machine at
        # three in the morning - so the window says so while somebody is here.
        $line = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Too early'
            '    set:'
            '      HDTComputerName: PC-1'
        )

        $bootstrap = Get-HDTConsoleRuleSetting -Line $line -Path $script:bootstrapPath -Bootstrap
        $plain = Get-HDTConsoleRuleSetting -Line $line -Path 'C:\HDTLab\Share
ules.yaml'

        $bootstrap.IsValid | Should -BeFalse
        $bootstrap.Problem | Should -BeLike '*rules.yaml*'

        $plain.IsValid | Should -BeTrue
    }

    It 'still does not throw, so the tab can show a broken file' {
        $line = [string[]] @('schemaVersion: 1', 'rules:', '  - name: Bad', '    set:', '      HDTComputerName: X')

        { Get-HDTConsoleRuleSetting -Line $line -Path $script:bootstrapPath -Bootstrap } | Should -Not -Throw
    }

    It 'says what an empty one is for' {
        $setting = Get-HDTConsoleRuleSetting -Line @() -Path $script:bootstrapPath -Bootstrap

        $setting.SummaryText | Should -BeLike '*no rules*'
    }
}
