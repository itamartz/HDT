# THE LAB MEMORY BUDGET, IN ONE PLACE, COUNTING ONLY WHAT THE HARNESS CREATED.
#
# Two things were wrong on 2026-09-06 and this file is the test for both.
#
# The number lived in SIX places - New-HDTLabVirtualMachine and five
# tests/e2e/*.E2E.Tests.ps1 files that each re-implemented the same running
# total inline. Raising it meant finding all six, and the seventh copy was one
# phase away. It now lives in Get-HDTLabMemoryBudget and everything asks.
#
# And it counted every running HDT-* VM, including the lab's own WSUS and WDS
# servers, which between them held exactly the whole old budget - so the harness
# could not create a single test VM. Membership is now decided by a marker the
# harness stamps into Notes at creation, which is a fact about what the harness
# DID rather than a name somebody remembered to write down. CLAUDE.md: "the rule
# is the HDT-* prefix, not a list of names - a name list rots, and this one did."
#
# NO DIGITS ARE WRITTEN OUT HERE. The expected values are built with PowerShell's
# own 32GB/8GB constants, so tests/contract/LabMemoryBudget.Contract.Tests.ps1
# can assert the byte literal exists in exactly one file without this file
# counting as a copy of it.
#
# EVERY ASSERTION RUNS WITHOUT HYPER-V. Get-HDTLabMemoryUse takes -VirtualMachine,
# and the rows below are hand-made [pscustomobject]s carrying the four properties
# Hyper-V\Get-VM returns and the real path reads. No VM is created, started,
# stopped or read.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:toolRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/tools'

    # A VM row as Hyper-V\Get-VM hands one over. Notes is empty by default,
    # which is what every VM on this host that the harness did not create has.
    function New-HDTTestVmRow {
        param(
            [string] $Name,
            [string] $State = 'Running',
            [long] $MemoryAssigned = 4GB,
            [string] $Notes = ''
        )

        return [pscustomobject] @{
            Name           = $Name
            State          = $State
            MemoryAssigned = $MemoryAssigned
            Notes          = $Notes
        }
    }

    function New-HDTTestStampedVmRow {
        param(
            [string] $Name,
            [string] $State = 'Running',
            [long] $MemoryAssigned = 4GB
        )

        return New-HDTTestVmRow -Name $Name -State $State -MemoryAssigned $MemoryAssigned -Notes (Get-HDTLabVmStamp)
    }

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

    # The infrastructure this host actually runs: two HDT-* VMs the harness did
    # not build, holding the whole of the OLD budget between them, with empty
    # Notes. Named here as TEST DATA - the code under test may not name them.
    $script:unstampedInfrastructure = @(
        (New-HDTTestVmRow -Name 'HDT-WSUS-01' -MemoryAssigned 8GB)
        (New-HDTTestVmRow -Name 'HDT-WDS-01' -MemoryAssigned 4GB)
    )
}

Describe 'Get-HDTLabMemoryBudget' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Get-HDTLabMemoryBudget' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'reports 32 GB as the combined budget' {
        (Get-HDTLabMemoryBudget).CombinedByte | Should -Be ([long] 32GB)
    }

    It 'reports 8 GB as the cap on a single test VM' {
        (Get-HDTLabMemoryBudget).PerVmByte | Should -Be ([long] 8GB)
    }

    It 'reports the numbers as text a message can quote' {
        # So a refusal says "32 GB" rather than a bare eleven-digit byte count.
        # A technician reads the first one.
        (Get-HDTLabMemoryBudget).CombinedText | Should -BeExactly '32 GB'
        (Get-HDTLabMemoryBudget).PerVmText | Should -BeExactly '8 GB'
    }

    It 'takes no parameter and touches no Hyper-V command' {
        # It is the one place the numbers live, so it must be readable from
        # anywhere - including a machine with no Hyper-V role installed.
        (Get-Command -Name 'Get-HDTLabMemoryBudget').Parameters.Keys |
            Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters } |
            Should -BeNullOrEmpty

        $ast = & $script:parseTool 'Get-HDTLabMemoryBudget'
        $ast | Should -Not -BeNullOrEmpty

        @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    ([string] $node.GetCommandName()) -like 'Hyper-V\*'
                }, $true)) | Should -BeNullOrEmpty
    }
}

