# Authoring rules.yaml from a command, the way sequence.yaml is authored.
#
# RULES.YAML IS HAND-EDITED FROM THE DAY IT IS WRITTEN. New-HDTWorkspace creates
# it with a comment header carrying a worked conditional example, and an
# administrator adds their own explanation beside every rule they add. A parse
# and re-emit hands back a correct document and none of that - so these commands
# splice LINES, and every line they were not asked to change comes back
# byte-identical.
#
# ORDER IS SEMANTICS HERE, NOT LAYOUT. rules.yaml is one of five variable
# sources and a set: value only takes effect if that variable is not already
# resolved, so first match wins per variable and the rules at the bottom act as
# fallbacks. Add-HDTRule therefore has to let the caller say WHERE, and the
# default has to be the end - the position that cannot shadow a rule that is
# already there.
#
# SAVE IS THE ONLY COMMAND THAT TOUCHES THE SHARE, and it hands the spliced text
# to the engine's own reader before a byte is written.
#
# EVERY EDIT IS RUN TWICE, OVER BOTH SHAPES A RULES DOCUMENT LEGALLY HAS. YAML
# lets a block sequence sit at its parent's indentation or one level in, so
# `rules:` may be followed by `- name:` at column zero or by `  - name:`
# indented. The hand-written samples in this repository are all indented; the
# serialiser ConvertTo-HDTYaml, which New-HDTWorkspace writes the FIRST
# rules.yaml of every share with, emits column zero. A suite that only knew the
# indented shape passed completely while the commands could not touch the one
# file every share starts life with.

# The cases are built at FILE SCOPE. Pester expands -ForEach during discovery,
# before any BeforeAll has run, so a list built in BeforeAll produces one passing
# test that covers nothing.
$script:root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# A header, a comment above a rule, a trailing comment on a value line, a
# flow-style when: and a block-style set: - everything an administrator's own
# file has in it, so "byte-identical" means something.
$script:indentedText = @'
# Variable rules for this deployment share - what CustomSettings.ini was.
#
# Rules are walked top to bottom.

schemaVersion: 1
rules:
  - name: Lab subnet
    when: { HDTDefaultGateway: "10.20.30.1" }
    set:
      HDTJoinDomain: lab.contoso.com
      HDTTaskSequenceID: LAB-CLIENT

  # Wildcards are allowed, and this one is why.
  - name: Latitude naming
    when: { HDTModel: "Latitude*", HDTIsLaptop: true }   # matched case-insensitively
    set:
      HDTComputerName: "LT-%HDTSerialNumber%"

  - name: Scripted name
    setFrom: Scripts\Get-ComputerName.ps1

  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTSerialNumber%"
      HDTJoinWorkgroup: WORKGROUP
'@

# The same document in the shape ConvertTo-HDTYaml writes, dash at column zero.
$script:columnZeroText = @'
# Variable rules for this deployment share - what CustomSettings.ini was.
#
# Rules are walked top to bottom.

schemaVersion: 1
rules:
- name: Lab subnet
  when: { HDTDefaultGateway: "10.20.30.1" }
  set:
    HDTJoinDomain: lab.contoso.com
    HDTTaskSequenceID: LAB-CLIENT

# Wildcards are allowed, and this one is why.
- name: Latitude naming
  when: { HDTModel: "Latitude*", HDTIsLaptop: true }   # matched case-insensitively
  set:
    HDTComputerName: "LT-%HDTSerialNumber%"

- name: Scripted name
  setFrom: Scripts\Get-ComputerName.ps1

- name: Fallback
  set:
    HDTComputerName: "PC-%HDTSerialNumber%"
    HDTJoinWorkgroup: WORKGROUP
'@

$script:style = @(
    @{ Style = 'rules indented'; Text = $script:indentedText; Indent = '  ' }
    @{ Style = 'rules at column zero'; Text = $script:columnZeroText; Indent = '' }
)

