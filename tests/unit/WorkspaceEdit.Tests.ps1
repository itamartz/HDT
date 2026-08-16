# Authoring workspace.yaml from a command, the way rules.yaml and sequence.yaml
# are authored.
#
# WORKSPACE.YAML IS HAND-EDITED FROM THE DAY IT IS WRITTEN. New-HDTWorkspace
# creates it with a comment header explaining deployRoot and the engine defaults,
# and an administrator adds their own notes beside every key they set. A parse
# and re-emit hands back a correct document and none of that - so these commands
# splice LINES, and every line they were not asked to change comes back
# byte-identical.
#
# THE bootImage BLOCK MAY NOT BE THERE AT ALL, and usually is not:
# New-HDTWorkspace deliberately writes none, because an omitted setting takes the
# engine's default and a copied-out default goes stale. So these commands have to
# CREATE the block and its nested keys, not merely edit existing ones. That is
# the one way this differs from the rules commands, where rules: always exists.
#
# EVERY EDIT IS RUN TWICE, OVER BOTH SHAPES A WORKSPACE DOCUMENT LEGALLY HAS.
# YAML lets a block sequence sit at its parent's own indentation or one level in.
# The hand-written samples in this repository indent; the serialiser
# ConvertTo-HDTYaml, which New-HDTWorkspace writes the first workspace.yaml of
# every share with, emits the parent's column. A suite that only knew one shape
# passed completely while the commands could not touch the file the toolkit
# itself writes - which is exactly the bug the rules commands shipped with.

# The cases are built at FILE SCOPE. Pester expands -ForEach during discovery,
# before any BeforeAll has run, so a list built in BeforeAll produces one passing
# test that covers nothing.
$script:root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# A header, comments inside the bootImage block, a trailing comment on a value
# line, and both list keys populated - everything an administrator's own file has
# in it, so "byte-identical" means something.
$script:indentedText = @'
# The identity of this deployment share, and the defaults every deployment
# from it starts with.
#
# Everything not stated here takes an engine default.

schemaVersion: 1
id: HDT-LAB
name: HDT lab deployment share
deployRoot: \\HDT-HOST\HdtShare
logLevel: Info

credential:
  username: CONTOSO\svc-hdt-deploy

bootImage:
  # The artifact base name. Produces Boot\HDTPE_x64.wim and Boot\HDTPE_x64.iso.
  name: HDTPE_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512

  optionalComponents:
    - WinPE-SecureStartup    # BitLocker
    - WinPE-EnhancedStorage

  extraContent:
    - source: Modules\MyVendorTools
      destination: \HDT\Modules\MyVendorTools
    - source: Tools\BGInfo
      destination: \HDT\Tools\BGInfo
'@

# The same document in the shape ConvertTo-HDTYaml writes, block sequences at
# their parent key's own column.
$script:columnZeroText = @'
# The identity of this deployment share, and the defaults every deployment
# from it starts with.
#
# Everything not stated here takes an engine default.

schemaVersion: 1
id: HDT-LAB
name: HDT lab deployment share
deployRoot: \\HDT-HOST\HdtShare
logLevel: Info
credential:
  username: CONTOSO\svc-hdt-deploy
bootImage:
  # The artifact base name. Produces Boot\HDTPE_x64.wim and Boot\HDTPE_x64.iso.
  name: HDTPE_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
  optionalComponents:
  - WinPE-SecureStartup    # BitLocker
  - WinPE-EnhancedStorage
  extraContent:
  - source: Modules\MyVendorTools
    destination: \HDT\Modules\MyVendorTools
  - source: Tools\BGInfo
    destination: \HDT\Tools\BGInfo
'@

$script:style = @(
    @{ Style = 'sequences indented'; Text = $script:indentedText; ItemIndent = '    ' }
    @{ Style = 'sequences at the parent column'; Text = $script:columnZeroText; ItemIndent = '  ' }
)

