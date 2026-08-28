# The lab helpers, asserted through their REFUSALS.
#
# PROJECT.md's Hyper-V lab safety rules are not advice. This host is the user's
# own machine and carries VMs this repository did not create. Every rule below
# is therefore enforced in code, before any Hyper-V call, rather than remembered
# by the person running the test.
#
# THE PROTECTED SET IS A PREFIX, NOT A LIST OF NAMES. These tests used to name
# 'CM01' and 'DC01' - two VMs retired on 2026-08-29 - and a refusal asserted
# against a machine that has stopped existing proves nothing about the machine
# that replaces it. Every refusal below is asserted against a SET of names the
# guard has never been told about, so it fails for the next VM the user builds
# and not only for the two somebody remembered.
#
# EVERY ASSERTION IN THIS FILE IS A REFUSAL, and every refusal happens before
# the first Hyper-V command - so this file runs in the normal unit suite, on a
# machine with no Hyper-V at all, and never creates, starts or removes anything.
#
# WHY THERE IS NO Mock ON Hyper-V\New-VM. The plan asked for one. It cannot
# work: the helpers call 'Hyper-V\New-VM' module-qualified (SPIKES S8 - PowerCLI
# shadows Get-VM on this host), and a module-qualified call resolves straight
# into the module without going through the function table Pester's Mock injects
# into. A mock that is never consulted is an assertion that always passes, which
# is worse than no assertion. What replaces it is stronger and runs everywhere:
# the AST assertions below prove every Hyper-V command in the helpers is
# module-qualified, and that the safety guard is called before the first one.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:toolRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/tools'

    $script:parseTool = {
        param([string] $BaseName)

        $path = Join-Path -Path $script:toolRoot -ChildPath ('{0}.ps1' -f $BaseName)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $null
        }

        $parseError = $null
        $token = $null
        return [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)
    }

    # Every command in a file whose name is module-qualified into Hyper-V, and
    # every command whose bare name is one Hyper-V also exports.
    $script:hyperVCall = {
        param([object] $Ast)

        return @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    ([string] $node.GetCommandName()) -like 'Hyper-V\*'
                }, $true))
    }

    $script:namedCall = {
        param([object] $Ast, [string] $Name)

        $wanted = $Name
        return @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true))
    }

    # A VHD path that is legal, so a name refusal is proven to be about the name.
    $script:legalVhd = 'C:\HDTLab\vms\HDT-Unit\HDT-Unit-osdisk.vhdx'
}

Describe 'Assert-HDTLabVmName' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Assert-HDTLabVmName' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'refuses a name that does not start with HDT-' {
        { Assert-HDTLabVmName -Name 'SomeOtherVm' } | Should -Throw '*HDT-*'
    }

    It 'refuses every VM name this repository did not create, and names it back' {
        # A SET, not one name. The guard has been told about none of these, which
        # is the point: it must refuse whatever the user builds next without
        # anyone remembering to add it. The message quotes the name back so the
        # person reading the failure knows which VM they nearly touched.
        foreach ($name in @('SomeOtherVm', 'FileServer', 'Ubuntu-Dev', 'hdt', 'HDT', 'HDTNoDash')) {
            { Assert-HDTLabVmName -Name $name } | Should -Throw ('*{0}*' -f $name)
        }
    }

    It 'refuses a wildcard name' {
        # 'HDT-*' as an argument would remove every test VM at once, and someone
        # will eventually type it.
        foreach ($name in @('HDT-*', 'HDT-?', 'HDT-[abc]')) {
            { Assert-HDTLabVmName -Name $name } | Should -Throw '*wildcard*'
        }
    }

    It 'names the lab safety rule it is enforcing' {
        # The person who hits this is about to argue with it, so the message
        # points at the document that settles the argument.
        { Assert-HDTLabVmName -Name 'HDT-*' } | Should -Throw '*PROJECT.md*'
        { Assert-HDTLabVmName -Name 'SomeOtherVm' } | Should -Throw '*PROJECT.md*'
    }

    It 'accepts a well formed HDT test VM name' {
        { Assert-HDTLabVmName -Name 'HDT-M3-Deploy' } | Should -Not -Throw
    }
}