$script:document = @(
    @(Get-ChildItem -Path (Join-Path -Path $script:root -ChildPath 'tests/fixtures/rules') `
            -Filter 'valid-*.yaml' -File -ErrorAction SilentlyContinue)
    @(Get-ChildItem -Path (Join-Path -Path $script:root -ChildPath 'samples') `
            -Filter 'rules.yaml' -Recurse -ErrorAction SilentlyContinue)
) | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\rules.yaml'

    function Get-HDTTestRuleName {
        [CmdletBinding()]
        [OutputType([string[]])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($Line -join "`r`n") }

        return [string[]] @((Import-HDTRuleDocument -Path $script:path -FileSystem $fs).Rule |
                ForEach-Object { $_.Name })
    }

    function Get-HDTTestRule {
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line,
            [Parameter(Mandatory = $true)] [string] $Name
        )

        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($Line -join "`r`n") }

        return @((Import-HDTRuleDocument -Path $script:path -FileSystem $fs).Rule |
                Where-Object { $_.Name -eq $Name })[0]
    }

    function Get-HDTTestAddedLine {
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Before,
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $After
        )

        return [string[]] @(Compare-Object -ReferenceObject $Before -DifferenceObject $After |
                Where-Object { $_.SideIndicator -eq '=>' } |
                ForEach-Object { [string] $_.InputObject })
    }

    function Get-HDTTestRemovedLine {
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Before,
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $After
        )

        return [string[]] @(Compare-Object -ReferenceObject $Before -DifferenceObject $After |
                Where-Object { $_.SideIndicator -eq '<=' } |
                ForEach-Object { [string] $_.InputObject })
    }
}

