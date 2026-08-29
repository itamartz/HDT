function Get-HDTMachineFact {
    <#
        .SYNOPSIS
            Gathers the machine facts through injected services.

        .DESCRIPTION
            Produces the gathered-facts layer of the variable model - hardware,
            firmware, chassis and network - as an ordered, case-insensitive
            dictionary keyed by HDT variable name. Every rule that matches on a
            machine matches on what this returns.

            It touches nothing itself. Every value arrives through one of three
            injected services, which is why the whole fact table can be proven
            under Pester against captured fixtures with no machine attached, and
            why a BIOS machine, an ARM machine and a machine with no TPM are all
            testable from a desk that has none of them. There is deliberately
            no Get-CimInstance, Get-ItemProperty or $env: reference anywhere in
            this file.

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
            Get-NetIPAddress because WinPE has no NetTCPIP module, which a boot
            test confirmed. The IPEnabled filtering is done here, not by the
            provider: ICimProvider has no -Filter, so every implementation
            returns the unfiltered set.

            What this deliberately does NOT produce: HDTBootMode, which only the
            boot path knows (phase 05); HDTComputerName and HDTTimeZone,
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
            $service = @{
                CimProvider         = New-HDTCimProvider
                RegistryService     = New-HDTRegistryService
                EnvironmentProvider = New-HDTEnvironmentProvider
            }

            $fact = Get-HDTMachineFact @service
            @($fact.Keys | Where-Object { $_ -like 'HDTIs*' }) |
                ForEach-Object { '{0} = {1}' -f $_, $fact[$_] }

            The yes-or-no facts a rule matches on - HDTIsLaptop, HDTIsVirtual,
            HDTIsUefi - read off this machine.

            THERE IS NO BARE CALL, AND THAT IS THE POINT. All three adapters are
            mandatory with no default, so `Get-HDTMachineFact` on its own does
            not gather - it PROMPTS for three objects nobody can type at a
            prompt. Every other command here defaults its services to the real
            ones; this is the one whose whole job is reading hardware, so a
            default would let a test that forgot its fakes poll the live CIM
            stack and pass. Splatting is the readable way to hand over three.

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
        [object] $EnvironmentProvider,

        # WHERE EACH FACT CAME FROM, AND WHICH ONES THE MACHINE COULD NOT ANSWER.
        # A dictionary the CALLER owns and this fills in - the same shape
        # Get-HDTDriver's -Cache uses, and for the same reason: it lets a command
        # hand back a second answer without changing the one every existing
        # caller already reads.
        #
        # IT EXISTS BECAUSE AN EMPTY FACT IS INVISIBLE. A fact that comes back
        # blank is simply absent from the log, and nothing distinguishes "this
        # machine has no TPM" from "the query failed" from "the property was
        # empty" - so a rule keyed on HDTSystemSKU that silently never matches
        # has no explanation anywhere.
        #
        # AND IT IS NOT ONLY DIAGNOSTIC. Invoke-HDTGatherStep reads Determined to
        # decide whether a re-gathered fact may overwrite a value something else
        # resolved. On a real deployment the step replaced HDTAssetTag - set by a
        # rule script - with the empty string SMBIOS reported, because it had no
        # way to tell an answer from a non-answer.
        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Provenance,

        # PER-SOURCE TIMING, AND ONLY WHEN A CLOCK IS INJECTED. A gather that
        # takes four seconds is one slow QUERY - Win32_Tpm against a stuck TPM
        # service is the usual answer - and which one is the only useful thing to
        # know about it. Optional because the engine's rule is that a real clock
        # reading never appears inside engine code: a caller with an IClock
        # passes it, and a caller without one gets no timings rather than a
        # DateTime::UtcNow hidden in here.
        [Parameter()]
        [AllowNull()]
        [object] $Clock
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # HOW LONG EACH SOURCE TOOK, keyed by source name. A hashtable rather than a
    # counter because the closure below is invoked with '&', which gives it its
    # own scope - an assignment to a plain variable in there would be discarded.
    $elapsed = @{}

    $timed = {
        param([string] $Source, [scriptblock] $Query)

        $startedAt = $null
        if ($null -ne $Clock) { $startedAt = $Clock.GetUtcNow() }

        try {
            return (& $Query)
        } finally {
            if ($null -ne $startedAt) {
                $elapsed[$Source] = [long] (($Clock.GetUtcNow()) - $startedAt).TotalMilliseconds
            }
        }
    }

    # -- required classes: no facts means no deployment, so these throw --------

    $computerSystem = @(& $timed 'Win32_ComputerSystem' { $CimProvider.GetInstance('Win32_ComputerSystem') })
    $computerSystemProduct = @(& $timed 'Win32_ComputerSystemProduct' { $CimProvider.GetInstance('Win32_ComputerSystemProduct') })
    $baseBoard = @(& $timed 'Win32_BaseBoard' { $CimProvider.GetInstance('Win32_BaseBoard') })
    $bios = @(& $timed 'Win32_BIOS' { $CimProvider.GetInstance('Win32_BIOS') })

    # -- optional classes: absent is a fact, not a failure --------------------
    #
    # WHY THE CLASS WAS ABSENT IS RECORDED, NOT JUST THAT IT WAS. "Win32_Tpm is
    # not available in this namespace" is an image missing an optional component;
    # "Win32_Tpm returned no instances" is a machine with no TPM. Those are
    # different problems with the same empty answer, and the log used to show
    # neither.
    $enclosureReason = ''
    $enclosure = @()
    try {
        $enclosure = @(& $timed 'Win32_SystemEnclosure' { $CimProvider.GetInstance('Win32_SystemEnclosure') })
        if ($enclosure.Count -eq 0) { $enclosureReason = 'Win32_SystemEnclosure returned no instances' }
    } catch {
        $enclosure = @()
        $enclosureReason = 'Win32_SystemEnclosure is not available on this machine: {0}' -f $_.Exception.Message
    }

    $adapterReason = ''
    $adapter = @()
    try {
        $adapter = @(& $timed 'Win32_NetworkAdapterConfiguration' { $CimProvider.GetInstance('Win32_NetworkAdapterConfiguration') })
        if ($adapter.Count -eq 0) { $adapterReason = 'Win32_NetworkAdapterConfiguration returned no instances' }
    } catch {
        $adapter = @()
        $adapterReason = 'Win32_NetworkAdapterConfiguration is not available on this machine: {0}' -f $_.Exception.Message
    }

    $tpmReason = ''
    $tpm = @()
    try {
        $tpm = @(& $timed 'Win32_Tpm' { $CimProvider.GetInstance('root/cimv2/security/microsofttpm', 'Win32_Tpm') })
        if ($tpm.Count -eq 0) { $tpmReason = 'Win32_Tpm returned no instances' }
    } catch {
        $tpm = @()
        # WinPE WITHOUT THE TPM OPTIONAL COMPONENT LOOKS EXACTLY LIKE THIS, and
        # it is an image to rebuild rather than a machine to replace.
        $tpmReason = 'the root/cimv2/security/microsofttpm namespace is not available: {0}' -f $_.Exception.Message
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
    #
    # WHICH CLASS ACTUALLY SUPPLIED IT IS RECORDED, because "Make came from the
    # baseboard" is the tell that this is a VM or an OEM that leaves the computer
    # system blank - and a rule matching on Make that works on one machine and
    # not another is usually this.
    $makeSource = 'Win32_ComputerSystem'
    $makeProperty = 'Manufacturer'
    $modelSource = 'Win32_ComputerSystem'
    $modelProperty = 'Model'

    if ([string]::IsNullOrWhiteSpace($make)) {
        $make = $boardManufacturer
        $makeSource = 'Win32_BaseBoard'
        $makeProperty = 'Manufacturer'
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        $model = $product
        $modelSource = 'Win32_BaseBoard'
        $modelProperty = 'Product'
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
    $assetTag = ''

    # THE WORKING BEHIND THE DERIVATION, kept so the log can show it.
    # HDTIsLaptop = True is a chassis type mapped through a table, and the log
    # gave the answer with none of the working - so when it comes out wrong on an
    # odd chassis there was nothing to debug. $chassisRead also distinguishes
    # "read the chassis and it is none of these" from "never read a chassis at
    # all", which both produce three Falses.
    $chassisRaw = ''
    $chassisRead = $false
    $assetTagReason = $enclosureReason

    if ($enclosure.Count -gt 0) {
        $chassisType = @($enclosure[0].ChassisTypes)
        if ($chassisType.Count -gt 0) {
            $primaryChassis = [int] $chassisType[0]
            $chassisRaw = [string] $primaryChassis
            $chassisRead = $true

            $isLaptop = (@(8, 9, 10, 11, 12, 14, 18, 21) -contains $primaryChassis)
            $isDesktop = (@(3, 4, 5, 6, 7, 15, 16) -contains $primaryChassis)
            $isServer = (@(23) -contains $primaryChassis)
        }

        # -- the asset tag, and why it is read defensively ---------------------
        #
        # MDT's AssetTag, from the same SMBIOS field. It is here rather than
        # with the identity facts because Win32_SystemEnclosure is the class
        # that carries it, and this is the block that already has it.
        #
        # THE PROPERTY IS NOT ALWAYS THERE. A VM's enclosure instance often
        # carries ChassisTypes and little else, and under
        # Set-StrictMode -Version Latest reading a property an object does not
        # have is a terminating error - so a gatherer that read it directly
        # would throw on exactly the machines this toolkit is tested against.
        #
        # THE VALUE IS TAKEN AS THE MACHINE REPORTS IT, trimmed and no more.
        # OEMs ship placeholders here - 'Default string', 'No Asset Tag',
        # 'System Asset Tag' - and a rule keyed on one of those matches every
        # unconfigured machine in the fleet rather than one. HDT does not
        # blocklist them: a site that genuinely stamps its tags would have its
        # real values silently blanked, and MDT reports the field raw. The trap
        # is recorded here instead, because the person writing that rule is the
        # one who needs to know.
        if ($null -ne $enclosure[0].PSObject.Properties['SMBIOSAssetTag']) {
            $assetTag = ([string] $enclosure[0].SMBIOSAssetTag).Trim()

            if ([string]::IsNullOrEmpty($assetTag)) {
                $assetTagReason = 'Win32_SystemEnclosure.SMBIOSAssetTag was empty'
            }
        } else {
            # A VM's enclosure instance often carries ChassisTypes and little
            # else. That is a different sentence from "the field is blank".
            $assetTagReason = 'Win32_SystemEnclosure has no SMBIOSAssetTag property on this machine'
        }

        if ($chassisRead -eq $false -and [string]::IsNullOrEmpty($enclosureReason)) {
            $enclosureReason = 'Win32_SystemEnclosure.ChassisTypes was empty'
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
    # MDT SETS DeploymentType IN ZTIGather AND GATES WHOLE GROUPS ON IT. This
    # engine performs bare-metal installs only, so there is one value - and it
    # is written anyway, so a sequence can be conditioned on it now rather than
    # every group predating the refresh path having to be retrofitted later.
    # See Get-HDTVariableMap for the rest of MDT's set.
    $fact['HDTDeploymentType'] = 'NEWCOMPUTER'
    $fact['HDTIsUEFI'] = [bool] $isUefi
    $fact['HDTSecureBootEnabled'] = [bool] $secureBootEnabled
    $fact['HDTTPMVersion'] = $tpmVersion
    $fact['HDTIsDesktop'] = [bool] $isDesktop
    $fact['HDTIsLaptop'] = [bool] $isLaptop
    $fact['HDTIsServer'] = [bool] $isServer
    $fact['HDTAssetTag'] = $assetTag
    $fact['HDTIsVM'] = [bool] $isVirtualMachine
    $fact['HDTMacAddress'] = [string[]] @($macAddress)
    $fact['HDTIPAddress'] = [string[]] @($ipAddress)
    $fact['HDTDefaultGateway'] = [string[]] @($defaultGateway)

    # -- where each of those came from ----------------------------------------
    #
    # BUILT AT THE END RATHER THAN THREADED THROUGH THE GATHER. Every value above
    # is already in a variable; recording provenance beside each assignment would
    # have put a bookkeeping line between every fact and the next, and the table
    # below is the one place a reader can see the whole map at once.
    #
    # THE SOURCE VOCABULARY IS SHARED WITH Gather\devices.json AND THE STEP'S
    # LOG: a CIM class is named by its class name, and the two non-CIM sources
    # are 'registry' and 'environment'. 'constant' is the third, and it is said
    # out loud rather than dressed up as a reading.

    if ($null -ne $Provenance) {
        # DETERMINED IS NOT "TRUTHY". False is an answer - SecureBoot off is a
        # fact about the machine, not a refusal - so a boolean that was actually
        # READ is determined, and only the ones derived from something absent are
        # not. Getting this wrong would put a real value in the "could not
        # determine" list on every BIOS machine.
        $note = {
            param([string] $Name, [string] $Source, [string] $Property, $Raw, [bool] $Determined, [string] $Reason)

            $millisecond = 0
            if ($elapsed.ContainsKey($Source)) { $millisecond = [long] $elapsed[$Source] }

            # A NAME REPORTED AS UNDETERMINED WITH NO REASON IS A SECOND MYSTERY,
            # so one is always supplied rather than left to the caller to invent.
            $said = $Reason
            if (-not $Determined -and [string]::IsNullOrWhiteSpace($said)) {
                $said = '{0}.{1} was empty' -f $Source, $Property
            }

            $Provenance[$Name] = [pscustomobject] @{
                Fact       = [string] $Name
                Source     = [string] $Source
                Property   = [string] $Property
                Raw        = $Raw
                Determined = [bool] $Determined
                Reason     = [string] $said
                ElapsedMs  = [long] $millisecond
            }
        }

        $said = { param([string] $Value) return (-not [string]::IsNullOrWhiteSpace($Value)) }

        & $note 'HDTMake' $makeSource $makeProperty $make (& $said $make) ''
        & $note 'HDTModel' $modelSource $modelProperty $model (& $said $model) ''
        & $note 'HDTProduct' 'Win32_BaseBoard' 'Product' $product (& $said $product) ''
        & $note 'HDTSerialNumber' 'Win32_BIOS' 'SerialNumber' $serialNumber (& $said $serialNumber) ''
        & $note 'HDTUUID' 'Win32_ComputerSystemProduct' 'UUID' $uuid (& $said $uuid) ''

        # THE ONE CLAUDE.md NAMES: the CIM property that is empty on VMs. A rule
        # keyed on it that never matches had no explanation anywhere until now.
        & $note 'HDTSystemSKU' 'Win32_ComputerSystem' 'SystemSKUNumber' $systemSku (& $said $systemSku) ''

        & $note 'HDTMemory' 'Win32_ComputerSystem' 'TotalPhysicalMemory' $memoryMegabyte ($memoryMegabyte -gt 0) `
            'Win32_ComputerSystem.TotalPhysicalMemory reported no memory'
        & $note 'HDTArchitecture' 'environment' 'PROCESSOR_ARCHITECTURE' $architectureRaw (& $said $architecture) ''

        # SAID TO BE A CONSTANT, because it is. This engine performs bare-metal
        # installs only, so there is one value - and reporting it as though a
        # machine had been asked would be a lie in the one place that exists to
        # stop them.
        & $note 'HDTDeploymentType' 'constant' 'NEWCOMPUTER' 'NEWCOMPUTER' $true ''

        & $note 'HDTIsUEFI' 'environment' 'firmware_type' $firmwareType (& $said $firmwareType) `
            'the firmware_type environment variable was not set, so UEFI could not be confirmed'

        # READ IS DETERMINED, EVEN WHEN THE ANSWER IS FALSE. A BIOS machine has
        # no SecureBoot\State key and that is a real answer about the machine.
        & $note 'HDTSecureBootEnabled' 'registry' 'UEFISecureBootEnabled' $secureBootValue $true ''

        & $note 'HDTTPMVersion' 'Win32_Tpm' 'SpecVersion' $tpmVersion (& $said ([string] $tpmVersion)) $tpmReason

        # THE DERIVATIONS, WITH THEIR WORKING. Raw is the chassis type; the fact
        # is what the table mapped it to. All three come back False when nothing
        # was read, which is indistinguishable from a machine that is genuinely
        # none of them - so $chassisRead, not the value, decides.
        & $note 'HDTIsDesktop' 'Win32_SystemEnclosure' 'ChassisTypes' $chassisRaw $chassisRead $enclosureReason
        & $note 'HDTIsLaptop' 'Win32_SystemEnclosure' 'ChassisTypes' $chassisRaw $chassisRead $enclosureReason
        & $note 'HDTIsServer' 'Win32_SystemEnclosure' 'ChassisTypes' $chassisRaw $chassisRead $enclosureReason

        & $note 'HDTAssetTag' 'Win32_SystemEnclosure' 'SMBIOSAssetTag' $assetTag (& $said $assetTag) $assetTagReason

        # DERIVED FROM MAKE AND MODEL, and always answerable: a machine that is
        # not a known hypervisor's is not a VM, which is a determination.
        & $note 'HDTIsVM' 'Win32_ComputerSystem' 'Manufacturer/Model' $isVirtualMachine $true ''

        & $note 'HDTMacAddress' 'Win32_NetworkAdapterConfiguration' 'MACAddress' `
            ([string[]] @($macAddress)) ($macAddress.Count -gt 0) `
            $(if ([string]::IsNullOrEmpty($adapterReason)) { 'no IP-enabled network adapter reported a MAC address' } else { $adapterReason })

        & $note 'HDTIPAddress' 'Win32_NetworkAdapterConfiguration' 'IPAddress' `
            ([string[]] @($ipAddress)) ($ipAddress.Count -gt 0) `
            $(if ([string]::IsNullOrEmpty($adapterReason)) { 'no IP-enabled network adapter reported an address' } else { $adapterReason })

        & $note 'HDTDefaultGateway' 'Win32_NetworkAdapterConfiguration' 'DefaultIPGateway' `
            ([string[]] @($defaultGateway)) ($defaultGateway.Count -gt 0) `
            $(if ([string]::IsNullOrEmpty($adapterReason)) { 'no IP-enabled network adapter reported a default gateway' } else { $adapterReason })
    }

    return $fact
}
