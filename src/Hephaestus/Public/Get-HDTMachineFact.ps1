function Get-HDTMachineFact {
    <#
        .SYNOPSIS
            Gathers the machine facts through injected services.

        .DESCRIPTION
            HDT's replacement for ZTIGather.wsf. It produces the gathered-facts
            layer of the variable model - hardware,
            firmware, chassis and network - as an ordered, case-insensitive
            dictionary keyed by HDT variable name.

            It touches nothing itself. Every value arrives through one of three
            injected services, which is why
            the whole fact table can be proven under Pester against captured
            fixtures with no machine attached, and why a BIOS machine, an ARM
            machine and a machine with no TPM are all testable from a desk that
            has none of them. There is deliberately no Get-CimInstance,
            Get-ItemProperty or $env: reference anywhere in this file.

            CIM classes are queried once each, in a fixed order, and everything
            is derived from those locals - a second query is a second round trip
            to WMI, which is slow in WinPE. The order is asserted by a test:

              Win32_ComputerSystem, Win32_ComputerSystemProduct, Win32_BaseBoard,
              Win32_BIOS, Win32_SystemEnclosure,
              Win32_NetworkAdapterConfiguration, Win32_Tpm

            The first four are required: a deployment that cannot read
            Win32_ComputerSystem has no facts to rule on and must fail loudly.
            The last three are optional and degrade to "no instances" - WinPE
            without the TPM optional component, a VM with no enclosure data and a
            machine with no IP enabled adapter are all normal in the field.

            Network facts come from Win32_NetworkAdapterConfiguration rather than
            Get-NetIPAddress because WinPE has no NetTCPIP module (DESIGN 3.2.1,
            SPIKES S1). The IPEnabled filtering is done here, not by the
            provider: ICimProvider has no -Filter, so every implementation
            returns the unfiltered set.

            What this deliberately does NOT produce: HDTBootMode, which only the
            boot path knows (phase 05); HDTComputerName and HDTTimeZoneName,
            which rules decide rather than hardware; and anything named _HDT*,
            which is engine-owned.

        .PARAMETER CimProvider
            An ICimProvider - New-HDTCimProvider in production,
            New-HDTFakeCimProvider in a test.

        .PARAMETER RegistryService
            An IRegistryService, used only to read the Secure Boot state key.

        .PARAMETER EnvironmentProvider
            An IEnvironmentProvider, used for firmware_type and the processor
            architecture variables.

        .OUTPUTS
            System.Collections.Specialized.OrderedDictionary. Ordered so a
            facts.json diff stays readable, case-insensitive so a hand-written
            rules.yaml may spell a variable however it likes.

        .EXAMPLE
            $fact = Get-HDTMachineFact `
                -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) `
                -EnvironmentProvider (New-HDTEnvironmentProvider)
            $fact['HDTModel']

            Gathers from the live machine through the real adapters.

        .EXAMPLE
            $cim = New-HDTFakeCimProvider -FixturePath ./tests/fixtures/cim `
                -NamespaceFixturePath @{ 'root/cimv2/security/microsofttpm' = './tests/fixtures/cim-microsofttpm' }
            Get-HDTMachineFact -CimProvider $cim `
                -RegistryService (New-HDTFakeRegistryService) `
                -EnvironmentProvider (New-HDTFakeEnvironmentProvider -Variable @{ firmware_type = 'BIOS' })

            The same gatherer against captured fixtures, standing in for a BIOS
            machine with no Secure Boot key.

        .NOTES
            The chassis type tables (laptop 8, 9, 10, 11, 12, 14, 18, 21;
            desktop 3, 4, 5, 6, 7, 15, 16; server 23), the virtual-machine
            manufacturer list, and the PROCESSOR_ARCHITEW6432 precedence are
            derived from PSD (friendsOfMDT), Scripts/PSDGather.psm1, function
            Get-PSDLocalInfo. PSD is MIT licensed; see NOTICE.md at the
            repository root. Nothing else is carried across - PSD calls
            Get-CimInstance inline, which PROJECT constraint 4 forbids here.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $CimProvider,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $RegistryService,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $EnvironmentProvider
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- required classes: no facts means no deployment, so these throw --------

    $computerSystem = @($CimProvider.GetInstance('Win32_ComputerSystem'))
    $computerSystemProduct = @($CimProvider.GetInstance('Win32_ComputerSystemProduct'))
    $baseBoard = @($CimProvider.GetInstance('Win32_BaseBoard'))
    $bios = @($CimProvider.GetInstance('Win32_BIOS'))

    # -- optional classes: absent is a fact, not a failure --------------------

    $enclosure = @()
    try {
        $enclosure = @($CimProvider.GetInstance('Win32_SystemEnclosure'))
    } catch {
        $enclosure = @()
    }

    $adapter = @()
    try {
        $adapter = @($CimProvider.GetInstance('Win32_NetworkAdapterConfiguration'))
    } catch {
        $adapter = @()
    }

    $tpm = @()
    try {
        $tpm = @($CimProvider.GetInstance('root/cimv2/security/microsofttpm', 'Win32_Tpm'))
    } catch {
        $tpm = @()
    }

    # -- identity -------------------------------------------------------------

    $make = ''
    $model = ''
    $systemSku = ''
    $memoryByte = 0
    if ($computerSystem.Count -gt 0) {
        $make = ([string] $computerSystem[0].Manufacturer).Trim()
        $model = ([string] $computerSystem[0].Model).Trim()
        $systemSku = ([string] $computerSystem[0].SystemSKUNumber).Trim()
        $memoryByte = [double] $computerSystem[0].TotalPhysicalMemory
    }

    $boardManufacturer = ''
    $product = ''
    if ($baseBoard.Count -gt 0) {
        $boardManufacturer = ([string] $baseBoard[0].Manufacturer).Trim()
        $product = ([string] $baseBoard[0].Product).Trim()
    }

    # A VM often reports an empty Manufacturer or Model on the computer system
    # and the truth on the baseboard. Reuse the single Win32_BaseBoard result.
    if ([string]::IsNullOrWhiteSpace($make)) {
        $make = $boardManufacturer
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        $model = $product
    }

    $serialNumber = ''
    if ($bios.Count -gt 0) {
        $serialNumber = ([string] $bios[0].SerialNumber).Trim()
    }

    $uuid = ''
    if ($computerSystemProduct.Count -gt 0) {
        $uuid = ([string] $computerSystemProduct[0].UUID).Trim().ToUpperInvariant()
    }

    # Floor, never a cast: [int] on a double rounds to even, which would make the
    # reported megabytes depend on the machine rather than on the memory.
    $memoryMegabyte = [int] [math]::Floor($memoryByte / 1MB)

    # -- chassis (PSD PSDGather.psm1, Get-PSDLocalInfo) ------------------------

    $isDesktop = $false
    $isLaptop = $false
    $isServer = $false
    if ($enclosure.Count -gt 0) {
        $chassisType = @($enclosure[0].ChassisTypes)
        if ($chassisType.Count -gt 0) {
            $primaryChassis = [int] $chassisType[0]

            $isLaptop = (@(8, 9, 10, 11, 12, 14, 18, 21) -contains $primaryChassis)
            $isDesktop = (@(3, 4, 5, 6, 7, 15, 16) -contains $primaryChassis)
            $isServer = (@(23) -contains $primaryChassis)
        }
    }

    # -- virtualisation (PSD PSDGather.psm1, Get-PSDLocalInfo) -----------------

    $isVirtualMachine = $false
    if (($make -like '*Microsoft*') -and ($model -like 'Virtual Machine')) {
        $isVirtualMachine = $true
    }
    foreach ($pattern in @('*VMware*', '*innotek*', '*VirtualBox*', '*QEMU*', '*KVM*', '*Xen*', '*Parallels*')) {
        if ($make -like $pattern) {
            $isVirtualMachine = $true
        }
    }

    # -- firmware, architecture, Secure Boot ----------------------------------

    $firmwareType = [string] $EnvironmentProvider.GetVariable('firmware_type')
    $isUefi = ($firmwareType.Trim() -eq 'UEFI')

    # A 32-bit host process on a 64-bit machine reports x86 in
    # PROCESSOR_ARCHITECTURE and the truth in PROCESSOR_ARCHITEW6432.
    $architectureRaw = [string] $EnvironmentProvider.GetVariable('PROCESSOR_ARCHITEW6432')
    if ([string]::IsNullOrWhiteSpace($architectureRaw)) {
        $architectureRaw = [string] $EnvironmentProvider.GetVariable('PROCESSOR_ARCHITECTURE')
    }
    $architectureRaw = $architectureRaw.Trim()

    $architecture = $architectureRaw.ToUpperInvariant()
    if ($architecture -eq 'AMD64') {
        $architecture = 'x64'
    }

    # A BIOS machine has no SecureBoot\State key at all; the service returns
    # $null for that and this resolves to $false rather than throwing.
    $secureBootValue = $RegistryService.GetValue('HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State', 'UEFISecureBootEnabled')
    $secureBootEnabled = $false
    if ($null -ne $secureBootValue) {
        $secureBootEnabled = ([string] $secureBootValue -eq '1')
    }

    # -- TPM ------------------------------------------------------------------

    # SpecVersion is '2.0, 0, 1.38'; only the first component is the spec.
    $tpmVersion = $null
    if ($tpm.Count -gt 0) {
        $specVersion = [string] $tpm[0].SpecVersion
        if (-not [string]::IsNullOrWhiteSpace($specVersion)) {
            $tpmVersion = ($specVersion -split ',')[0].Trim()
        }
    }

    # -- network --------------------------------------------------------------

    $macAddress = New-Object -TypeName System.Collections.ArrayList
    $ipAddress = New-Object -TypeName System.Collections.ArrayList
    $defaultGateway = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($adapter | Where-Object { $_.IPEnabled } | Sort-Object -Property Index)) {
        if ($null -ne $current.MACAddress) {
            [void] $macAddress.Add([string] $current.MACAddress)
        }
        foreach ($address in @($current.IPAddress)) {
            if ($null -ne $address) {
                [void] $ipAddress.Add([string] $address)
            }
        }
        foreach ($gateway in @($current.DefaultIPGateway)) {
            if ($null -ne $gateway) {
                [void] $defaultGateway.Add([string] $gateway)
            }
        }
    }

    # -- the fact table -------------------------------------------------------

    $fact = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    $fact['HDTMake'] = $make
    $fact['HDTModel'] = $model
    $fact['HDTProduct'] = $product
    $fact['HDTSerialNumber'] = $serialNumber
    $fact['HDTUUID'] = $uuid
    $fact['HDTSystemSKU'] = $systemSku
    $fact['HDTMemory'] = $memoryMegabyte
    $fact['HDTArchitecture'] = $architecture
    $fact['HDTIsUEFI'] = [bool] $isUefi
    $fact['HDTSecureBootEnabled'] = [bool] $secureBootEnabled
    $fact['HDTTPMVersion'] = $tpmVersion
    $fact['HDTIsDesktop'] = [bool] $isDesktop
    $fact['HDTIsLaptop'] = [bool] $isLaptop
    $fact['HDTIsServer'] = [bool] $isServer
    $fact['HDTIsVM'] = [bool] $isVirtualMachine
    $fact['HDTMacAddress'] = [string[]] @($macAddress)
    $fact['HDTIPAddress'] = [string[]] @($ipAddress)
    $fact['HDTDefaultGateway'] = [string[]] @($defaultGateway)

    return $fact
}