Describe 'the rules commands are exported by Hephaestus' {

    It 'exports <_>' -ForEach @('Add-HDTRule', 'Set-HDTRule', 'Remove-HDTRule', 'Save-HDTRuleDocument') {
        Get-Command -Name $_ -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Add-HDTRule (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'appends to the end by default, where a new rule cannot shadow an existing one' {
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' }

        Get-HDTTestRuleName -Line $after |
            Should -Be @('Lab subnet', 'Latitude naming', 'Scripted name', 'Fallback', 'Spare')
    }

    It 'puts a rule directly after the one it was told to follow' {
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' } -After 'Lab subnet'

        Get-HDTTestRuleName -Line $after |
            Should -Be @('Lab subnet', 'Spare', 'Latitude naming', 'Scripted name', 'Fallback')
    }

    It 'puts a rule at the top when it is asked to win over everything below it' {
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' } -First

        Get-HDTTestRuleName -Line $after |
            Should -Be @('Spare', 'Lab subnet', 'Latitude naming', 'Scripted name', 'Fallback')
    }

    It 'leaves every line it did not add byte-identical' {
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' } -After 'Lab subnet'

        Get-HDTTestRemovedLine -Before $script:line -After $after | Should -BeNullOrEmpty
    }

    It 'writes the new rule at the indentation the existing rules are at' {
        # A rule written at the wrong column belongs to the rule above it or to
        # nothing, and the administrator's own edit is what broke the file.
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' }
        $added = @(Get-HDTTestAddedLine -Before $script:line -After $after | Where-Object { $_ -match '- name:' })

        $added[0] | Should -BeExactly ('{0}- name: Spare' -f $Indent)
    }

    It 'writes a when: block for a conditional rule' {
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -When ([ordered] @{ HDTIsLaptop = $true }) `
            -Set @{ HDTOrganisation = 'Contoso' }

        (Get-HDTTestRule -Line $after -Name 'Spare').When['HDTIsLaptop'] | Should -BeTrue
    }

    It 'writes a setFrom rule when that is what it was given' {
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -SetFrom 'Scripts\Get-Spare.ps1'
        $rule = Get-HDTTestRule -Line $after -Name 'Spare'

        $rule.SetFrom | Should -BeExactly 'Scripts\Get-Spare.ps1'
        $rule.Set | Should -BeNullOrEmpty
    }

    It 'writes a list value as a YAML sequence' {
        # A list item is a dash line too, and reading one as a rule would report
        # this document as having more rules than it has.
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -Set ([ordered] @{ HDTApplication = @('Office', 'Reader') })

        @((Get-HDTTestRule -Line $after -Name 'Spare').Set['HDTApplication']) | Should -Be @('Office', 'Reader')
        Get-HDTTestRuleName -Line $after |
            Should -Be @('Lab subnet', 'Latitude naming', 'Scripted name', 'Fallback', 'Spare')
    }

    It 'refuses a set: name the engine would reject, and names it' {
        # The schema says ^HDT[A-Za-z0-9_]*$. Refusing here, before the lines are
        # handed back, is what stops the failure surfacing at Save with several
        # more edits stacked on top of it.
        { Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ Organisation = 'Contoso' } } |
            Should -Throw -ExpectedMessage '*Organisation*'
    }

    It 'refuses that with an HDTConfigurationError' {
        $record = $null
        try {
            Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ Organisation = 'Contoso' }
        } catch {
            $record = $_
        }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses a name another rule already uses, because provenance names the rule' {
        { Add-HDTRule -Line $script:line -Name 'Fallback' -Set @{ HDTOrganisation = 'Contoso' } } |
            Should -Throw -ExpectedMessage '*Fallback*'
    }

    It 'refuses to follow a rule that is not there rather than appending quietly' {
        { Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' } -After 'Nowhere' } |
            Should -Throw -ExpectedMessage '*Nowhere*'
    }

    It 'refuses -After together with -First, which name two different places' {
        { Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' } -After 'Fallback' -First } |
            Should -Throw
    }

    It 'changes nothing under -WhatIf' {
        $after = Add-HDTRule -Line $script:line -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' } -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'Set-HDTRule (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'replaces the set: block of one rule and leaves the others alone' {
        $after = Set-HDTRule -Line $script:line -Name 'Fallback' -Set ([ordered] @{ HDTComputerName = 'PC-%HDTAssetTag%' })
        $rule = Get-HDTTestRule -Line $after -Name 'Fallback'

        $rule.Set['HDTComputerName'] | Should -BeExactly 'PC-%HDTAssetTag%'
        @($rule.Set.Keys).Count | Should -Be 1
        (Get-HDTTestRule -Line $after -Name 'Lab subnet').Set['HDTJoinDomain'] |
            Should -BeExactly 'lab.contoso.com'
    }

    It 'touches only the lines of the rule it was given' {
        $after = Set-HDTRule -Line $script:line -Name 'Fallback' -Set ([ordered] @{ HDTComputerName = 'PC-%HDTAssetTag%' })

        $removed = @(Get-HDTTestRemovedLine -Before $script:line -After $after)

        # The two set: values of Fallback, and nothing else in the file.
        @($removed | Where-Object { $_ -notmatch 'HDTComputerName|HDTJoinWorkgroup' }) | Should -BeNullOrEmpty
    }

    It 'keeps the comment written above the rule it edits' {
        $after = Set-HDTRule -Line $script:line -Name 'Latitude naming' -Set ([ordered] @{ HDTComputerName = 'NB-%HDTSerialNumber%' })

        $after | Should -Contain ('{0}# Wildcards are allowed, and this one is why.' -f $Indent)
    }

    It 'adds a when: to a rule that had none' {
        $after = Set-HDTRule -Line $script:line -Name 'Fallback' -When ([ordered] @{ HDTIsLaptop = $true })

        (Get-HDTTestRule -Line $after -Name 'Fallback').When['HDTIsLaptop'] | Should -BeTrue
    }

    It 'removes when: when it is handed an empty set of conditions' {
        # An empty when: is not a document the engine loads, so "no conditions"
        # can only mean "this rule always applies".
        $after = Set-HDTRule -Line $script:line -Name 'Lab subnet' -When ([ordered] @{})

        @((Get-HDTTestRule -Line $after -Name 'Lab subnet').When.Keys).Count | Should -Be 0
    }

    It 'swaps set: for setFrom:, because a rule declares one or the other' {
        $after = Set-HDTRule -Line $script:line -Name 'Fallback' -SetFrom 'Scripts\Get-Fallback.ps1'
        $rule = Get-HDTTestRule -Line $after -Name 'Fallback'

        $rule.SetFrom | Should -BeExactly 'Scripts\Get-Fallback.ps1'
        $rule.Set | Should -BeNullOrEmpty
    }

    It 'swaps setFrom: for set: the same way round' {
        $after = Set-HDTRule -Line $script:line -Name 'Scripted name' -Set ([ordered] @{ HDTComputerName = 'PC-1' })
        $rule = Get-HDTTestRule -Line $after -Name 'Scripted name'

        $rule.Set['HDTComputerName'] | Should -BeExactly 'PC-1'
        $rule.SetFrom | Should -BeNullOrEmpty
    }

    It 'renames a rule on its own entry line' {
        $after = Set-HDTRule -Line $script:line -Name 'Fallback' -NewName 'Last resort'

        Get-HDTTestRuleName -Line $after |
            Should -Be @('Lab subnet', 'Latitude naming', 'Scripted name', 'Last resort')
        $after | Should -Contain ('{0}- name: Last resort' -f $Indent)
    }

    It 'refuses -Set together with -SetFrom, which is the one thing a rule may not be' {
        { Set-HDTRule -Line $script:line -Name 'Fallback' -Set @{ HDTOrganisation = 'Contoso' } -SetFrom 'Scripts\X.ps1' } |
            Should -Throw -ExpectedMessage '*never both*'
    }

    It 'refuses a rule name that is not in the document' {
        { Set-HDTRule -Line $script:line -Name 'Nowhere' -Set @{ HDTOrganisation = 'Contoso' } } |
            Should -Throw -ExpectedMessage '*Nowhere*'
    }

    It 'refuses a call that asks for no change at all' {
        { Set-HDTRule -Line $script:line -Name 'Fallback' } | Should -Throw
    }

    It 'refuses a set: name the engine would reject' {
        { Set-HDTRule -Line $script:line -Name 'Fallback' -Set @{ Organisation = 'Contoso' } } |
            Should -Throw -ExpectedMessage '*Organisation*'
    }

    It 'refuses a rename onto a name another rule already uses' {
        { Set-HDTRule -Line $script:line -Name 'Fallback' -NewName 'Lab subnet' } |
            Should -Throw -ExpectedMessage '*Lab subnet*'
    }

    It 'changes nothing under -WhatIf' {
        $after = Set-HDTRule -Line $script:line -Name 'Fallback' -NewName 'Last resort' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'Remove-HDTRule (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'takes the rule out and leaves the rest in order' {
        $after = Remove-HDTRule -Line $script:line -Name 'Scripted name'

        Get-HDTTestRuleName -Line $after | Should -Be @('Lab subnet', 'Latitude naming', 'Fallback')
    }

    It 'takes the comment written above the rule with it' {
        # A comment left behind attaches itself to whatever now sits beneath it,
        # so the file ends up stating something untrue.
        $after = Remove-HDTRule -Line $script:line -Name 'Latitude naming'

        $after | Should -Not -Contain ('{0}# Wildcards are allowed, and this one is why.' -f $Indent)
    }

    It 'adds no line of its own' {
        $after = Remove-HDTRule -Line $script:line -Name 'Scripted name'

        Get-HDTTestAddedLine -Before $script:line -After $after | Should -BeNullOrEmpty
    }

    It 'refuses to remove the last rule, which would leave a document the engine cannot load' {
        $only = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            ('{0}- name: Fallback' -f $Indent)
            ('{0}  set:' -f $Indent)
            ('{0}    HDTJoinWorkgroup: WORKGROUP' -f $Indent)
        )

        { Remove-HDTRule -Line $only -Name 'Fallback' } | Should -Throw -ExpectedMessage '*only rule*'
    }

    It 'refuses a rule name that is not in the document' {
        { Remove-HDTRule -Line $script:line -Name 'Nowhere' } | Should -Throw -ExpectedMessage '*Nowhere*'
    }

    It 'changes nothing under -WhatIf' {
        $after = Remove-HDTRule -Line $script:line -Name 'Scripted name' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'Save-HDTRuleDocument (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'writes the edited document through the injected filesystem' {
        $script:captured = $null
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $Text }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:capturedPath = $Path
            $script:captured = $Text
        }

        $edited = Remove-HDTRule -Line $script:line -Name 'Scripted name'
        $result = Save-HDTRuleDocument -Path $script:path -Line $edited -FileSystem $fake -Confirm:$false

        $result.Saved | Should -BeTrue
        $result.RuleCount | Should -Be 3
        $script:captured | Should -Not -Match 'Scripted name'
    }

    It 'gives the document back byte for byte when nothing was changed' {
        $script:captured = $null
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $Text }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:capturedPath = $Path
            $script:captured = $Text
        }

        [void] (Save-HDTRuleDocument -Path $script:path -Line $script:line -FileSystem $fake -Confirm:$false)

        $script:captured | Should -BeExactly $Text
    }

    It 'refuses to write something the engine cannot read, and writes nothing' {
        $script:captured = $null
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $Text }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:capturedPath = $Path
            $script:captured = $Text
        }

        $broken = [string[]] @('schemaVersion: 1', 'rules:', '  - name: Fallback', '     set:', '      HDTX: 1')

        { Save-HDTRuleDocument -Path $script:path -Line $broken -FileSystem $fake -Confirm:$false } | Should -Throw
        $script:captured | Should -BeNullOrEmpty
    }

    It 'keeps the line endings the file already had' {
        $script:captured = $null
        $lf = ($Text -replace "`r`n", "`n")
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $lf }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:capturedPath = $Path
            $script:captured = $Text
        }

        [void] (Save-HDTRuleDocument -Path $script:path -Line ([string[]] @($lf -split "`r?`n")) -FileSystem $fake -Confirm:$false)

        $script:captured | Should -Not -Match "`r"
    }

    It 'writes nothing under -WhatIf and says so' {
        $script:captured = $null
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $Text }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:capturedPath = $Path
            $script:captured = $Text
        }

        $result = Save-HDTRuleDocument -Path $script:path -Line $script:line -FileSystem $fake -WhatIf

        $result.Saved | Should -BeFalse
        $script:captured | Should -BeNullOrEmpty
    }
}

