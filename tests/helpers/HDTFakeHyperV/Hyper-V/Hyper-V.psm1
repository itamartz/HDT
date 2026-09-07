# A MODULE CALLED Hyper-V THAT TOUCHES NO HYPERVISOR.
#
# WHY IT HAS TO BE CALLED THAT, and why nothing else would do. The lab helpers
# write every hypervisor call module-qualified - Hyper-V\New-VM - because
# PowerCLI shadows Get-VM on this host (SPIKES S8). A module-qualified call
# resolves straight into the module named on the left of the backslash and never
# goes through the function table Pester's Mock injects into, so
# New-HDTLabVirtualMachine's guards - the stamp, Generation 2, and the budget
# that counts stamped VMs only - were provable only by reading its source. This
# is the only thing a module-qualified call CAN be pointed at: a module with
# that name, imported BY PATH before the real one is ever asked for.
#
# THE COMMAND NAMES ARE HYPER-V'S AND NOT Verb-HDTNoun, deliberately, and this
# is the one place in the repository where that is true. Impersonating those
# exact names is the entire mechanism; a Verb-HDTNoun here would be a fake
# nothing calls. Everything that is NOT an impersonation - the recorder, the
# seeding, the reset - carries the prefix (CLAUDE.md rule 3).
#
# THE NAMING CONTRACT DOES SCAN THIS FILE, and excuses exactly these eight names
# and no others - Naming.Contract.Tests.ps1, $script:HDTImpersonation. The
# exemption is written there rather than in Get-HDTSourceFile so that
# PSScriptAnalyzer and the PowerShell 5.1 syntax contract still cover this file:
# it is excused the naming rule and nothing else. Rule 3 exists because the
# engine dot-sources user scripts from Scripts\ and third-party step types from
# Modules\ inside WinPE, where an unprefixed name is a live collision. Nothing
# ships this module, nothing imports it but one test file, and that file removes
# it again in AfterAll.
#
# THE FIX THAT WOULD DELETE THIS FILE is an injected hypervisor service, the way
# the engine injects IDiskService and IImageService (CLAUDE.md rule 5). There
# would then be nothing to shadow. It means a new parameter on
# New-HDTLabVirtualMachine and a change at every e2e call site, which is why it
# is written down here rather than done in passing.
#
# IT CREATES NOTHING AND IT CANNOT. There is no hypervisor code path in this
# file: every function appends a record to a list and returns a plain object. If
# this module is the loaded one, no VM can be made whatever the caller does. The
# danger is the reverse - the caller reaching the REAL module - which is why the
# test that uses this refuses to invoke anything until it has proved that the
# loaded Hyper-V module is this file.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HDTFakeCall = New-Object -TypeName System.Collections.ArrayList
$script:HDTFakeVirtualMachine = @()

function Add-HDTFakeHyperVCall {
    <#
        .SYNOPSIS
            Records one impersonated command and what it was handed.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [hashtable] $Argument
    )

    [void] $script:HDTFakeCall.Add([pscustomobject] @{
            Command  = $Command
            Argument = $Argument
        })
}

function Get-HDTFakeHyperVCall {
    <#
        .SYNOPSIS
            Every hypervisor command the code under test made, in order.

        .PARAMETER Command
            Only the calls to this command. Omitted, all of them.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Command
    )

    if ([string]::IsNullOrEmpty($Command)) { return @($script:HDTFakeCall) }

    return @($script:HDTFakeCall | Where-Object { $_.Command -eq $Command })
}

function Clear-HDTFakeHyperVCall {
    <#
        .SYNOPSIS
            Forgets every recorded call and every seeded VM.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $script:HDTFakeCall.Clear()
    $script:HDTFakeVirtualMachine = @()
}

function Set-HDTFakeHyperVVirtualMachine {
    <#
        .SYNOPSIS
            What Get-VM will answer with.

        .DESCRIPTION
            A row needs Name, State, MemoryAssigned and Notes - the four
            properties Get-HDTLabMemoryUse reads and the only four the live path
            reads.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It changes nothing outside the caller. Every function in this module appends to an in-memory list; there is no hypervisor and no host state to confirm before touching.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $VirtualMachine
    )

    $script:HDTFakeVirtualMachine = @($VirtualMachine)
}

# -- the impersonations ----------------------------------------------------
#
# Each takes the parameters the lab helpers actually pass, records them and
# returns a plain object. Nothing here reaches a hypervisor.

