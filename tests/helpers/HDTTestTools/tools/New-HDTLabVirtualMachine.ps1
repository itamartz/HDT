function New-HDTLabVirtualMachine {
    <#
        .SYNOPSIS
            Creates a Generation 2 HDT test VM on the isolated 'HDT Lab' switch.

        .DESCRIPTION
            PROJECT.md's Hyper-V lab safety rules, enforced in code before any
            Hyper-V call is made. This host runs the user's LIVE lab, so the
            rules are not advice:

              rule 1  the name must be HDT-*, and never CM01 or DC01
                      (Assert-HDTLabVmName)
              rule 2  the switch must be 'HDT Lab' - the isolated internal one.
                      'Default Switch' carries the user's 192.168.25.0/24 lab
                      and CM01's PXE responder; a test VM there would either
                      break their lab or be answered by SCCM, which silently
                      invalidates the test
              rule 4  memory. All HDT VMs stay under 12 GB combined, so one test
                      VM may not take more than 8 GB, and the total already
                      assigned to running HDT-* VMs is checked before this one
                      is created
              rule 5  every VHD lives under C:\HDTLab\vms, not the host default
                      C:\HyperVVMs where the user's own VMs are
              rule 6  Generation 2 - UEFI and Secure Boot, which is what HDT
                      targets and what the -NoPromptForKey UEFI ISO needs

            EVERY HYPER-V COMMAND IS MODULE-QUALIFIED. SPIKES S8: PowerCLI is
            installed on this host and shadows Get-VM, so 'Hyper-V\Get-VM' is
            the only form that certainly means Hyper-V's.

            The DVD drive is put FIRST in the firmware boot order, which is what
            makes the VM boot WinPE on the first start - and what makes
            ConfigureBoot's firmware reorder observable on the second, because
            a machine that still boots the ISO has not been reconfigured.

        .PARAMETER Name
            The VM name. Must be HDT-*.

        .PARAMETER MemoryByte
            Startup memory, static. 4 GB is the lab standard.

        .PARAMETER ProcessorCount
            Virtual processors.

        .PARAMETER SwitchName
            Must be 'HDT Lab'.

        .PARAMETER VhdPath
            One or more existing VHDXs to attach, in order. All must be under
            C:\HDTLab\vms.

        .PARAMETER IsoPath
            An ISO for the DVD drive. Omitted, no DVD drive is attached.

        .PARAMETER Generation
            Must be 2. The parameter exists so that the refusal can be tested.

        .OUTPUTS
            The Microsoft.HyperV.PowerShell.VirtualMachine that was created.

        .EXAMPLE
            New-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -MemoryByte 4294967296 `
                -ProcessorCount 2 -SwitchName 'HDT Lab' `
                -VhdPath 'C:\HDTLab\vms\HDT-M3-Deploy\os.vhdx' `
                -IsoPath 'C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso'
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [long] $MemoryByte,

        [Parameter(Mandatory = $true)]
        [int] $ProcessorCount,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $SwitchName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $VhdPath,

        [Parameter()]
        [AllowEmptyString()]
        [string] $IsoPath,

        [Parameter()]
        [int] $Generation = 2
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $labSwitch = 'HDT Lab'
    $vmRoot = 'C:\HDTLab\vms'
    $maximumVmByte = 8589934592     # 8 GB for one VM
    $maximumLabByte = 12884901888   # 12 GB for all of them together

    # -- the guards, before any Hyper-V call -------------------------------

    Assert-HDTLabVmName -Name $Name

    if ($Generation -ne 2) {
        throw ("Generation {0} is not what HDT targets. HDT test VMs are Generation 2 - UEFI and Secure Boot - which is what the uefi-standard layout and the -NoPromptForKey UEFI ISO require (PROJECT.md, 'Hyper-V lab safety rules', rule 6)." -f $Generation)
    }

    if ($SwitchName -ne $labSwitch) {
        throw ("'{0}' is not the '{1}' switch. HDT test VMs attach ONLY to '{1}': 'Default Switch' carries the user's lab and CM01's PXE responder, and a test VM there would either break their lab or be answered by SCCM (PROJECT.md, 'Hyper-V lab safety rules', rule 2 and 3)." -f $SwitchName, $labSwitch)
    }

    foreach ($path in @($VhdPath)) {
        if (-not ($path -like ('{0}\*' -f $vmRoot))) {
            throw ("'{0}' is not under {1}. HDT test VM files go there, not to the host default C:\HyperVVMs where the user's own machines live (PROJECT.md, 'Hyper-V lab safety rules', rule 5)." -f $path, $vmRoot)
        }
    }

    if ($MemoryByte -gt $maximumVmByte) {
        throw ("{0} bytes is more than one HDT test VM may take. The whole lab budget is 12 GB combined and the host has about 22 GB free with CM01 using dynamic memory, so a single test VM is capped at 8 GB - 4 GB is the standard (PROJECT.md, 'Hyper-V lab safety rules', rule 4)." -f $MemoryByte)
    }

    # -- the memory budget, across every RUNNING HDT VM --------------------
    #
    # Name-filtered, never an unfiltered pipeline (rule 1).

    $running = @(Hyper-V\Get-VM -Name 'HDT-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq 'Running' })

    $assigned = [long] 0
    foreach ($vm in $running) {
        $assigned += [long] $vm.MemoryAssigned
    }

    if (($assigned + $MemoryByte) -gt $maximumLabByte) {
        throw ("Starting '{0}' with {1} bytes would put the running HDT VMs over the 12 GB lab budget ({2} bytes already assigned to {3} running HDT VM(s)). Shut one down first (PROJECT.md, 'Hyper-V lab safety rules', rule 4)." -f
            $Name, $MemoryByte, $assigned, $running.Count)
    }

    # -- create it ---------------------------------------------------------

    if (-not $PSCmdlet.ShouldProcess($Name, ("Create a Generation 2 VM on the '{0}' switch" -f $labSwitch))) {
        return $null
    }

    $vmPath = Join-Path -Path $vmRoot -ChildPath $Name
    if (-not (Test-Path -LiteralPath $vmPath -PathType Container)) {
        New-Item -Path $vmPath -ItemType Directory -Force | Out-Null
    }

    $vm = Hyper-V\New-VM -Name $Name -MemoryStartupBytes $MemoryByte -Generation 2 `
        -SwitchName $labSwitch -Path $vmRoot -NoVHD

    Hyper-V\Set-VM -Name $Name -ProcessorCount $ProcessorCount -AutomaticCheckpointsEnabled $false
    Hyper-V\Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false

    foreach ($path in @($VhdPath)) {
        Hyper-V\Add-VMHardDiskDrive -VMName $Name -Path $path
    }

    # Secure Boot on, with the Microsoft Windows template - SPIKES S3 booted the
    # no-prompt ISO in exactly this configuration.
    Hyper-V\Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'

    if (-not [string]::IsNullOrWhiteSpace($IsoPath)) {
        Hyper-V\Add-VMDvdDrive -VMName $Name -Path $IsoPath

        $dvd = Hyper-V\Get-VMDvdDrive -VMName $Name
        Hyper-V\Set-VMFirmware -VMName $Name -FirstBootDevice $dvd
    }

    return $vm
}