Describe 'New-HDTLabVirtualMachine' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'New-HDTLabVirtualMachine' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context 'the refusals' {

        It 'refuses a name that does not start with HDT-' {
            { New-HDTLabVirtualMachine -Name 'SomeOtherVm' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'HDT Lab' -VhdPath $script:legalVhd } | Should -Throw '*HDT-*'
        }

        It 'refuses every VM name this repository did not create' {
            # A SET, not a list of remembered names - see the header.
            foreach ($name in @('FileServer', 'Ubuntu-Dev', 'HDTNoDash')) {
                { New-HDTLabVirtualMachine -Name $name -MemoryByte 4294967296 -ProcessorCount 2 `
                        -SwitchName 'HDT Lab' -VhdPath $script:legalVhd } | Should -Throw ('*{0}*' -f $name)
            }
        }

        It 'refuses Default Switch, which is not the deployment subnet' {
            # PROJECT.md rules 2 and 3. 'Default Switch' is Hyper-V's own shared
            # NAT switch - 172.25.16.1/20 on this host - so a VM there cannot
            # reach the share the way one on 'HDT External' can, and it shares a
            # segment with whatever else Hyper-V puts on it. A green deployment
            # over the wrong network is worse than a red one. THIS IS THE ONE
            # THAT MUST NEVER RELAX, and it is asserted separately from the two
            # allowed switches below so that widening the allow-list cannot
            # quietly widen this.
            { New-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'Default Switch' -VhdPath $script:legalVhd } | Should -Throw '*Default Switch*'
        }

        It 'refuses a switch that is neither HDT Lab nor HDT External' {
            { New-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'FSE Switch' -VhdPath $script:legalVhd } | Should -Throw '*HDT External*'
        }

        It 'accepts HDT External, the switch a share deployment needs' {
            # PROJECT.md's network rule: the lab network is 192.168.2.0/24, DHCP
            # comes from the real LAN and test VMs reach it through 'HDT
            # External'. A VM on the ISOLATED 'HDT Lab' switch gets no lease and
            # cannot reach a share on the host (SPIKES S6), which is the whole
            # reason no deployment had ever run over SMB.
            #
            # ASSERTED AS "does not throw the switch refusal", not as a full
            # creation: creating a VM belongs to the e2e suite, and this file
            # runs in the fast one.
            $record = $null
            try {
                New-HDTLabVirtualMachine -Name 'HDT-Smb-Probe' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'HDT External' -VhdPath $script:legalVhd -WhatIf
            } catch {
                $record = $_
            }

            [string] $record | Should -Not -BeLike '*is not the*switch*'
            [string] $record | Should -Not -BeLike '*HDT External*is not*'
        }

        It 'refuses a VHD path outside C:\HDTLab\vms' {
            # PROJECT.md rule 5: VM files go to C:\HDTLab\vms, not the host
            # default C:\HyperVVMs where the user's own VMs live.
            { New-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'HDT Lab' -VhdPath 'C:\HyperVVMs\HDT-M3-Deploy.vhdx' } | Should -Throw '*C:\HDTLab\vms*'
        }

        It 'refuses a second VHD path outside C:\HDTLab\vms' {
            # Every path in the array, not just the first.
            { New-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'HDT Lab' -VhdPath @($script:legalVhd, 'D:\elsewhere\content.vhdx') } |
                Should -Throw '*C:\HDTLab\vms*'
        }

        It 'refuses a generation other than 2' {
            # PROJECT.md rule 6: Generation 2 is what HDT targets and what the
            # UEFI layout and the -NoPromptForKey ISO path require.
            { New-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'HDT Lab' -VhdPath $script:legalVhd -Generation 1 } | Should -Throw '*Generation 2*'
        }

        It 'refuses more memory than the lab budget allows' {
            # PROJECT.md rule 4: all HDT VMs under 12 GB combined, on a host
            # whose free memory moves with whatever else is running.
            { New-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -MemoryByte 17179869184 -ProcessorCount 2 `
                    -SwitchName 'HDT Lab' -VhdPath $script:legalVhd } | Should -Throw '*12*'
        }

        It 'names the lab safety rule it is enforcing' {
            { New-HDTLabVirtualMachine -Name 'SomeOtherVm' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'HDT Lab' -VhdPath $script:legalVhd } | Should -Throw '*PROJECT.md*'
        }
    }

    Context 'the guard runs before any Hyper-V command' {

        It 'module-qualifies every Hyper-V command' {
            # SPIKES S8: PowerCLI shadows Get-VM on this host, so an unqualified
            # Get-VM is not necessarily Hyper-V's.
            $ast = & $script:parseTool 'New-HDTLabVirtualMachine'
            $ast | Should -Not -BeNullOrEmpty

            $bare = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        ([string] $node.GetCommandName()) -match '^(New|Get|Set|Start|Stop|Remove|Add|Connect|Enable|Disable)-VM'
                    }, $true))

            $bare | Should -BeNullOrEmpty -Because 'every Hyper-V call must be written Hyper-V\<command>'

            @(& $script:hyperVCall $ast).Count | Should -BeGreaterThan 0
        }

        It 'calls Assert-HDTLabVmName before the first Hyper-V command' {
            $ast = & $script:parseTool 'New-HDTLabVirtualMachine'

            $guard = @(& $script:namedCall $ast 'Assert-HDTLabVmName')
            $guard.Count | Should -BeGreaterOrEqual 1

            $firstHyperV = @(& $script:hyperVCall $ast | Sort-Object { $_.Extent.StartOffset })[0]

            $guard[0].Extent.StartOffset | Should -BeLessThan $firstHyperV.Extent.StartOffset
        }

        It 'carries SupportsShouldProcess' {
            (Get-Command -Name 'New-HDTLabVirtualMachine').Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }
    }
}