$script:document = @(
    @(Get-ChildItem -Path (Join-Path -Path $script:root -ChildPath 'tests/fixtures/workspace') `
            -Filter 'valid-*.yaml' -File -ErrorAction SilentlyContinue)
    @(Get-ChildItem -Path (Join-Path -Path $script:root -ChildPath 'samples') `
            -Filter 'workspace.yaml' -Recurse -ErrorAction SilentlyContinue)
) | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\workspace.yaml'

    function Get-HDTTestWorkspace {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($Line -join "`r`n") }

        return Import-HDTWorkspaceDocument -Path $script:path -FileSystem $fs
    }

    function Get-HDTTestDestination {
        [CmdletBinding()]
        [OutputType([string[]])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        return [string[]] @((Get-HDTTestWorkspace -Line $Line).BootImage.ExtraContent |
                ForEach-Object { [string] $_.Destination })
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

Describe 'the workspace commands are exported by Hephaestus' {

    It 'exports <_>' -ForEach @(
        'Add-HDTBootImageContent', 'Remove-HDTBootImageContent',
        'Add-HDTBootImageComponent', 'Remove-HDTBootImageComponent',
        'Add-HDTBootImageStartCommand', 'Remove-HDTBootImageStartCommand',
        'Move-HDTBootImageStartCommand',
        'Set-HDTBootImageDriver', 'Set-HDTBootImageUnattend', 'Set-HDTWorkspaceProperty',
        'Save-HDTWorkspaceDocument', 'Get-HDTAdkComponent') {

        Get-Command -Name $_ -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Add-HDTBootImageContent (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'adds an entry the engine reads back' {
        $after = Add-HDTBootImageContent -Line $script:line -Source 'Tools\VNC' -Destination '\HDT\Tools\VNC'

        Get-HDTTestDestination -Line $after |
            Should -Be @('\HDT\Modules\MyVendorTools', '\HDT\Tools\BGInfo', '\HDT\Tools\VNC')
    }

    It 'keeps the source it was given' {
        $after = Add-HDTBootImageContent -Line $script:line -Source 'Tools\VNC' -Destination '\HDT\Tools\VNC'
        $entry = @((Get-HDTTestWorkspace -Line $after).BootImage.ExtraContent |
                Where-Object { $_.Destination -eq '\HDT\Tools\VNC' })[0]

        $entry.Source | Should -BeExactly 'Tools\VNC'
    }

    It 'leaves every line it did not add byte-identical' {
        $after = Add-HDTBootImageContent -Line $script:line -Source 'Tools\VNC' -Destination '\HDT\Tools\VNC'

        Get-HDTTestRemovedLine -Before $script:line -After $after | Should -BeNullOrEmpty
    }

    It 'writes the new entry at the column the existing entries are at' {
        # An entry written at the wrong column belongs to the entry above it or
        # to nothing, and the administrator's own edit is what broke the file.
        $after = Add-HDTBootImageContent -Line $script:line -Source 'Tools\VNC' -Destination '\HDT\Tools\VNC'
        $added = @(Get-HDTTestAddedLine -Before $script:line -After $after | Where-Object { $_ -match '- source:' })

        $added[0] | Should -BeExactly ('{0}- source: Tools\VNC' -f $ItemIndent)
    }

    It 'refuses a destination containing .. at authoring time, not at build time' {
        # A '..' destination escapes the image and writes onto the build host.
        # Refusing here is what stops it surfacing fifteen minutes into a build
        # with a WIM mounted.
        { Add-HDTBootImageContent -Line $script:line -Source 'Tools\VNC' -Destination '\HDT\..\..\Windows' } |
            Should -Throw -ExpectedMessage '*..*'
    }

    It 'refuses that with an HDTConfigurationError' {
        $record = $null
        try {
            Add-HDTBootImageContent -Line $script:line -Source 'Tools\VNC' -Destination '\HDT\..\Windows'
        } catch {
            $record = $_
        }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses a destination that is not rooted at the image' {
        { Add-HDTBootImageContent -Line $script:line -Source 'Tools\VNC' -Destination 'HDT\Tools\VNC' } |
            Should -Throw -ExpectedMessage '*HDT\Tools\VNC*'
    }

    It 'refuses an entry the document already declares' {
        { Add-HDTBootImageContent -Line $script:line -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo' } |
            Should -Throw -ExpectedMessage '*BGInfo*'
    }

    It 'allows a second source landing on the same destination, which is how content is merged' {
        $after = Add-HDTBootImageContent -Line $script:line -Source 'Tools\BGInfoConfig' -Destination '\HDT\Tools\BGInfo'

        Get-HDTTestDestination -Line $after |
            Should -Be @('\HDT\Modules\MyVendorTools', '\HDT\Tools\BGInfo', '\HDT\Tools\BGInfo')
    }

    It 'changes nothing under -WhatIf' {
        $after = Add-HDTBootImageContent -Line $script:line -Source 'Tools\VNC' -Destination '\HDT\Tools\VNC' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'Remove-HDTBootImageContent (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'takes the entry out and leaves the rest in order' {
        $after = Remove-HDTBootImageContent -Line $script:line -Destination '\HDT\Tools\BGInfo'

        Get-HDTTestDestination -Line $after | Should -Be @('\HDT\Modules\MyVendorTools')
    }

    It 'adds no line of its own' {
        $after = Remove-HDTBootImageContent -Line $script:line -Destination '\HDT\Tools\BGInfo'

        Get-HDTTestAddedLine -Before $script:line -After $after | Should -BeNullOrEmpty
    }

    It 'removes the extraContent key with the last entry, because an empty one is not a document the engine loads' {
        $after = Remove-HDTBootImageContent -Line $script:line -Destination '\HDT\Tools\BGInfo'
        $after = Remove-HDTBootImageContent -Line $after -Destination '\HDT\Modules\MyVendorTools'

        @(Get-HDTTestDestination -Line $after).Count | Should -Be 0
        @($after | Where-Object { $_ -match '^\s*extraContent:' }) | Should -BeNullOrEmpty
    }

    It 'refuses an entry that is not there rather than doing nothing quietly' {
        { Remove-HDTBootImageContent -Line $script:line -Destination '\HDT\Tools\Nowhere' } |
            Should -Throw -ExpectedMessage '*Nowhere*'
    }

    It 'refuses to guess which of two entries sharing a destination was meant' {
        # DESIGN's rule for anything destructive: an ambiguous target is refused,
        # never guessed.
        $two = Add-HDTBootImageContent -Line $script:line -Source 'Tools\BGInfoConfig' -Destination '\HDT\Tools\BGInfo'

        { Remove-HDTBootImageContent -Line $two -Destination '\HDT\Tools\BGInfo' } |
            Should -Throw -ExpectedMessage '*-Source*'
    }

    It 'removes the one named by both source and destination' {
        $two = Add-HDTBootImageContent -Line $script:line -Source 'Tools\BGInfoConfig' -Destination '\HDT\Tools\BGInfo'
        $after = Remove-HDTBootImageContent -Line $two -Source 'Tools\BGInfoConfig' -Destination '\HDT\Tools\BGInfo'

        Get-HDTTestDestination -Line $after | Should -Be @('\HDT\Modules\MyVendorTools', '\HDT\Tools\BGInfo')
    }

    It 'changes nothing under -WhatIf' {
        $after = Remove-HDTBootImageContent -Line $script:line -Destination '\HDT\Tools\BGInfo' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'Add-HDTBootImageComponent (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'adds the component to the declared list' {
        $after = Add-HDTBootImageComponent -Line $script:line -Name 'WinPE-HTA'

        (Get-HDTTestWorkspace -Line $after).BootImage.OptionalComponent |
            Should -Be @('WinPE-SecureStartup', 'WinPE-EnhancedStorage', 'WinPE-HTA')
    }

    It 'adds more than one in the order they were given' {
        $after = Add-HDTBootImageComponent -Line $script:line -Name @('WinPE-HTA', 'WinPE-FMAPI')

        (Get-HDTTestWorkspace -Line $after).BootImage.OptionalComponent |
            Should -Be @('WinPE-SecureStartup', 'WinPE-EnhancedStorage', 'WinPE-HTA', 'WinPE-FMAPI')
    }

    It 'leaves every line it did not add byte-identical, comments included' {
        # A rewrite of the whole list would be far simpler and would delete the
        # note somebody wrote beside a component - which is the one thing an
        # editor that splices exists to avoid.
        $after = Add-HDTBootImageComponent -Line $script:line -Name 'WinPE-HTA'

        Get-HDTTestRemovedLine -Before $script:line -After $after | Should -BeNullOrEmpty
        $after | Should -Contain (@($script:line | Where-Object { $_ -match '# BitLocker' })[0])
    }

    It 'refuses a name that is not a WinPE optional component name' {
        { Add-HDTBootImageComponent -Line $script:line -Name 'BitLocker' } |
            Should -Throw -ExpectedMessage '*BitLocker*'
    }

    It 'refuses one the document already declares, whatever the case' {
        { Add-HDTBootImageComponent -Line $script:line -Name 'winpe-securestartup' } |
            Should -Throw -ExpectedMessage '*winpe-securestartup*'
    }

    It 'changes nothing under -WhatIf' {
        $after = Add-HDTBootImageComponent -Line $script:line -Name 'WinPE-HTA' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'Remove-HDTBootImageComponent (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'takes the component out and leaves the rest in order' {
        $after = Remove-HDTBootImageComponent -Line $script:line -Name 'WinPE-SecureStartup'

        (Get-HDTTestWorkspace -Line $after).BootImage.OptionalComponent |
            Should -Be @('WinPE-EnhancedStorage')
    }

    It 'adds no line of its own, and keeps the note beside the one it left' {
        $after = Remove-HDTBootImageComponent -Line $script:line -Name 'WinPE-EnhancedStorage'

        Get-HDTTestAddedLine -Before $script:line -After $after | Should -BeNullOrEmpty
        $after | Should -Contain (@($script:line | Where-Object { $_ -match '# BitLocker' })[0])
    }

    It 'refuses a component the document does not declare' {
        { Remove-HDTBootImageComponent -Line $script:line -Name 'WinPE-HTA' } |
            Should -Throw -ExpectedMessage '*WinPE-HTA*'
    }

    It 'leaves an explicit empty list when the last one goes, which means the required six and nothing else' {
        # UNSET AND SET-TO-NOTHING ARE DIFFERENT INSTRUCTIONS. Removing the key
        # here would silently restore the three defaults the administrator has
        # just finished deleting.
        $after = Remove-HDTBootImageComponent -Line $script:line -Name @('WinPE-SecureStartup', 'WinPE-EnhancedStorage')

        @((Get-HDTTestWorkspace -Line $after).BootImage.OptionalComponent).Count | Should -Be 0
        @($after | Where-Object { $_ -match '^\s*optionalComponents:' }) | Should -Not -BeNullOrEmpty
    }

    It 'changes nothing under -WhatIf' {
        $after = Remove-HDTBootImageComponent -Line $script:line -Name 'WinPE-SecureStartup' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'the start commands (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'adds a start command to a document that declares none' {
        $after = Add-HDTBootImageStartCommand -Line $script:line -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'

        (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
            Should -Be @('X:\HDT\Tools\BGInfo\bginfo.exe /timer:0')
    }

    It 'appends the second one, because they run in order' {
        $after = Add-HDTBootImageStartCommand -Line $script:line -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'
        $after = Add-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\VNC\winvnc.exe -service'

        (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
            Should -Be @('X:\HDT\Tools\BGInfo\bginfo.exe /timer:0', 'X:\HDT\Tools\VNC\winvnc.exe -service')
    }

    It 'puts one first when it is asked to' {
        $after = Add-HDTBootImageStartCommand -Line $script:line -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'
        $after = Add-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\VNC\winvnc.exe -service' -First

        (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
            Should -Be @('X:\HDT\Tools\VNC\winvnc.exe -service', 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0')
    }

    It 'refuses a command the document already runs' {
        $after = Add-HDTBootImageStartCommand -Line $script:line -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'

        { Add-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0' } |
            Should -Throw -ExpectedMessage '*bginfo*'
    }

    It 'refuses a command carrying a line break, which would become a second command nobody could see' {
        { Add-HDTBootImageStartCommand -Line $script:line -Command "one`r`ntwo" } | Should -Throw
    }

    It 'removes the command it is given' {
        $after = Add-HDTBootImageStartCommand -Line $script:line -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'
        $after = Add-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\VNC\winvnc.exe -service'
        $after = Remove-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'

        (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
            Should -Be @('X:\HDT\Tools\VNC\winvnc.exe -service')
    }

    It 'removes the startCommand key with the last command' {
        $after = Add-HDTBootImageStartCommand -Line $script:line -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'
        $after = Remove-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'

        @((Get-HDTTestWorkspace -Line $after).BootImage.StartCommand).Count | Should -Be 0
        @($after | Where-Object { $_ -match '^\s*startCommand:' }) | Should -BeNullOrEmpty
    }

    It 'refuses to remove a command the document does not run' {
        { Remove-HDTBootImageStartCommand -Line $script:line -Command 'X:\nothing.exe' } |
            Should -Throw -ExpectedMessage '*nothing.exe*'
    }

    It 'changes nothing under -WhatIf' {
        $after = Add-HDTBootImageStartCommand -Line $script:line -Command 'X:\HDT\one.exe' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }

    # ORDER IS SEMANTICS HERE, exactly as position is in a rules document.
    # startnet.cmd runs these in the order they are listed, and cmd.exe runs
    # them synchronously - so a tool that has to be up before the next line
    # runs has to be ABOVE it, and -First only ever wins the top slot. Add was
    # the whole vocabulary until now: reordering meant remove and re-add, which
    # is three presses to move one row and loses the row's place if the second
    # add fails.
    Context 'moving one' {

        BeforeAll {
            $script:three = Add-HDTBootImageStartCommand -Line $script:line -Command 'X:\one.exe'
            $script:three = Add-HDTBootImageStartCommand -Line $script:three -Command 'X:\two.exe'
            $script:three = Add-HDTBootImageStartCommand -Line $script:three -Command 'X:\three.exe'
        }

        It 'moves one up, past exactly one neighbour' {
            $after = Move-HDTBootImageStartCommand -Line $script:three -Command 'X:\three.exe' -Direction Up

            (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
                Should -Be @('X:\one.exe', 'X:\three.exe', 'X:\two.exe')
        }

        It 'moves one down, past exactly one neighbour' {
            $after = Move-HDTBootImageStartCommand -Line $script:three -Command 'X:\one.exe' -Direction Down

            (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
                Should -Be @('X:\two.exe', 'X:\one.exe', 'X:\three.exe')
        }

        It 'leaves the first one alone when it is asked to move up' {
            # NOT AN ERROR. The button is pressed by somebody holding it down to
            # move a row several places, and refusing at the top would put a
            # message on screen for a press that simply had nowhere to go.
            $after = Move-HDTBootImageStartCommand -Line $script:three -Command 'X:\one.exe' -Direction Up

            (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
                Should -Be @('X:\one.exe', 'X:\two.exe', 'X:\three.exe')
        }

        It 'leaves the last one alone when it is asked to move down' {
            $after = Move-HDTBootImageStartCommand -Line $script:three -Command 'X:\three.exe' -Direction Down

            (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
                Should -Be @('X:\one.exe', 'X:\two.exe', 'X:\three.exe')
        }

        It 'refuses to move a command the document does not run' {
            { Move-HDTBootImageStartCommand -Line $script:three -Command 'X:\nothing.exe' -Direction Up } |
                Should -Throw -ExpectedMessage '*nothing.exe*'
        }

        It 'leaves every other line byte-identical' {
            $after = Move-HDTBootImageStartCommand -Line $script:three -Command 'X:\three.exe' -Direction Up

            # The three commands are the only lines that may differ, and only in
            # their order - the comments and every other key come back untouched.
            @(Get-HDTTestRemovedLine -Before $script:three -After $after |
                    Where-Object { $_ -notmatch 'one\.exe|two\.exe|three\.exe' }) | Should -BeNullOrEmpty
        }

        It 'changes nothing under -WhatIf' {
            $after = Move-HDTBootImageStartCommand -Line $script:three -Command 'X:\three.exe' -Direction Up -WhatIf

            ($after -join "`n") | Should -BeExactly ($script:three -join "`n")
        }
    }
}

Describe 'Set-HDTBootImageDriver (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'names the boot driver group' {
        $after = Set-HDTBootImageDriver -Line $script:line -Name 'boot-critical'

        (Get-HDTTestWorkspace -Line $after).BootImage.Drivers | Should -BeExactly 'boot-critical'
    }

    It 'replaces the group it already named' {
        $after = Set-HDTBootImageDriver -Line $script:line -Name 'boot-critical'
        $after = Set-HDTBootImageDriver -Line $after -Name 'winpe-nic'

        (Get-HDTTestWorkspace -Line $after).BootImage.Drivers | Should -BeExactly 'winpe-nic'
        @($after | Where-Object { $_ -match 'boot-critical' }) | Should -BeNullOrEmpty
    }

    It 'clears the key rather than writing it empty, which the engine refuses' {
        $after = Set-HDTBootImageDriver -Line $script:line -Name 'boot-critical'
        $after = Set-HDTBootImageDriver -Line $after -Clear

        (Get-HDTTestWorkspace -Line $after).BootImage.Drivers | Should -BeExactly ''
        @($after | Where-Object { $_ -match '^\s*drivers:' }) | Should -BeNullOrEmpty
    }

    It 'leaves every other line byte-identical' {
        $after = Set-HDTBootImageDriver -Line $script:line -Name 'boot-critical'

        Get-HDTTestRemovedLine -Before $script:line -After $after | Should -BeNullOrEmpty
    }

    It 'changes nothing under -WhatIf' {
        $after = Set-HDTBootImageDriver -Line $script:line -Name 'boot-critical' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

# The WinPE answer file. wpeinit processes it - EnableFirewall, EnableNetwork,
# Display, LogPath, PageFile, Restart, RunSynchronous, RunAsynchronous - so it is
# the supported way to build an image with the firewall configured, rather than
# a `wpeutil disablefirewall` line somebody types at a prompt.
#
# IT IS SHAPED LIKE Set-HDTBootImageDriver, deliberately: one value, -Clear to
# take it away, and the key removed rather than written empty. Two commands that
# do the same kind of thing to the same block should not need to be learned
# twice.
Describe 'Set-HDTBootImageUnattend (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'names the answer file' {
        $after = Set-HDTBootImageUnattend -Line $script:line -Path 'Control\Unattend-PE.xml'

        (Get-HDTTestWorkspace -Line $after).BootImage.Unattend |
            Should -BeExactly 'Control\Unattend-PE.xml'
    }

    It 'replaces the file it already named' {
        $after = Set-HDTBootImageUnattend -Line $script:line -Path 'Control\Unattend-PE.xml'
        $after = Set-HDTBootImageUnattend -Line $after -Path 'Control\Unattend-Lab.xml'

        (Get-HDTTestWorkspace -Line $after).BootImage.Unattend |
            Should -BeExactly 'Control\Unattend-Lab.xml'
        @($after | Where-Object { $_ -match 'Unattend-PE' }) | Should -BeNullOrEmpty
    }

    It 'clears the key rather than writing it empty, which the engine refuses' {
        $after = Set-HDTBootImageUnattend -Line $script:line -Path 'Control\Unattend-PE.xml'
        $after = Set-HDTBootImageUnattend -Line $after -Clear

        (Get-HDTTestWorkspace -Line $after).BootImage.Unattend | Should -BeExactly ''
        @($after | Where-Object { $_ -match '^\s*unattend:' }) | Should -BeNullOrEmpty
    }

    It 'leaves every other line byte-identical' {
        $after = Set-HDTBootImageUnattend -Line $script:line -Path 'Control\Unattend-PE.xml'

        Get-HDTTestRemovedLine -Before $script:line -After $after | Should -BeNullOrEmpty
    }

    It 'changes nothing under -WhatIf' {
        $after = Set-HDTBootImageUnattend -Line $script:line -Path 'Control\Unattend-PE.xml' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }

    It 'takes a rooted path, because Browse picks a file on the build host' {
        # extraContent's source accepts one and always has. An answer file kept
        # in a build folder rather than on the share is the ordinary case, not
        # an attack: whoever edits workspace.yaml can already name any content
        # they like.
        $after = Set-HDTBootImageUnattend -Line $script:line -Path 'C:\build\Unattend-PE.xml'

        (Get-HDTTestWorkspace -Line $after).BootImage.Unattend |
            Should -BeExactly 'C:\build\Unattend-PE.xml'
    }

    It 'takes a UNC path' {
        $after = Set-HDTBootImageUnattend -Line $script:line -Path '\\HDT-HOST\Build\Unattend-PE.xml'

        (Get-HDTTestWorkspace -Line $after).BootImage.Unattend |
            Should -BeExactly '\\HDT-HOST\Build\Unattend-PE.xml'
    }
}

Describe 'Set-HDTWorkspaceProperty (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'changes the display name' {
        $after = Set-HDTWorkspaceProperty -Line $script:line -Name 'Contoso deployment share'

        (Get-HDTTestWorkspace -Line $after).Name | Should -BeExactly 'Contoso deployment share'
    }

    It 'changes deployRoot, which is what a booted client connects to' {
        $after = Set-HDTWorkspaceProperty -Line $script:line -DeployRoot '\\NEW-HOST\HdtShare'

        (Get-HDTTestWorkspace -Line $after).DeployRoot | Should -BeExactly '\\NEW-HOST\HdtShare'
    }

    It 'changes the log level' {
        $after = Set-HDTWorkspaceProperty -Line $script:line -LogLevel 'Debug'

        (Get-HDTTestWorkspace -Line $after).LogLevel | Should -BeExactly 'Debug'
    }

    It 'changes the boot image scalars, all of them at once' {
        $after = Set-HDTWorkspaceProperty -Line $script:line -BootImageName 'HDTPE_lab' `
            -Architecture 'arm64' -Language 'en-gb' -ScratchSpaceMB 1024 `
            -EntryCommand 'powershell.exe -NoProfile -File X:\HDT\Start-HDTDiagnostic.ps1'

        $image = (Get-HDTTestWorkspace -Line $after).BootImage

        $image.Name | Should -BeExactly 'HDTPE_lab'
        $image.Architecture | Should -BeExactly 'arm64'
        $image.Language | Should -BeExactly 'en-gb'
        $image.ScratchSpaceMB | Should -Be 1024
        $image.EntryCommand | Should -BeExactly 'powershell.exe -NoProfile -File X:\HDT\Start-HDTDiagnostic.ps1'
    }

    It 'leaves every line it was not asked to change byte-identical' {
        $after = Set-HDTWorkspaceProperty -Line $script:line -LogLevel 'Debug'
        $removed = @(Get-HDTTestRemovedLine -Before $script:line -After $after)

        @($removed | Where-Object { $_ -notmatch 'logLevel' }) | Should -BeNullOrEmpty
    }

    It 'refuses a scratchSpaceMB below the range DISM accepts' {
        { Set-HDTWorkspaceProperty -Line $script:line -ScratchSpaceMB 16 } |
            Should -Throw -ExpectedMessage '*32*'
    }

    It 'refuses a scratchSpaceMB above it' {
        { Set-HDTWorkspaceProperty -Line $script:line -ScratchSpaceMB 2048 } |
            Should -Throw -ExpectedMessage '*1024*'
    }

    It 'refuses that with an HDTConfigurationError' {
        $record = $null
        try {
            Set-HDTWorkspaceProperty -Line $script:line -ScratchSpaceMB 2048
        } catch {
            $record = $_
        }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses a deployRoot containing ..' {
        { Set-HDTWorkspaceProperty -Line $script:line -DeployRoot '\\HOST\Share\..\Other' } |
            Should -Throw -ExpectedMessage '*..*'
    }

    It 'refuses a call that asks for no change at all' {
        { Set-HDTWorkspaceProperty -Line $script:line } | Should -Throw
    }

    It 'changes nothing under -WhatIf' {
        $after = Set-HDTWorkspaceProperty -Line $script:line -LogLevel 'Debug' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'Save-HDTWorkspaceDocument (<Style>)' -ForEach $script:style {

    BeforeAll {
        $script:line = [string[]] @($Text -split "`r?`n")
    }

    It 'writes the edited document through the injected filesystem' {
        $script:captured = $null
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $Text }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:captured = $Text
        }

        $edited = Remove-HDTBootImageContent -Line $script:line -Destination '\HDT\Tools\BGInfo'
        $result = Save-HDTWorkspaceDocument -Path $script:path -Line $edited -FileSystem $fake -Confirm:$false

        $result.Saved | Should -BeTrue
        $result.Id | Should -BeExactly 'HDT-LAB'
        $script:captured | Should -Not -Match 'BGInfo'
    }

    It 'gives the document back byte for byte when nothing was changed' {
        $script:captured = $null
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $Text }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:captured = $Text
        }

        [void] (Save-HDTWorkspaceDocument -Path $script:path -Line $script:line -FileSystem $fake -Confirm:$false)

        $script:captured | Should -BeExactly $Text
    }

    It 'refuses to write something the engine cannot read, and writes nothing' {
        $script:captured = $null
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $Text }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:captured = $Text
        }

        $broken = [string[]] @('schemaVersion: 1', 'id: HDT-LAB', 'name: Lab', 'bootImage:', '  architecture: sparc')

        { Save-HDTWorkspaceDocument -Path $script:path -Line $broken -FileSystem $fake -Confirm:$false } | Should -Throw
        $script:captured | Should -BeNullOrEmpty
    }

    It 'keeps the line endings the file already had' {
        $script:captured = $null
        $lf = ($Text -replace "`r`n", "`n")
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $lf }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:captured = $Text
        }

        [void] (Save-HDTWorkspaceDocument -Path $script:path -Line ([string[]] @($lf -split "`r?`n")) `
                -FileSystem $fake -Confirm:$false)

        $script:captured | Should -Not -Match "`r"
    }

    It 'writes nothing under -WhatIf and says so' {
        $script:captured = $null
        $fake = New-HDTFakeFileSystem -File @{ $script:path = $Text }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)
            $script:captured = $Text
        }

        $result = Save-HDTWorkspaceDocument -Path $script:path -Line $script:line -FileSystem $fake -WhatIf

        $result.Saved | Should -BeFalse
        $script:captured | Should -BeNullOrEmpty
    }
}

Describe 'a workspace.yaml with no bootImage block at all' {

    # THE SHAPE EVERY SHARE STARTS LIFE WITH. New-HDTWorkspace deliberately
    # writes no bootImage block, because an omitted setting takes the engine's
    # default and a copied-out default is one that goes stale. So the first thing
    # any of these commands has to be able to do is BUILD the block.

    # DECLARED HERE, NOT AT FILE SCOPE. Pester's discovery and run passes do not
    # share a scope: a -ForEach list is evaluated during discovery and handed to
    # the run as data, but a plain $script: variable set at file scope is not
    # readable from a BeforeAll, and reads back empty.
    BeforeAll {
        $script:bare = [string[]] @(@'
# The identity of this deployment share, and the defaults every deployment
# from it starts with.
#
# Everything not stated here takes an engine default, including the whole
# bootImage block.

schemaVersion: 1
id: HDT-LAB
name: HDT-LAB
deployRoot: \\HDT-HOST\HdtShare
logLevel: Info
'@ -split "`r?`n")
    }

    It 'has nothing to edit to begin with' {
        @((Get-HDTTestWorkspace -Line $script:bare).BootImage.ExtraContent).Count | Should -Be 0
        @($script:bare | Where-Object { $_ -match '^bootImage:' }) | Should -BeNullOrEmpty
    }

    It 'builds the block for the first extraContent entry' {
        $after = Add-HDTBootImageContent -Line $script:bare -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'

        Get-HDTTestDestination -Line $after | Should -Be @('\HDT\Tools\BGInfo')
        @($after | Where-Object { $_ -match '^bootImage:' }) | Should -Not -BeNullOrEmpty
    }

    It 'builds the block for the first start command' {
        $after = Add-HDTBootImageStartCommand -Line $script:bare -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'

        (Get-HDTTestWorkspace -Line $after).BootImage.StartCommand |
            Should -Be @('X:\HDT\Tools\BGInfo\bginfo.exe /timer:0')
    }

    It 'builds the block for the first driver group' {
        $after = Set-HDTBootImageDriver -Line $script:bare -Name 'boot-critical'

        (Get-HDTTestWorkspace -Line $after).BootImage.Drivers | Should -BeExactly 'boot-critical'
    }

    It 'builds the block for a boot image scalar' {
        $after = Set-HDTWorkspaceProperty -Line $script:bare -ScratchSpaceMB 256

        (Get-HDTTestWorkspace -Line $after).BootImage.ScratchSpaceMB | Should -Be 256
    }

    It 'materialises the engine defaults when the first component is added to an unstated list' {
        # UNSET MEANS "the admin did not say", and takes three defaults. Writing
        # only the new name would silently DELETE those three from the image -
        # an add that removes is the worst kind of surprise.
        $after = Add-HDTBootImageComponent -Line $script:bare -Name 'WinPE-HTA'

        (Get-HDTTestWorkspace -Line $after).BootImage.OptionalComponent |
            Should -Be @('WinPE-SecureStartup', 'WinPE-EnhancedStorage', 'WinPE-WDS-Tools', 'WinPE-HTA')
    }

    It 'removes one of the unstated defaults by writing the rest out' {
        $after = Remove-HDTBootImageComponent -Line $script:bare -Name 'WinPE-WDS-Tools'

        (Get-HDTTestWorkspace -Line $after).BootImage.OptionalComponent |
            Should -Be @('WinPE-SecureStartup', 'WinPE-EnhancedStorage')
    }

    It 'keeps the comment header when it builds the block' {
        $after = Add-HDTBootImageContent -Line $script:bare -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'

        $after | Should -Contain '# The identity of this deployment share, and the defaults every deployment'
    }

    It 'adds the block once, however many keys are written into it' {
        $after = Add-HDTBootImageContent -Line $script:bare -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'
        $after = Add-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'
        $after = Set-HDTBootImageDriver -Line $after -Name 'boot-critical'

        @($after | Where-Object { $_ -match '^bootImage:' }).Count | Should -Be 1
    }
}

Describe 'a load and save cycle on every workspace document in the repository' {

    It 'has documents to cover in the first place' {
        # -ForEach over an empty list expands to no tests and a green run, which
        # is how a suite that covers nothing looks exactly like one that covers
        # everything.
        $found = @(
            @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/workspace') `
                    -Filter 'valid-*.yaml' -File -ErrorAction SilentlyContinue)
            @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'samples') `
                    -Filter 'workspace.yaml' -Recurse -ErrorAction SilentlyContinue)
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

        [void] (Save-HDTWorkspaceDocument -Path $Path -Line $documentLine -FileSystem $fake -Confirm:$false)

        $script:capturedPath | Should -BeExactly $Path
        $script:captured | Should -BeExactly $original -Because ("{0} came back different from how it went in" -f $Name)
    }

    It 'changes exactly the lines it was asked to in <Name>' -ForEach $script:document {
        $original = [System.IO.File]::ReadAllText($Path)
        $documentLine = [string[]] @($original -split "`r?`n")

        $edited = @(Add-HDTBootImageContent -Line $documentLine -Source 'Tools\HDTProbe' -Destination '\HDT\Tools\HDTProbe')

        @(Compare-Object -ReferenceObject $documentLine -DifferenceObject $edited |
                Where-Object { $_.SideIndicator -eq '<=' }) | Should -BeNullOrEmpty
    }
}

Describe 'the workspace commands against the workspace.yaml the toolkit itself writes' {

    # THE COMPOSITION, NOT ANY COMMAND ON ITS OWN. The last time these two halves
    # were tested separately, both suites were green while the editor could not
    # touch the one file every share starts life with: New-HDTWorkspace
    # serialises through ConvertTo-HDTYaml, whose block sequences sit at their
    # parent's column, and the editor only knew the indented shape.
    #
    # So this drives EVERY command over the real file New-HDTWorkspace produced,
    # and reads the result back through the engine's own reader.
    #
    # NOTHING HERE GOES NEAR A DISK. The workspace is created in a fake
    # filesystem, so the share, its folders and its documents exist only in
    # memory.

    Context 'a share created by New-HDTWorkspace, then edited by the workspace commands' {

        BeforeAll {
            $script:shareFileSystem = New-HDTFakeFileSystem
            $script:share = New-HDTWorkspace -Path 'C:\ws\HDT-LAB' -Id 'HDT-LAB' `
                -Name 'HDT lab deployment share' -DeployRoot '\\HDT-HOST\HdtShare' `
                -FileSystem $script:shareFileSystem -Confirm:$false

            $script:written = $script:shareFileSystem.ReadAllText($script:share.Path)
            $script:shareLine = [string[]] @($script:written -split "`r?`n")
        }

        It 'wrote a workspace.yaml with no bootImage block, which is the point' {
            @($script:shareLine | Where-Object { $_ -match '^bootImage:' }) | Should -BeNullOrEmpty
        }

        It 'takes the four things that make a tool usable in WinPE, in one composed edit' {
            # BGInfo copied in, and started. This is the whole feature: content
            # that is copied but never run is content nobody sees.
            $after = Add-HDTBootImageContent -Line $script:shareLine `
                -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'
            $after = Add-HDTBootImageContent -Line $after `
                -Source 'Tools\VNC' -Destination '\HDT\Tools\VNC'
            $after = Add-HDTBootImageStartCommand -Line $after `
                -Command 'X:\HDT\Tools\BGInfo\bginfo.exe X:\HDT\Tools\BGInfo\hdt.bgi /timer:0 /nolicprompt'
            $after = Add-HDTBootImageStartCommand -Line $after `
                -Command 'X:\HDT\Tools\VNC\winvnc.exe -service'

            $image = (Get-HDTTestWorkspace -Line $after).BootImage

            @($image.ExtraContent | ForEach-Object { $_.Destination }) |
                Should -Be @('\HDT\Tools\BGInfo', '\HDT\Tools\VNC')
            $image.StartCommand | Should -Be @(
                'X:\HDT\Tools\BGInfo\bginfo.exe X:\HDT\Tools\BGInfo\hdt.bgi /timer:0 /nolicprompt',
                'X:\HDT\Tools\VNC\winvnc.exe -service')
        }

        It 'drives every command over it and reads the whole result back' {
            $after = Add-HDTBootImageContent -Line $script:shareLine `
                -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'
            $after = Add-HDTBootImageContent -Line $after `
                -Source 'Modules\MyVendorTools' -Destination '\HDT\Modules\MyVendorTools'
            $after = Remove-HDTBootImageContent -Line $after -Destination '\HDT\Modules\MyVendorTools'
            $after = Add-HDTBootImageComponent -Line $after -Name 'WinPE-HTA'
            $after = Remove-HDTBootImageComponent -Line $after -Name 'WinPE-WDS-Tools'
            $after = Add-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'
            $after = Set-HDTBootImageDriver -Line $after -Name 'boot-critical'
            $after = Set-HDTWorkspaceProperty -Line $after -Name 'HDT lab' -LogLevel 'Debug' `
                -BootImageName 'HDTPE_lab' -Language 'en-us' -ScratchSpaceMB 256 `
                -EntryCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDeployment.ps1'

            $workspace = Get-HDTTestWorkspace -Line $after

            $workspace.Name | Should -BeExactly 'HDT lab'
            $workspace.LogLevel | Should -BeExactly 'Debug'
            $workspace.DeployRoot | Should -BeExactly '\\HDT-HOST\HdtShare'
            $workspace.BootImage.Name | Should -BeExactly 'HDTPE_lab'
            $workspace.BootImage.Language | Should -BeExactly 'en-us'
            $workspace.BootImage.ScratchSpaceMB | Should -Be 256
            $workspace.BootImage.Drivers | Should -BeExactly 'boot-critical'
            $workspace.BootImage.EntryCommand | Should -BeLike '*Start-HDTDeployment.ps1'
            $workspace.BootImage.OptionalComponent |
                Should -Be @('WinPE-SecureStartup', 'WinPE-EnhancedStorage', 'WinPE-HTA')
            @($workspace.BootImage.ExtraContent | ForEach-Object { $_.Destination }) |
                Should -Be @('\HDT\Tools\BGInfo')
            $workspace.BootImage.StartCommand | Should -Be @('X:\HDT\Tools\BGInfo\bginfo.exe /timer:0')
        }

        It 'keeps the comment header the share was created with through a full edit and save' {
            # The header is the only documentation of deployRoot an administrator
            # has at the point of editing it. It is the reason these commands
            # splice rather than re-serialise, so an edit that lost it would
            # defeat the whole design.
            $script:captured = $null
            $fake = New-HDTFakeFileSystem -File @{ $script:share.Path = $script:written }
            $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
                param([string] $Path, [string] $Text)
                $script:captured = $Text
            }

            $after = Add-HDTBootImageContent -Line $script:shareLine `
                -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'
            $after = Add-HDTBootImageStartCommand -Line $after -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'

            $result = Save-HDTWorkspaceDocument -Path $script:share.Path -Line $after `
                -FileSystem $fake -Confirm:$false

            $result.Saved | Should -BeTrue
            $script:captured | Should -Match 'deployRoot is the path a machine that has booted the image uses to reach'
            $script:captured | Should -Match 'Everything not stated here takes an engine default'
        }

        It 'leaves every line of the share document it did not change byte-identical' {
            $after = Add-HDTBootImageContent -Line $script:shareLine `
                -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'

            Get-HDTTestRemovedLine -Before $script:shareLine -After $after | Should -BeNullOrEmpty
        }

        It 'gives the share workspace.yaml back byte for byte when nothing was changed' {
            $script:captured = $null
            $fake = New-HDTFakeFileSystem -File @{ $script:share.Path = $script:written }
            $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
                param([string] $Path, [string] $Text)
                $script:captured = $Text
            }

            [void] (Save-HDTWorkspaceDocument -Path $script:share.Path -Line $script:shareLine `
                    -FileSystem $fake -Confirm:$false)

            $script:captured | Should -BeExactly $script:written
        }
    }
}
