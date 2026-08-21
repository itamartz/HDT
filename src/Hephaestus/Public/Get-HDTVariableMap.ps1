function Get-HDTVariableMap {
    <#
        .SYNOPSIS
            Returns the HDT variable namespace and its MDT translation table.

        .DESCRIPTION
            HDT has the same variable set MDT has, meaning for
            meaning, under an HDT prefix, so an existing runbook converts by
            search-and-replace. That table is data here rather than prose in a
            document: "Get-HDTVariableMap prints this table at runtime, and a
            contract test asserts every documented MDT name has exactly one HDT
            counterpart, so the mapping cannot silently drift"
            (tests/contract/VariableNamespace.Contract.Tests.ps1).

            Three families live in one table:

              * translated variables - the MDT-to-HDT pairs;
              * HDT-specific additions with no MDT equivalent, whose MdtName is
                $null;
              * engine variables, named _HDT* and never writable.
                A rule or a sequence that assigns one is a validation error, not
                a silent override, which is what Assert-HDTRuleDocument enforces.

            Origin says where a value comes from, so the map doubles as the index
            of what Get-HDTMachineFact reads:

            | Origin              | Meaning                                     |
            |---------------------|---------------------------------------------|
            | Class.Property      | a gathered fact, from that CIM property     |
            | environment.<name>  | a gathered fact, from that environment name |
            | registry.<name>     | a gathered fact, from that registry value   |
            | engine              | set by the engine, read-only                |
            | authored            | supplied by rules, sequences or the wizard  |

        .PARAMETER Name
            One or more HDT variable names to return, wildcards allowed. Omit it
            for the whole table. A name that matches nothing returns nothing,
            which is not an error - it is the answer to "is this variable
            mapped?".

        .OUTPUTS
            System.Management.Automation.PSCustomObject with HDTName, MdtName,
            Writable, Origin and Description.

        .EXAMPLE
            Get-HDTVariableMap | Format-Table -AutoSize

            Prints the whole translation table.

        .EXAMPLE
            Get-HDTVariableMap -Name 'HDTIs*'

            The chassis, firmware and virtual-machine flags.

        .EXAMPLE
            Get-HDTVariableMap | Where-Object { -not $_.Writable }

            The engine-owned variables a rules.yaml may not assign.

        .NOTES
            An early draft of this table carried '| HDTComputerName |
            HDTComputerName |' in a column pair whose left side is the MDT name.
            MDT's name is OSDComputerName; the document was corrected rather than
            worked around, and the contract test 'never puts an HDT name in the
            MDT column' is what would have caught it.

            'SkipWizard' is a family rather than a single name in MDT. HDT maps
            the family head and any HDTSkip<Page> name follows the same
            convention.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string[]] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $map = @(
        # -- identity and hardware facts (DESIGN 3.2.1) -----------------------
        @{ HDTName = 'HDTMake'; MdtName = 'Make'; Origin = 'Win32_ComputerSystem.Manufacturer'
            Description = 'System manufacturer, falling back to the baseboard manufacturer when the computer system reports none.'
        }
        @{ HDTName = 'HDTModel'; MdtName = 'Model'; Origin = 'Win32_ComputerSystem.Model'
            Description = 'System model, falling back to the baseboard product when the computer system reports none.'
        }
        @{ HDTName = 'HDTProduct'; MdtName = 'Product'; Origin = 'Win32_BaseBoard.Product'
            Description = 'Baseboard product identifier, the value driver packages are commonly keyed on.'
        }
        @{ HDTName = 'HDTSerialNumber'; MdtName = 'SerialNumber'; Origin = 'Win32_BIOS.SerialNumber'
            Description = 'BIOS serial number, the usual source of a generated computer name.'
        }
        @{ HDTName = 'HDTUUID'; MdtName = 'UUID'; Origin = 'Win32_ComputerSystemProduct.UUID'
            Description = 'SMBIOS UUID in upper case, the key of a Control\machines override file.'
        }
        @{ HDTName = 'HDTSystemSKU'; MdtName = 'SystemSKU'; Origin = 'Win32_ComputerSystem.SystemSKUNumber'
            Description = 'Manufacturer SKU string, more specific than the model on some vendor ranges.'
        }
        # MDT'S AssetTag, AND THE ONE FACT AN ORGANISATION OWNS RATHER THAN THE
        # VENDOR. Make, model and serial are stamped at the factory; this field
        # is what a site writes its own inventory number into, which is why
        # MDT's naming rules key on it. Beware the placeholder: OEMs ship
        # 'Default string' or 'No Asset Tag' here, and a rule matching one of
        # those matches every unconfigured machine rather than one.
        @{ HDTName = 'HDTAssetTag'; MdtName = 'AssetTag'; Origin = 'Win32_SystemEnclosure.SMBIOSAssetTag'
            Description = 'Asset tag from SMBIOS, trimmed and otherwise as the machine reports it. Empty where the machine carries none, which is most machines nobody has stamped.'
        }
        @{ HDTName = 'HDTMemory'; MdtName = 'Memory'; Origin = 'Win32_ComputerSystem.TotalPhysicalMemory'
            Description = 'Installed physical memory in whole megabytes, floored.'
        }
        @{ HDTName = 'HDTArchitecture'; MdtName = 'Architecture'; Origin = 'environment.PROCESSOR_ARCHITECTURE'
            Description = 'Processor architecture, x64 for AMD64, read from PROCESSOR_ARCHITEW6432 first so a 32-bit host process still reports the truth.'
        }
        # MDT GATES WHOLE GROUPS ON THIS - NEWCOMPUTER, REFRESH, REPLACE,
        # UPGRADE - which is how one Client.xml serves bare metal and an
        # in-place refresh from the same file.
        #
        # HDT IMPLEMENTS ONE OF THEM, and the variable exists anyway. A sequence
        # written against it now needs no rewrite the day a refresh path lands;
        # the alternative is a condition invented later and retrofitted onto
        # every group that predates it. What it must NOT do is claim more than
        # it does, which is why the description says so out loud.
        @{ HDTName = 'HDTDeploymentType'; MdtName = 'DeploymentType'; Origin = 'engine'
            Description = 'Which deployment scenario is running. This engine performs bare-metal installs only, so it is always NEWCOMPUTER; MDT also has REFRESH, REPLACE and UPGRADE, and those arrive with the steps that implement them.'
        }
        # THE DEPLOYED MACHINE'S TIME ZONE, and the reason it is not optional in
        # practice: Microsoft derives an unspecified one from the locale, and
        # this toolkit's answer file sets en-US - which is Pacific Standard Time
        # on every machine it builds. MDT's TimeZoneName, by another name.
        @{ HDTName = 'HDTTimeZone'; MdtName = 'TimeZoneName'; Origin = 'engine'
            Description = 'The Windows time zone id the deployed machine gets, written into the unattend''s specialize pass. Seeded from the boot image''s own time zone so one choice covers both, and overridable by a rule.'
        }

        # WHEN THE RUN STARTED, IN UTC, and UTC is the decision rather than a
        # detail: WinPE runs on the hardware clock and the deployed OS is put
        # into a time zone half way through, so a start read as local time and an
        # end read as local time are hours apart for reasons that have nothing to
        # do with how long the deployment took.
        @{ HDTName = 'HDTDeploymentStart'; MdtName = $null; Origin = 'engine'
            Description = 'When this deployment started, as UTC in ISO 8601 (yyyy-MM-ddTHH:mm:ssZ). Published by the engine before the sequence runs; a matching HDTDeploymentEnd is what a tattoo step would subtract it from.'
        }
        @{ HDTName = 'HDTDeploymentEnd'; MdtName = $null; Origin = 'engine'
            Description = 'The clock, in UTC ISO 8601, refreshed before every step. A tattoo step at the end of a sequence subtracts HDTDeploymentStart from it to record how long the deployment took; the true final value is in RESULT.json.'
        }

        # WHAT THE BOOT IMAGE CARRIES, SO A SEQUENCE CAN ASK. The template's
        # Install Certificates step is conditioned on it, and an image built
        # without certificates never sets it - which leaves the token unresolved,
        # which the engine reads as false. Silence skips the step, and that is
        # the behaviour every image built before this existed needs.
        @{ HDTName = 'HDTHasCertificate'; MdtName = $null; Origin = 'engine'
            Description = 'True when the boot image carries certificates - a certificate authority, a machine certificate, or both. Published from bootstrap.json when the deployment starts.'
        }
        @{ HDTName = 'HDTIsUEFI'; MdtName = 'IsUEFI'; Origin = 'environment.firmware_type'
            Description = 'True when the machine booted UEFI firmware, which decides the disk layout.'
        }
        @{ HDTName = 'HDTSecureBootEnabled'; MdtName = $null; Origin = 'registry.UEFISecureBootEnabled'
            Description = 'True when Secure Boot is enabled; false on a BIOS machine, which has no state key at all.'
        }
        @{ HDTName = 'HDTTPMVersion'; MdtName = $null; Origin = 'Win32_Tpm.SpecVersion'
            Description = 'TPM specification version such as 2.0, or null where no TPM is present or readable.'
        }
        @{ HDTName = 'HDTIsDesktop'; MdtName = 'IsDesktop'; Origin = 'Win32_SystemEnclosure.ChassisTypes'
            Description = 'True for a desktop chassis type.'
        }
        @{ HDTName = 'HDTIsLaptop'; MdtName = 'IsLaptop'; Origin = 'Win32_SystemEnclosure.ChassisTypes'
            Description = 'True for a portable, laptop, notebook, sub-notebook, docking-station or convertible chassis type.'
        }
        @{ HDTName = 'HDTIsServer'; MdtName = 'IsServer'; Origin = 'Win32_SystemEnclosure.ChassisTypes'
            Description = 'True for a rack-mount server chassis type.'
        }
        @{ HDTName = 'HDTIsVM'; MdtName = 'IsVM'; Origin = 'Win32_ComputerSystem.Manufacturer'
            Description = 'True when the manufacturer and model identify a Hyper-V, VMware, VirtualBox, QEMU, KVM, Xen or Parallels guest.'
        }
        @{ HDTName = 'HDTMacAddress'; MdtName = 'MacAddress'; Origin = 'Win32_NetworkAdapterConfiguration.MACAddress'
            Description = 'MAC addresses of the IP-enabled adapters, in adapter index order.'
        }
        @{ HDTName = 'HDTIPAddress'; MdtName = 'IPAddress'; Origin = 'Win32_NetworkAdapterConfiguration.IPAddress'
            Description = 'IP addresses of the IP-enabled adapters, in adapter index order.'
        }
        @{ HDTName = 'HDTDefaultGateway'; MdtName = 'DefaultGateway'; Origin = 'Win32_NetworkAdapterConfiguration.DefaultIPGateway'
            Description = 'Default gateways of the IP-enabled adapters, the usual way a rule identifies a subnet.'
        }

        # -- authored deployment variables (DESIGN 3.2, 3.3) ------------------
        @{ HDTName = 'HDTComputerName'; MdtName = 'OSDComputerName'; Origin = 'authored'
            Description = 'Name to give the deployed machine, commonly generated from HDTSerialNumber by a rule.'
        }
        @{ HDTName = 'HDTTaskSequenceID'; MdtName = 'TaskSequenceID'; Origin = 'authored'
            Description = 'Identifier of the sequence to run, which is what skipping the wizard requires.'
        }
        # PUBLISHED BY THE ENGINE FROM THE DOCUMENT IT IS RUNNING, not authored
        # like the id above. A sequence is chosen three ways and only one of
        # them sets HDTTaskSequenceID, so Invoke-HDTTaskSequence publishes all
        # three from the sequence it was handed - and overwrites the id, because
        # the sequence being executed is the truth about which one is running.
        @{ HDTName = 'HDTTaskSequenceName'; MdtName = 'TaskSequenceName'; Origin = 'engine'
            Description = 'Display name of the sequence being run, as its document declares it. The id is what selects a sequence; this is what a log line and a progress window can put in front of a person.'
        }
        @{ HDTName = 'HDTTaskSequenceVersion'; MdtName = 'TaskSequenceVersion'; Origin = 'engine'
            Description = "Version the sequence document declares, as text so a '2.0' keeps both components. Empty for a sequence that declares none, which is every sequence written before the field existed."
        }
        @{ HDTName = 'HDTJoinDomain'; MdtName = 'JoinDomain'; Origin = 'authored'
            Description = 'Active Directory domain to join.'
        }
        @{ HDTName = 'HDTDomainAdmin'; MdtName = 'DomainAdmin'; Origin = 'authored'
            Description = 'Account used to join the domain.'
        }
        @{ HDTName = 'HDTDomainAdminPassword'; MdtName = 'DomainAdminPassword'; Origin = 'authored'
            Description = 'Password for HDTDomainAdmin; never written to a log.'
        }
        @{ HDTName = 'HDTMachineObjectOU'; MdtName = 'MachineObjectOU'; Origin = 'authored'
            Description = 'Distinguished name of the organisational unit the computer object is created in.'
        }
        @{ HDTName = 'HDTJoinWorkgroup'; MdtName = 'JoinWorkgroup'; Origin = 'authored'
            Description = 'Workgroup to join instead of a domain.'
        }
        # MDT'S New Task Sequence WIZARD ASKS FOR BOTH, on its "OS Settings"
        # page, and writes them where the unattend reads them. They are
        # authored variables here for the same reason: an unattend template
        # substitutes %HDTFullName% exactly as it substitutes the password.
        @{ HDTName = 'HDTFullName'; MdtName = 'FullName'; Origin = 'authored'
            Description = 'Registered owner written into the answer file - a person or a team, not a computer name.'
        }
        @{ HDTName = 'HDTOrgName'; MdtName = 'OrgName'; Origin = 'authored'
            Description = 'Registered organisation written into the answer file.'
        }
        # MDT HAS TWO NAMES FOR THIS AND HDT HAS ONE. ProductKey and
        # OverrideProductKey exist in MDT because a task sequence could carry
        # its own key and a rule needed a way to beat it. HDT's precedence
        # already answers that - a rule outranks a sequence default (DESIGN
        # 3.1) - so a second name would be a second way to say the same thing,
        # and the pair is exactly where an MDT admin loses an afternoon.
        @{ HDTName = 'HDTProductKey'; MdtName = 'ProductKey'; Origin = 'authored'
            Description = "Windows product key written into the answer file's specialize pass. Unset removes the element rather than writing an empty one, which is what a KMS or LTSC build needs and what an empty element would fail the pass over."
        }
        @{ HDTName = 'HDTAdminPassword'; MdtName = 'AdminPassword'; Origin = 'authored'
            Description = 'Local administrator password for the deployed machine; never written to a log.'
        }
        @{ HDTName = 'HDTApplications'; MdtName = 'Applications'; Origin = 'authored'
            Description = 'Applications to install, by catalog identifier.'
        }
        @{ HDTName = 'HDTSkipFinalSummary'; MdtName = 'SkipFinalSummary'; Origin = 'authored'
            Description = 'True to end the full-OS leg without the Deployment Summary screen. Default false: a machine that finished and one that failed halfway must not look the same to the person standing at it.'
        }
        # A SECOND LIST, NOT A DEFAULT FOR THE FIRST. A default is what you get
        # when nobody chose; this is what you get when somebody did.
        @{ HDTName = 'HDTMandatoryApplications'; MdtName = 'MandatoryApplications'; Origin = 'authored'
            Description = 'Applications installed whatever the wizard selected, and whatever selection a step pins - the management agent or antivirus a site does not let a technician click past. Merged with HDTApplications; an id in both installs once.'
        }
        @{ HDTName = 'HDTSkipWizard'; MdtName = 'SkipWizard'; Origin = 'authored'
            Description = 'True to skip the deployment wizard entirely; any HDTSkip<Page> name follows the same convention for a single page.'
        }
        @{ HDTName = 'HDTWSUSServer'; MdtName = 'WSUSServer'; Origin = 'authored'
            Description = 'WSUS server the update step points at; unset means Windows Update.'
        }
        @{ HDTName = 'HDTDriverGroup'; MdtName = 'DriverGroup'; Origin = 'authored'
            Description = 'Driver store folder to inject from, commonly built from HDTMake and HDTModel by a rule.'
        }
        # THE LOCALE AND TIME PAGE'S FOUR, and MDT asks for all four separately
        # because Windows treats them separately: the language of the INSTALLED
        # OS, the formats a USER sees, the KEYBOARD, and the clock. A machine
        # deployed in English with a German keyboard is a perfectly ordinary
        # request, and one setting could not express it.
        @{ HDTName = 'HDTUILanguage'; MdtName = 'UILanguage'; Origin = 'authored'
            Description = 'Language the operating system is installed in, as a culture name such as en-US.'
        }
        @{ HDTName = 'HDTUserLocale'; MdtName = 'UserLocale'; Origin = 'authored'
            Description = 'Time, date, number and currency formats the user sees, as a culture name such as en-US.'
        }
        @{ HDTName = 'HDTSystemLocale'; MdtName = 'SystemLocale'; Origin = 'authored'
            Description = "The unattend's SystemLocale - the language a non-Unicode program assumes. Seeded to en-US when nothing sets it, which is what the template hard-coded before it was a variable."
        }
        @{ HDTName = 'HDTKeyboardLocale'; MdtName = 'KeyboardLocale'; Origin = 'authored'
            Description = 'Keyboard layout, as a culture name or an input locale pair such as 0409:00000409.'
        }
        @{ HDTName = 'HDTBootMode'; MdtName = $null; Origin = 'authored'
            Description = 'PXE or Media - how this deployment was started; set by the boot path rather than by hardware.'
        }
        @{ HDTName = 'HDTDiskLayout'; MdtName = $null; Origin = 'authored'
            Description = 'Named disk layout the partition step applies, such as uefi-standard.'
        }

        # -- published by an imaging step (DESIGN 9.1, 9.2) -------------------
        #
        # Origin 'step' rather than 'authored' or 'GatheredFact', because these
        # are facts about what a step DID: nothing can know HDTOSVolume before
        # the disk has been partitioned. They are ordinary writable HDT names,
        # so a later step or a condition composes on them the same way it does
        # on anything else.
        @{ HDTName = 'HDTTargetDisk'; MdtName = 'OSDDiskIndex'; Origin = 'step'
            Description = 'Number of the disk DiskPartition cleared and repartitioned.'
        }
        @{ HDTName = 'HDTSystemVolume'; MdtName = 'BootVolume'; Origin = 'step'
            Description = 'Drive letter of the EFI System or System Reserved partition, where the boot files are written.'
        }
        @{ HDTName = 'HDTOSVolume'; MdtName = 'OSVolume'; Origin = 'step'
            Description = 'Drive letter of the Windows partition; ApplyImage applies to it and ApplyUnattend stages beneath it.'
        }
        @{ HDTName = 'HDTRecoveryVolume'; MdtName = 'RecoveryVolume'; Origin = 'step'
            Description = 'Drive letter of the recovery partition, or empty for a layout that declares none.'
        }
        @{ HDTName = 'HDTImageIndex'; MdtName = $null; Origin = 'step'
            Description = 'Index ApplyImage resolved and applied, whether the sequence asked by number, name or edition.'
        }
        @{ HDTName = 'HDTUnattendPath'; MdtName = $null; Origin = 'step'
            Description = 'Full path of the staged unattend, which is Windows\Panther\unattend.xml on the OS volume.'
        }

        # A DEPLOYMENT USED TO END AND STAY WHERE IT WAS. A machine that had
        # just finished sat at a desktop, logged in as the local Administrator,
        # until somebody walked over to it - the opposite of what a technician
        # imaging a bench of twenty machines wants, and why MDT has this.
        @{ HDTName = 'HDTFinishAction'; MdtName = 'FinishAction'; Origin = 'authored'
            Description = 'What the machine does when the deployment ends: REBOOT, SHUTDOWN, LOGOFF or NONE. Unset means NONE, which is what every deployment did before this existed. A value nobody meant does nothing and warns rather than acting on the nearest guess.'
        }
        @{ HDTName = 'HDTSLShare'; MdtName = 'SLShare'; Origin = 'rule'
            Description = 'Where the deployment copies its logs. Empty means <deployRoot>\Logs, which is what every deployment did before this existed.'
        }

        # -- engine variables (DESIGN 4.4.1) - never writable -----------------
        @{ HDTName = '_HDTLogPath'; MdtName = '_SMSTSLogPath'; Origin = 'engine'
            Description = 'Current log directory; it moves with the phase and every log is written there.'
        }
        @{ HDTName = '_HDTRunId'; MdtName = $null; Origin = 'engine'
            Description = 'Unique identifier for this deployment run.'
        }
        @{ HDTName = '_HDTPhase'; MdtName = $null; Origin = 'engine'
            Description = 'WinPE or FullOS - the phase the engine is executing in.'
        }
        @{ HDTName = '_HDTStepName'; MdtName = $null; Origin = 'engine'
            Description = 'Name of the executing step.'
        }
        @{ HDTName = '_HDTStepType'; MdtName = $null; Origin = 'engine'
            Description = 'Type of the executing step.'
        }
        @{ HDTName = 'HDTUserId'; MdtName = 'UserID'; Origin = 'bootstrap'
            Description = 'The account the boot image connects to the deployment share with, chosen by bootstrap-rules.yaml before the share is reached. MDT put this in Bootstrap.ini, and so does this - a rule that chose another site''s share and left this behind has chosen a share it cannot open.'
        }
        @{ HDTName = 'HDTUserDomain'; MdtName = 'UserDomain'; Origin = 'bootstrap'
            Description = 'The account''s domain, or empty for one local to the file server.'
        }
        @{ HDTName = 'HDTUserPassword'; MdtName = 'UserPassword'; Origin = 'bootstrap'
            Description = 'The account''s password. Clear text in bootstrap-rules.yaml, exactly as MDT''s Bootstrap.ini kept it: the file travels inside the boot image, and anybody holding the image already holds the credential baked into it.'
        }
        @{ HDTName = 'HDTDeployRoot'; MdtName = 'DeployRoot'; Origin = 'bootstrap'
            Description = 'Which deployment share to connect to, chosen by bootstrap-rules.yaml from the gathered facts before the share is reached. MDT put this in Bootstrap.ini. Unset means the one the boot image was built with.'
        }
        @{ HDTName = '_HDTDeployRoot'; MdtName = $null; Origin = 'engine'
            Description = 'Resolved workspace root, whether that is a share or standalone media. MDT''s DeployRoot belongs to HDTDeployRoot, which is the one an administrator SETS - this is what the engine RESOLVED it to, and the two differ whenever a bootstrap rule chose another share or the deployment is running from media.'
        }
        @{ HDTName = '_HDTVersion'; MdtName = $null; Origin = 'engine'
            Description = 'Engine version executing this deployment.'
        }
        @{ HDTName = '_HDTApplicationInstalled'; MdtName = $null; Origin = 'engine'
            Description = 'Application ids this run has already installed. The InstallApplications step checkpoints it so a reboot mid-list resumes at the next application rather than restarting the list.'
        }
    )

    foreach ($entry in $map) {
        if ($PSBoundParameters.ContainsKey('Name') -and $null -ne $Name) {
            $matched = $false
            foreach ($pattern in $Name) {
                if ($entry.HDTName -like $pattern) {
                    $matched = $true
                }
            }
            if (-not $matched) {
                continue
            }
        }

        [pscustomobject] @{
            HDTName     = $entry.HDTName
            MdtName     = $entry.MdtName
            Writable    = (-not $entry.HDTName.StartsWith('_'))
            Origin      = $entry.Origin
            Description = $entry.Description
        }
    }
}