function New-VM {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Overwriting the name is the entire mechanism. A module-qualified call resolves into the module of that name and nowhere else, so a substitute has to carry the same name. See the file header.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It changes nothing outside the caller. Every function in this module appends to an in-memory list; there is no hypervisor and no host state to confirm before touching.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string] $Name,
        [long] $MemoryStartupBytes,
        [int] $Generation,
        [string] $SwitchName,
        [string] $Path,
        [switch] $NoVHD
    )

    Add-HDTFakeHyperVCall -Command 'New-VM' -Argument @{
        Name               = $Name
        MemoryStartupBytes = $MemoryStartupBytes
        Generation         = $Generation
        SwitchName         = $SwitchName
        Path               = $Path
        NoVHD              = [bool] $NoVHD
    }

    return [pscustomobject] @{
        Name           = $Name
        Generation     = $Generation
        State          = 'Off'
        MemoryAssigned = $MemoryStartupBytes
        Notes          = ''
    }
}

function Get-VM {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Overwriting the name is the entire mechanism. A module-qualified call resolves into the module of that name and nowhere else, so a substitute has to carry the same name. See the file header.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string] $Name,
        [object] $Id
    )

    Add-HDTFakeHyperVCall -Command 'Get-VM' -Argument @{ Name = $Name; Id = $Id }

    if ([string]::IsNullOrEmpty($Name)) { return @($script:HDTFakeVirtualMachine) }

    return @($script:HDTFakeVirtualMachine | Where-Object { $_.Name -like $Name })
}

function Set-VM {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Overwriting the name is the entire mechanism. A module-qualified call resolves into the module of that name and nowhere else, so a substitute has to carry the same name. See the file header.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It changes nothing outside the caller. Every function in this module appends to an in-memory list; there is no hypervisor and no host state to confirm before touching.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $Name,
        [int] $ProcessorCount,
        [object] $AutomaticCheckpointsEnabled,
        [string] $Notes
    )

    Add-HDTFakeHyperVCall -Command 'Set-VM' -Argument @{
        Name                        = $Name
        ProcessorCount              = $ProcessorCount
        AutomaticCheckpointsEnabled = $AutomaticCheckpointsEnabled
        Notes                       = $Notes
    }
}

function Set-VMMemory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Overwriting the name is the entire mechanism. A module-qualified call resolves into the module of that name and nowhere else, so a substitute has to carry the same name. See the file header.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It changes nothing outside the caller. Every function in this module appends to an in-memory list; there is no hypervisor and no host state to confirm before touching.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $VMName,
        [object] $DynamicMemoryEnabled
    )

    Add-HDTFakeHyperVCall -Command 'Set-VMMemory' -Argument @{
        VMName               = $VMName
        DynamicMemoryEnabled = $DynamicMemoryEnabled
    }
}

function Add-VMHardDiskDrive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Overwriting the name is the entire mechanism. A module-qualified call resolves into the module of that name and nowhere else, so a substitute has to carry the same name. See the file header.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $VMName,
        [string] $Path
    )

    Add-HDTFakeHyperVCall -Command 'Add-VMHardDiskDrive' -Argument @{ VMName = $VMName; Path = $Path }
}

function Set-VMFirmware {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Overwriting the name is the entire mechanism. A module-qualified call resolves into the module of that name and nowhere else, so a substitute has to carry the same name. See the file header.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It changes nothing outside the caller. Every function in this module appends to an in-memory list; there is no hypervisor and no host state to confirm before touching.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $VMName,
        [string] $EnableSecureBoot,
        [string] $SecureBootTemplate,
        [object] $FirstBootDevice
    )

    Add-HDTFakeHyperVCall -Command 'Set-VMFirmware' -Argument @{
        VMName             = $VMName
        EnableSecureBoot   = $EnableSecureBoot
        SecureBootTemplate = $SecureBootTemplate
        FirstBootDevice    = $FirstBootDevice
    }
}

function Add-VMDvdDrive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Overwriting the name is the entire mechanism. A module-qualified call resolves into the module of that name and nowhere else, so a substitute has to carry the same name. See the file header.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $VMName,
        [string] $Path
    )

    Add-HDTFakeHyperVCall -Command 'Add-VMDvdDrive' -Argument @{ VMName = $VMName; Path = $Path }
}

function Get-VMDvdDrive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Overwriting the name is the entire mechanism. A module-qualified call resolves into the module of that name and nowhere else, so a substitute has to carry the same name. See the file header.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string] $VMName
    )

    Add-HDTFakeHyperVCall -Command 'Get-VMDvdDrive' -Argument @{ VMName = $VMName }

    return [pscustomobject] @{ VMName = $VMName; Path = 'fake.iso' }
}

Export-ModuleMember -Function @(
    'Get-HDTFakeHyperVCall', 'Clear-HDTFakeHyperVCall', 'Set-HDTFakeHyperVVirtualMachine',
    'New-VM', 'Get-VM', 'Set-VM', 'Set-VMMemory', 'Add-VMHardDiskDrive',
    'Set-VMFirmware', 'Add-VMDvdDrive', 'Get-VMDvdDrive')