Describe 'Get-HDTLabMemoryUse' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Get-HDTLabMemoryUse' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'counts a stamped running VM' {
        $use = Get-HDTLabMemoryUse -VirtualMachine @((New-HDTTestStampedVmRow -Name 'HDT-Unit-01' -MemoryAssigned 4GB))

        $use.AssignedByte | Should -Be ([long] 4GB)
        $use.Counted | Should -Be @('HDT-Unit-01')
    }

    It 'ignores a running HDT VM the harness did not stamp' {
        # The whole point. These two hold the entire old budget, so before the
        # stamp existed the harness could not create anything at all.
        $use = Get-HDTLabMemoryUse -VirtualMachine $script:unstampedInfrastructure

        $use.AssignedByte | Should -Be ([long] 0)
        @($use.Counted).Count | Should -Be 0
        @($use.Ignored).Count | Should -Be 2
    }

    It 'ignores a stamped VM that is not running' {
        # A VM that is Off holds no memory on the host.
        $use = Get-HDTLabMemoryUse -VirtualMachine @(
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-Off' -State 'Off' -MemoryAssigned 4GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-On' -MemoryAssigned 4GB)
        )

        $use.AssignedByte | Should -Be ([long] 4GB)
        $use.Counted | Should -Be @('HDT-Unit-On')
        $use.Ignored | Should -Be @('HDT-Unit-Off')
    }

    It 'reports the names it counted and the names it ignored' {
        # Both lists, because a refusal that says "0 bytes assigned" while
        # Hyper-V Manager shows two running VMs looks like a broken check.
        $use = Get-HDTLabMemoryUse -VirtualMachine @(
            $script:unstampedInfrastructure + @((New-HDTTestStampedVmRow -Name 'HDT-Unit-01' -MemoryAssigned 4GB))
        )

        $use.Counted | Should -Be @('HDT-Unit-01')
        @($use.Ignored) | Should -Contain 'HDT-WSUS-01'
        @($use.Ignored) | Should -Contain 'HDT-WDS-01'
    }

    It 'reports zero against an empty host' {
        $use = Get-HDTLabMemoryUse -VirtualMachine @()

        $use.AssignedByte | Should -Be ([long] 0)
        @($use.Counted).Count | Should -Be 0
        @($use.Ignored).Count | Should -Be 0
    }

    It 'names no virtual machine anywhere in its source' {
        # THE ASSERTION THAT KEEPS THE DESIGN HONEST. A name list rots; this one
        # already did, in the e2e lab-safety assertion that compared two empty
        # arrays and passed while checking nothing. Membership of the budget is
        # decided by the stamp and never by a name.
        #
        # Comments are exempt and code is not: the help may explain WHICH VMs
        # fall out and why. Only the comparison may not name one.
        $path = Join-Path -Path $script:toolRoot -ChildPath 'Get-HDTLabMemoryUse.ps1'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue

        $token = $null
        $parseError = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)

        $named = @($token |
                Where-Object { $_.Kind.ToString() -ne 'Comment' } |
                Where-Object { ([string] $_.Text) -match 'HDT-[A-Za-z0-9]' } |
                ForEach-Object { [string] $_.Text })

        $named | Should -BeNullOrEmpty -Because ('a VM name in the budget rule is the list rotting again: {0}' -f ($named -join '; '))
    }
}

Describe 'Assert-HDTLabMemoryBudget' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Assert-HDTLabMemoryBudget' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'accepts a 4 GB VM when 12 GB of unstamped infrastructure is running' {
        # This is the live host on 2026-09-06 and it is the case the whole plan
        # exists for.
        { Assert-HDTLabMemoryBudget -MemoryByte 4GB -Name 'HDT-Unit-01' `
                -VirtualMachine $script:unstampedInfrastructure } | Should -Not -Throw
    }

    It 'accepts a 4 GB VM when 24 GB of stamped VMs are running' {
        $running = @(
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-01' -MemoryAssigned 8GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-02' -MemoryAssigned 8GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-03' -MemoryAssigned 8GB)
        )

        { Assert-HDTLabMemoryBudget -MemoryByte 4GB -Name 'HDT-Unit-04' -VirtualMachine $running } |
            Should -Not -Throw
    }

    It 'refuses a 4 GB VM when 30 GB of stamped VMs are running' {
        $running = @(
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-01' -MemoryAssigned 8GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-02' -MemoryAssigned 8GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-03' -MemoryAssigned 8GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-04' -MemoryAssigned 6GB)
        )

        { Assert-HDTLabMemoryBudget -MemoryByte 4GB -Name 'HDT-Unit-05' -VirtualMachine $running } |
            Should -Throw '*32 GB*'
    }

    It 'refuses more memory than one test VM may take' {
        { Assert-HDTLabMemoryBudget -MemoryByte 12GB -Name 'HDT-Unit-01' -VirtualMachine @() } |
            Should -Throw '*8 GB*'
    }

    It 'names the running total, the budget and the VMs it counted in the refusal' {
        $running = @(
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-01' -MemoryAssigned 8GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-02' -MemoryAssigned 8GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-03' -MemoryAssigned 8GB)
            (New-HDTTestStampedVmRow -Name 'HDT-Unit-04' -MemoryAssigned 6GB)
        )

        $record = $null
        try {
            Assert-HDTLabMemoryBudget -MemoryByte 4GB -Name 'HDT-Unit-05' `
                -VirtualMachine ($running + $script:unstampedInfrastructure)
        } catch {
            $record = $_
        }

        $record | Should -Not -BeNullOrEmpty
        $message = [string] $record.Exception.Message

        $message | Should -BeLike '*HDT-Unit-05*'          # the VM being started
        $message | Should -BeLike '*HDT-Unit-01*'          # the VMs it counted
        $message | Should -BeLike '*32 GB*'                # the budget
        $message | Should -BeLike ('*{0}*' -f ([long] 30GB))   # the running total

        # And how many it IGNORED, because "0 counted" against a Hyper-V Manager
        # showing running VMs otherwise reads as a broken check.
        $message | Should -BeLike '*ignored*'
    }

    It 'names the lab safety rule it is enforcing' {
        # The person who hits this is about to argue with it.
        { Assert-HDTLabMemoryBudget -MemoryByte 12GB -Name 'HDT-Unit-01' -VirtualMachine @() } |
            Should -Throw '*rule 4*'
        { Assert-HDTLabMemoryBudget -MemoryByte 12GB -Name 'HDT-Unit-01' -VirtualMachine @() } |
            Should -Throw '*PROJECT.md*'
    }
}
