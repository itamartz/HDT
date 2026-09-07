function Get-HDTLabProtectedVm {
    <#
        .SYNOPSIS
            Every VM on this host that the repository did not create, and
            whether Hyper-V could be read at all.

        .DESCRIPTION
            THE SNAPSHOT THE LAB-SAFETY ASSERTION COMPARES. Each E2E suite takes
            one before it starts and one after it finishes, and proves they are
            identical - which is how "we touched no VM outside HDT-*" is a
            measurement rather than a promise.

            IT REPORTS READABILITY SEPARATELY FROM CONTENT, and that distinction
            is the whole reason this exists as a command.

            Every suite used to hand-roll the snapshot and then guard it with
            "the protected set must not be empty". The guard was right about the
            danger - comparing an empty snapshot with an empty snapshot passes
            while checking nothing, which is SPIKES S9.14 and happened here
            through six green runs - but it answered the danger with the wrong
            question. It cannot tell

              (a) Hyper-V could not be read, so the snapshot is meaningless

            from

              (b) Hyper-V was read perfectly well and this host genuinely has no
                  VM outside HDT-*

            and (b) is the NORMAL, CORRECT state of a dedicated CI runner. On
            2026-09-07 the E2E workflow on GHRUNNER01 - a runner built for
            nothing but this suite, whose only VMs are the ones the suite makes -
            failed four assertions for being exactly what it is supposed to be.

            SO THE QUESTION IS "DID THE ENUMERATION SUCCEED", NOT "DID IT RETURN
            ROWS". Get-VM is called with -ErrorAction Stop and the failure is
            caught: an unreadable Hyper-V sets Readable to $false, and an empty
            answer from a readable one is an empty Protected list with Readable
            $true. A suite asserts the first and compares the second.

            -ErrorAction SilentlyContinue WAS THE BUG UNDERNEATH THE BUG. It
            turns "Hyper-V is not there" into the same empty array as "there is
            nothing to report", which is precisely the ambiguity the count guard
            was invented to paper over.

            THE UNFILTERED Get-VM IS READ-ONLY, and is the one exception
            PROJECT.md rule 1 allows: you cannot prove you left the other VMs
            alone without listing them. Nothing here acts on a VM.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with:

              Readable   [bool]   Get-VM answered without throwing
              Total      [int]    every VM on the host, HDT-* included
              Protected  [object[]] the VMs not named HDT-*, sorted, as
                                   Name/State/Memory/Switch records
              Error      [string]  why it could not be read, when it could not

        .EXAMPLE
            $before = Get-HDTLabProtectedVm
            # ... the suite runs ...
            $after = Get-HDTLabProtectedVm

            $before.Readable | Should -BeTrue
            ($after.Protected | ConvertTo-Json -Depth 3) |
                Should -BeExactly ($before.Protected | ConvertTo-Json -Depth 3)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $answer = [pscustomobject] @{
        Readable  = $false
        Total     = 0
        Protected = @()
        Error     = ''
    }

    $all = @()

    try {
        # -ErrorAction Stop, DELIBERATELY. See the description: SilentlyContinue
        # is what made an absent Hyper-V indistinguishable from a quiet one.
        $all = @(Hyper-V\Get-VM -ErrorAction Stop)
        $answer.Readable = $true
    } catch {
        $answer.Error = [string] $_.Exception.Message
        return $answer
    }

    $answer.Total = $all.Count

    # MemoryStartup, NOT MemoryStartupBytes: the property is called
    # MemoryStartup on the object Get-VM returns.
    $answer.Protected = @($all |
            Where-Object { [string] $_.Name -notlike 'HDT-*' } |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject] @{
                    Name   = [string] $_.Name
                    State  = [string] $_.State
                    Memory = [long] $_.MemoryStartup
                    Switch = (@(Hyper-V\Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue |
                                ForEach-Object { [string] $_.SwitchName }) -join ',')
                }
            })

    return $answer
}
