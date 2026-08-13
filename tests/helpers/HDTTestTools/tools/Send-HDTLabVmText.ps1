function Send-HDTLabVmText {
    <#
        .SYNOPSIS
            Types text at a lab VM's console keyboard.

        .DESCRIPTION
            SPIKES S4's verified technique, as a helper. The Hyper-V WMI
            namespace root\virtualization\v2 exposes Msvm_Keyboard with TypeText
            and TypeKey, which is how a headless harness drives a VM that has no
            integration services yet - and WinPE has none.

            THE FILTER IS SystemName = <the VM's Msvm_ComputerSystem.Name GUID>,
            NOT ITS ElementName. S4 recorded that specifically: ElementName is
            the friendly name and Name is the GUID, and Msvm_Keyboard is keyed
            on the GUID.

            TypeText is capped at 1024 characters per call by the WMI method, so
            long lines are sent in chunks. -Enter presses Return afterwards
            (key code 13).

            This is used ONCE in the E2E, to start the launcher at the WinPE
            prompt, because the boot image's startnet.cmd predates the engine.
            Wiring the engine into startnet.cmd is M4's Update-HDTBootImage;
            typing one line is the smallest thing that does not pretend
            otherwise.

        .PARAMETER Name
            The VM. Must be HDT-*.

        .PARAMETER Text
            What to type.

        .PARAMETER Enter
            Press Return after the text.

        .OUTPUTS
            None.

        .EXAMPLE
            Send-HDTLabVmText -Name 'HDT-M3-Deploy' -Text 'powershell -ep bypass -f D:\HDT\Start-HDTLabDeployment.ps1' -Enter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter()]
        [switch] $Enter
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Assert-HDTLabVmName -Name $Name

    if (-not $PSCmdlet.ShouldProcess($Name, 'Type text at the VM console')) {
        return
    }

    $vm = @(Hyper-V\Get-VM -Name $Name)
    if ($vm.Count -ne 1) {
        throw ("no single VM named '{0}' to type at." -f $Name)
    }

    # The GUID, not the friendly name (SPIKES S4).
    $guid = [string] $vm[0].Id

    $keyboard = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_Keyboard' |
            Where-Object { $_.SystemName -eq $guid })

    if ($keyboard.Count -ne 1) {
        throw ("could not find the Msvm_Keyboard for '{0}' ({1}). Msvm_Keyboard is keyed on Msvm_ComputerSystem.Name - the GUID - and not on ElementName." -f $Name, $guid)
    }

    # TypeText takes at most 1024 characters per call.
    $chunkSize = 1024
    for ($offset = 0; $offset -lt $Text.Length; $offset += $chunkSize) {
        $length = [math]::Min($chunkSize, $Text.Length - $offset)

        $result = Invoke-CimMethod -InputObject $keyboard[0] -MethodName 'TypeText' `
            -Arguments @{ asciiText = $Text.Substring($offset, $length) }

        if ([int] $result.ReturnValue -ne 0) {
            throw ("TypeText returned {0} for '{1}'." -f $result.ReturnValue, $Name)
        }
    }

    if ($Enter) {
        $result = Invoke-CimMethod -InputObject $keyboard[0] -MethodName 'TypeKey' `
            -Arguments @{ keyCode = [uint16] 13 }

        if ([int] $result.ReturnValue -ne 0) {
            throw ("TypeKey returned {0} for '{1}'." -f $result.ReturnValue, $Name)
        }
    }
}
