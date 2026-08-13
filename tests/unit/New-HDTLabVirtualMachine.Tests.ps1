# The lab helpers, asserted through their REFUSALS.
#
# PROJECT.md's Hyper-V lab safety rules are not advice. This host runs the
# user's live lab: CM01 is a Configuration Manager server with a PXE responder
# and DC01 is the domain controller. Every rule below is therefore enforced in
# code, before any Hyper-V call, rather than remembered by the person running
# the test.
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

    It 'refuses the name CM01' {
        { Assert-HDTLabVmName -Name 'CM01' } | Should -Throw '*CM01*'
    }

    It 'refuses the name DC01' {
        { Assert-HDTLabVmName -Name 'DC01' } | Should -Throw '*DC01*'
    }

    It 'refuses CM01 whatever the casing' {
        { Assert-HDTLabVmName -Name 'cm01' } | Should -Throw '*CM01*'
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
        { Assert-HDTLabVmName -Name 'CM01' } | Should -Throw '*PROJECT.md*'
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

        It 'refuses the name CM01' {
            { New-HDTLabVirtualMachine -Name 'CM01' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'HDT Lab' -VhdPath $script:legalVhd } | Should -Throw '*CM01*'
        }

        It 'refuses the name DC01' {
            { New-HDTLabVirtualMachine -Name 'DC01' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'HDT Lab' -VhdPath $script:legalVhd } | Should -Throw '*DC01*'
        }

        It 'refuses a switch that is not HDT Lab' {
            # PROJECT.md rule 3: PXE/WDS testing on Default Switch would collide
            # with CM01's PXE - either breaking the lab or silently answering our
            # test VMs and invalidating the test.
            { New-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -MemoryByte 4294967296 -ProcessorCount 2 `
                    -SwitchName 'Default Switch' -VhdPath $script:legalVhd } | Should -Throw '*HDT Lab*'
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
            # PROJECT.md rule 4: all HDT VMs under 12 GB combined, on a host with
            # ~22 GB free and CM01 using dynamic memory.
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

        It 'refuses the name CM01' {
            { Remove-HDTLabVirtualMachine -Name 'CM01' -Confirm:$false } | Should -Throw '*CM01*'
        }

        It 'refuses the name DC01' {
            { Remove-HDTLabVirtualMachine -Name 'DC01' -Confirm:$false } | Should -Throw '*DC01*'
        }

        It 'refuses a wildcard name' {
            { Remove-HDTLabVirtualMachine -Name 'HDT-*' -Confirm:$false } | Should -Throw '*wildcard*'
        }

        It 'names the lab safety rule it is enforcing' {
            { Remove-HDTLabVirtualMachine -Name 'DC01' -Confirm:$false } | Should -Throw '*PROJECT.md*'
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