Describe 'Remove-HDTLabVirtualMachine' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context 'the refusals' {

        It 'refuses a name that does not start with HDT-' {
            { Remove-HDTLabVirtualMachine -Name 'SomeOtherVm' -Confirm:$false } | Should -Throw '*HDT-*'
        }

        It 'refuses every VM name this repository did not create' {
            # A SET, not a list of remembered names - see the header.
            foreach ($name in @('FileServer', 'Ubuntu-Dev', 'HDTNoDash')) {
                { Remove-HDTLabVirtualMachine -Name $name -Confirm:$false } | Should -Throw ('*{0}*' -f $name)
            }
        }

        It 'refuses a wildcard name' {
            { Remove-HDTLabVirtualMachine -Name 'HDT-*' -Confirm:$false } | Should -Throw '*wildcard*'
        }

        It 'names the lab safety rule it is enforcing' {
            { Remove-HDTLabVirtualMachine -Name 'SomeOtherVm' -Confirm:$false } | Should -Throw '*PROJECT.md*'
        }
    }

    Context 'the guard runs before any Hyper-V command' {

        It 'module-qualifies every Hyper-V command' {
            $ast = & $script:parseTool 'Remove-HDTLabVirtualMachine'
            $ast | Should -Not -BeNullOrEmpty

            $bare = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        ([string] $node.GetCommandName()) -match '^(New|Get|Set|Start|Stop|Remove|Add|Connect|Enable|Disable)-VM'
                    }, $true))

            $bare | Should -BeNullOrEmpty
            @(& $script:hyperVCall $ast).Count | Should -BeGreaterThan 0
        }

        It 'calls Assert-HDTLabVmName before the first Hyper-V command' {
            $ast = & $script:parseTool 'Remove-HDTLabVirtualMachine'

            $guard = @(& $script:namedCall $ast 'Assert-HDTLabVmName')
            $guard.Count | Should -BeGreaterOrEqual 1

            $firstHyperV = @(& $script:hyperVCall $ast | Sort-Object { $_.Extent.StartOffset })[0]

            $guard[0].Extent.StartOffset | Should -BeLessThan $firstHyperV.Extent.StartOffset
        }

        It 'carries SupportsShouldProcess' {
            (Get-Command -Name 'Remove-HDTLabVirtualMachine').Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }
    }

    Context 'what it is allowed to delete' {

        # DURING 04-04 THE CONTENTS OF C:\HDTLab\vms WERE LOST - including
        # HDT-PE-Test and the SPIKES S7/S8 disk that sat loose at the ROOT of
        # that folder. The cause was never established: no helper names anything
        # but the exact VM it was given, and the user was working in the same
        # lab at the time. What IS established is that the helper's delete was
        # not narrow enough to make the accident impossible, and these
        # assertions close that.

        # NO ANGLE BRACKETS IN A TEST NAME. Pester expands <something> in an It
        # name as a variable placeholder for data-driven tests, so
        # 'deletes only <vmRoot>\<Name>' becomes an attempt to read $vmRoot -
        # which throws under the StrictMode build.ps1 sets, and only there.
        It 'deletes only the VM own folder, never the VM root itself' {
            $path = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/tools/Remove-HDTLabVirtualMachine.ps1'
            $text = Get-Content -LiteralPath $path -Raw

            # A guard on the folder about to be removed, naming the root it may
            # not be. Without it an empty or odd $Name makes Join-Path yield the
            # root and Remove-Item -Recurse empties the whole lab.
            $text | Should -Match 'Assert-HDTLabVmPath'
        }

        It 'refuses a path that is the VM root' {
            { Assert-HDTLabVmPath -Path 'C:\HDTLab\vms' -Name 'HDT-M3-Smoke' } | Should -Throw '*C:\HDTLab\vms*'
        }

        It 'refuses a path outside the VM root' {
            { Assert-HDTLabVmPath -Path 'C:\HyperVVMs\Something' -Name 'HDT-M3-Smoke' } | Should -Throw '*C:\HDTLab\vms*'
        }

        It 'refuses a file that sits loose in the VM root rather than in a VM folder' {
            # HDT-PE-Test-osdisk.vhdx lived exactly there. A disk at the root of
            # the lab belongs to no HDT-M3 VM and no helper may remove it.
            { Assert-HDTLabVmPath -Path 'C:\HDTLab\vms\HDT-PE-Test-osdisk.vhdx' -Name 'HDT-M3-Smoke' } |
                Should -Throw '*HDT-M3-Smoke*'
        }

        It 'refuses another VM folder' {
            { Assert-HDTLabVmPath -Path 'C:\HDTLab\vms\HDT-PE-Test' -Name 'HDT-M3-Smoke' } |
                Should -Throw '*HDT-M3-Smoke*'
        }

        It 'accepts this VM own folder and the files inside it' {
            { Assert-HDTLabVmPath -Path 'C:\HDTLab\vms\HDT-M3-Smoke' -Name 'HDT-M3-Smoke' } | Should -Not -Throw
            { Assert-HDTLabVmPath -Path 'C:\HDTLab\vms\HDT-M3-Smoke\os.vhdx' -Name 'HDT-M3-Smoke' } | Should -Not -Throw
        }

        It 'names the lab safety rule it is enforcing' {
            { Assert-HDTLabVmPath -Path 'C:\HDTLab\vms' -Name 'HDT-M3-Smoke' } | Should -Throw '*PROJECT.md*'
        }
    }
}