Describe 'a shape the editor does not support fails safely' {

    # A RULE'S KEYS ARE READ AT THE DASH COLUMN PLUS TWO, which is what
    # `- name: X` / `  set:` means and what every document this toolkit writes or
    # ships uses - the same convention the task sequence editor has always read
    # steps by. A dash padded out to `-   name:` puts the keys at plus four, and
    # a key splice against that would produce a misaligned mapping.
    #
    # THE POINT OF THIS TEST IS THAT IT REFUSES RATHER THAN MANGLES. The
    # validation gate parses the spliced document before handing it back, so an
    # unsupported shape is a terminating error naming the file and nothing is
    # written - which is the difference between a shape this editor cannot help
    # with and a share it has broken.

    BeforeAll {
        $script:padded = [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '-   name: Fallback'
            '    set:'
            '      HDTJoinWorkgroup: WORKGROUP'
            '-   name: Other'
            '    set:'
            '      HDTOrganisation: Contoso'
        )
    }

    It 'refuses a key splice it cannot align, with an HDTConfigurationError' {
        $record = $null
        try {
            Set-HDTRule -Line $script:padded -Name 'Fallback' -When ([ordered] @{ HDTIsLaptop = $true })
        } catch {
            $record = $_
        }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'still adds and removes whole rules, which are block splices rather than key splices' {
        $after = Add-HDTRule -Line $script:padded -Name 'Spare' -Set @{ HDTOrganisation = 'Contoso' }

        Get-HDTTestRuleName -Line $after | Should -Be @('Fallback', 'Other', 'Spare')
        Get-HDTTestRuleName -Line (Remove-HDTRule -Line $script:padded -Name 'Fallback') | Should -Be @('Other')
    }
}

Describe 'a load and save cycle on every rules document in the repository' {

    It 'has documents to cover in the first place' {
        # -ForEach over an empty list expands to no tests and a green run, which
        # is how a suite that covers nothing looks exactly like one that covers
        # everything.
        $found = @(
            @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/rules') `
                    -Filter 'valid-*.yaml' -File -ErrorAction SilentlyContinue)
            @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'samples') `
                    -Filter 'rules.yaml' -Recurse -ErrorAction SilentlyContinue)
        )

        @($found).Count | Should -BeGreaterOrEqual 4
    }

    It 'gives <Name> back byte for byte' -ForEach $script:document {
        $original = [System.IO.File]::ReadAllText($Path)
        $documentLine = [string[]] @($original -split "`r?`n")

        $script:captured = $null
        $script:capturedPath = $null

        $fake = New-HDTFakeFileSystem -File @{ $Path = $original }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)

            $script:capturedPath = $Path
            $script:captured = $Text
        }

        [void] (Save-HDTRuleDocument -Path $Path -Line $documentLine -FileSystem $fake -Confirm:$false)

        $script:capturedPath | Should -BeExactly $Path
        $script:captured | Should -BeExactly $original -Because ("{0} came back different from how it went in" -f $Name)
    }

    It 'changes exactly the lines it was asked to in <Name>' -ForEach $script:document {
        $original = [System.IO.File]::ReadAllText($Path)
        $documentLine = [string[]] @($original -split "`r?`n")

        $edited = @(Add-HDTRule -Line $documentLine -Name 'HDT round trip probe' -Set @{ HDTOrganisation = 'Contoso' })

        # Nothing removed, and the added lines are the probe's own.
        @(Compare-Object -ReferenceObject $documentLine -DifferenceObject $edited |
                Where-Object { $_.SideIndicator -eq '<=' }) | Should -BeNullOrEmpty
    }
}

Describe 'the rules commands against the rules.yaml the toolkit itself writes' {

    # THE COMPOSITION, NOT EITHER COMMAND ON ITS OWN. New-HDTWorkspace is tested
    # against its own expectations and the rules commands were tested against
    # their own fixtures, and both suites were green while the two could not be
    # used together at all: New-HDTWorkspace serialises through ConvertTo-HDTYaml,
    # which puts the rule dash at column zero, and the editor read that dash as
    # the next top-level key and reported a document with no rules in it.
    #
    # Every share starts life with exactly this file, so this is the first
    # rules.yaml an administrator ever edits - and it was the one document the
    # editor could not touch.
    #
    # NOTHING HERE GOES NEAR A DISK. The workspace is created in a fake
    # filesystem, so the share, its folders and its documents exist only in
    # memory.

    Context 'a share created by New-HDTWorkspace, then edited by the rules commands' {

        BeforeAll {
            $script:shareFileSystem = New-HDTFakeFileSystem
            $script:share = New-HDTWorkspace -Path 'C:\ws\HDT-LAB' -Id 'HDT-LAB' `
                -FileSystem $script:shareFileSystem -Confirm:$false

            $script:written = $script:shareFileSystem.ReadAllText($script:share.RulePath)
            $script:shareLine = [string[]] @($script:written -split "`r?`n")
        }

        It 'wrote a rules.yaml the engine reads as holding the rules a new share gets' {
            # A NEW SHARE IS NOT EMPTY. New-HDTWorkspace writes the locale rule
            # every deployment needs an answer for and the fallback that names
            # the machine, and these tests edit around them - so this asserts
            # what the toolkit writes rather than pinning a count that grows
            # whenever a sensible default is added.
            Get-HDTTestRuleName -Line $script:shareLine | Should -Be @('Language and region', 'Fallback')
        }

        It 'takes a rule added above the fallback' {
            $after = Add-HDTRule -Line $script:shareLine -Name 'Latitude naming' -First `
                -When ([ordered] @{ HDTModel = 'Latitude*' }) `
                -Set ([ordered] @{ HDTComputerName = 'LT-%HDTSerialNumber%' })

            Get-HDTTestRuleName -Line $after | Should -Be @('Latitude naming', 'Language and region', 'Fallback')
            (Get-HDTTestRule -Line $after -Name 'Latitude naming').When['HDTModel'] |
                Should -BeExactly 'Latitude*'
        }

        It 'takes a rule appended after the fallback' {
            $after = Add-HDTRule -Line $script:shareLine -Name 'Applications' `
                -Set ([ordered] @{ HDTApplication = @('Office', 'Reader') })

            Get-HDTTestRuleName -Line $after | Should -Be @('Language and region', 'Fallback', 'Applications')
            @((Get-HDTTestRule -Line $after -Name 'Applications').Set['HDTApplication']) |
                Should -Be @('Office', 'Reader')
        }

        It 'changes the fallback rule the share was created with' {
            $after = Set-HDTRule -Line $script:shareLine -Name 'Fallback' `
                -Set ([ordered] @{ HDTComputerName = 'PC-%HDTAssetTag%'; HDTJoinWorkgroup = 'WORKGROUP' })

            (Get-HDTTestRule -Line $after -Name 'Fallback').Set['HDTComputerName'] |
                Should -BeExactly 'PC-%HDTAssetTag%'
        }

        It 'renames the fallback rule on its own entry line' {
            $after = Set-HDTRule -Line $script:shareLine -Name 'Fallback' -NewName 'Last resort'

            Get-HDTTestRuleName -Line $after | Should -Be @('Language and region', 'Last resort')
        }

        It 'removes a rule that was added to it' {
            $after = Add-HDTRule -Line $script:shareLine -Name 'Applications' -First `
                -Set ([ordered] @{ HDTApplication = @('Office') })
            $after = Remove-HDTRule -Line $after -Name 'Applications'

            Get-HDTTestRuleName -Line $after | Should -Be @('Language and region', 'Fallback')
        }

        It 'removes the fallback, now that a new share has more than one rule' {
            # IT USED TO BE THE ONLY ONE, and removing it was refused for that
            # reason - a rules.yaml with no rules is not a document the engine
            # reads. A new share carries two now, so this is an ordinary
            # removal, and the refusal is proven elsewhere against a file that
            # really does hold one.
            $after = Remove-HDTRule -Line $script:shareLine -Name 'Fallback'

            Get-HDTTestRuleName -Line $after | Should -Be @('Language and region')
        }

        It 'keeps the comment header the share was created with through a full edit and save' {
            # The header carries the worked conditional example an administrator
            # reads before they write their first rule. It is the reason these
            # commands splice rather than re-serialise, so an edit that lost it
            # would defeat the whole design.
            $script:captured = $null
            $fake = New-HDTFakeFileSystem -File @{ $script:share.RulePath = $script:written }
            $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
                param([string] $Path, [string] $Text)
                $script:capturedPath = $Path
                $script:captured = $Text
            }

            $after = Add-HDTRule -Line $script:shareLine -Name 'Latitude naming' -First `
                -When ([ordered] @{ HDTModel = 'Latitude*' }) `
                -Set ([ordered] @{ HDTComputerName = 'LT-%HDTSerialNumber%' })

            $result = Save-HDTRuleDocument -Path $script:share.RulePath -Line $after `
                -FileSystem $fake -Confirm:$false

            $result.RuleCount | Should -Be 3
            $script:captured | Should -Match 'what CustomSettings\.ini was'
            $script:captured | Should -Match '#   - name: Naming service'
        }

        It 'gives the share rules.yaml back byte for byte when nothing was changed' {
            $script:captured = $null
            $fake = New-HDTFakeFileSystem -File @{ $script:share.RulePath = $script:written }
            $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
                param([string] $Path, [string] $Text)
                $script:capturedPath = $Path
                $script:captured = $Text
            }

            [void] (Save-HDTRuleDocument -Path $script:share.RulePath -Line $script:shareLine `
                    -FileSystem $fake -Confirm:$false)

            $script:captured | Should -BeExactly $script:written
        }
    }
}