Describe 'every lab helper' {

    It 'module-qualifies every Hyper-V command it makes' {
        $labTool = @(Get-ChildItem -Path $script:toolRoot -Filter '*HDTLab*.ps1')
        $labTool.Count | Should -BeGreaterThan 0

        $violation = @()
        foreach ($file in $labTool) {
            $parseError = $null
            $token = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $token, [ref] $parseError)

            $violation += @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        ([string] $node.GetCommandName()) -match '^(New|Get|Set|Start|Stop|Remove|Add|Connect|Enable|Disable|Restart|Save|Suspend|Resume)-VM'
                    }, $true) | ForEach-Object { '{0}: {1}' -f $file.Name, $_.GetCommandName() })
        }

        $violation | Should -BeNullOrEmpty -Because ($violation -join '; ')
    }

    It 'never writes an unfiltered Hyper-V pipeline' {
        # PROJECT.md rule 1: never 'Get-VM | Remove-VM' or any unfiltered
        # pipeline. Every Get-VM in a lab helper names a VM.
        $labTool = @(Get-ChildItem -Path $script:toolRoot -Filter '*HDTLab*.ps1')

        $violation = @()
        foreach ($file in $labTool) {
            $parseError = $null
            $token = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $token, [ref] $parseError)

            $violation += @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        ([string] $node.GetCommandName()) -eq 'Hyper-V\Get-VM'
                    }, $true) |
                    Where-Object { ([string] $_.Extent.Text) -notlike '*-Name*' -and ([string] $_.Extent.Text) -notlike '*-Id*' } |
                    ForEach-Object { '{0}: {1}' -f $file.Name, $_.Extent.Text })
        }

        $violation | Should -BeNullOrEmpty -Because ($violation -join '; ')
    }
}
