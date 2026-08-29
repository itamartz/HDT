# Where each machine fact came from, and which ones the machine could not
# answer.
#
# A FACT THAT COMES BACK EMPTY IS INVISIBLE TODAY. It is simply not in the list,
# and nothing distinguishes "this machine has no TPM" from "the query failed"
# from "the property was blank". A rule keyed on HDTSystemSKU that silently never
# matches is currently undiagnosable - and CLAUDE.md names this trap by name:
# the CIM property that is empty on VMs.
#
# AND IT IS NOT ONLY A LOGGING PROBLEM. On a real deployment
# (LT-7FJ45S2-run-20260829-190105) the Gather STEP overwrote HDTAssetTag - set to
# 'ASSET-7FJ45S2' by a rule script, and recorded as such in provenance.json -
# with the EMPTY string SMBIOS reported, and logged it as
# "HDTAssetTag: ASSET-7FJ45S2 -> " with nothing after the arrow. A fact the
# machine could not determine must not be allowed to erase one something else
# resolved, and telling those two apart is what makes that possible.
#
# THE DERIVATIONS NEED THEIR WORKING SHOWN. HDTIsLaptop = True is a chassis type
# mapped through a table; the log gives the answer and shows none of it, so when
# it comes out wrong on an odd chassis there is nothing to debug.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:cimFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'
    $script:tpmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm'
    $script:tpmNamespace = 'root/cimv2/security/microsofttpm'
}

Describe 'Get-HDTMachineFact -Provenance' {

    BeforeEach {
        $script:cim = New-HDTFakeCimProvider `
            -FixturePath $script:cimFixturePath `
            -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

        $script:environment = New-HDTFakeEnvironmentProvider -Variable @{
            firmware_type          = 'UEFI'
            PROCESSOR_ARCHITECTURE = 'AMD64'
        }

        $script:registry = New-HDTFakeRegistryService -Value @{
            'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' = @{ UEFISecureBootEnabled = 1 }
        }

        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 27, 9, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 10

        $script:bag = [ordered] @{}

        $script:gather = {
            param([hashtable] $Extra)

            $argument = @{
                CimProvider         = $script:cim
                RegistryService     = $script:registry
                EnvironmentProvider = $script:environment
                Provenance          = $script:bag
                Clock               = $script:clock
            }

            if ($null -ne $Extra) {
                foreach ($key in @($Extra.Keys)) { $argument[$key] = $Extra[$key] }
            }

            return (Get-HDTMachineFact @argument)
        }
    }

    Context 'the bag the caller owns' {

        It 'still answers the facts, unchanged, when a bag is passed' {
            # THE PROVENANCE IS A SIDE CHANNEL, not a different return shape.
            # Every existing caller reads the ordered dictionary and must go on
            # reading exactly the same thing.
            $withBag = & $script:gather $null
            $without = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry `
                -EnvironmentProvider $script:environment

            @($withBag.Keys) | Should -Be @($without.Keys)
            $withBag['HDTModel'] | Should -BeExactly $without['HDTModel']
        }

        It 'gathers perfectly well with no bag at all' {
            # The parameter is optional because most callers do not want it, and
            # a gatherer that required one would make every caller carry it.
            { Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry `
                    -EnvironmentProvider $script:environment } | Should -Not -Throw
        }

        It 'records a row for every fact it produced' {
            $fact = & $script:gather $null

            # AGAINST THE SET, not against the handful this file names. A fact
            # added later with no provenance row fails here the day it lands.
            foreach ($name in @($fact.Keys)) {
                $script:bag.Contains($name) | Should -BeTrue -Because "$name must say where it came from"
            }
        }
    }

    Context 'where each fact came from' {

        It 'names the CIM class behind an identity fact' {
            $null = & $script:gather $null

            $script:bag['HDTModel'].Source | Should -BeExactly 'Win32_ComputerSystem'
            $script:bag['HDTSerialNumber'].Source | Should -BeExactly 'Win32_BIOS'
            $script:bag['HDTUUID'].Source | Should -BeExactly 'Win32_ComputerSystemProduct'
        }

        It 'names the property, not only the class' {
            # "It came from Win32_ComputerSystem" is half an answer; the half a
            # person needs is which property, so they can read it themselves.
            $null = & $script:gather $null

            $script:bag['HDTSystemSKU'].Property | Should -BeExactly 'SystemSKUNumber'
        }

        It 'names the registry and the environment as sources of their own' {
            $null = & $script:gather $null

            $script:bag['HDTSecureBootEnabled'].Source | Should -BeExactly 'registry'
            $script:bag['HDTIsUEFI'].Source | Should -BeExactly 'environment'
        }

        It 'says a constant is a constant rather than pretending it was gathered' {
            # HDTDeploymentType is 'NEWCOMPUTER' because this engine performs
            # bare-metal installs only. Reporting it as though a machine had been
            # asked would be a lie in the one file that exists to stop lies.
            $null = & $script:gather $null

            $script:bag['HDTDeploymentType'].Source | Should -BeExactly 'constant'
        }

        It 'shows the working behind a derived fact' {
            # HDTIsLaptop IS A DERIVATION - a chassis type mapped through a
            # table - and the log gave the answer with none of the working. When
            # it comes out wrong on an odd chassis there has to be something to
            # debug.
            $null = & $script:gather $null

            $script:bag['HDTIsLaptop'].Source | Should -BeExactly 'Win32_SystemEnclosure'
            $script:bag['HDTIsLaptop'].Property | Should -BeExactly 'ChassisTypes'
            [string] $script:bag['HDTIsLaptop'].Raw | Should -Not -BeNullOrEmpty
        }

        It 'times each source rather than the whole gather' {
            # A gather that takes four seconds is one slow QUERY, and which one
            # is the only useful thing to know about it. Win32_Tpm on a machine
            # with a stuck TPM service is the usual answer.
            $null = & $script:gather $null

            [int] $script:bag['HDTModel'].ElapsedMs | Should -BeGreaterOrEqual 0
        }
    }

    Context 'the facts the machine could not answer' {

        It 'marks a fact it determined as determined' {
            $null = & $script:gather $null

            $script:bag['HDTModel'].Determined | Should -BeTrue
        }

        It 'marks an empty property as not determined, and says why' {
            # THE MOST VALUABLE LINE IN THE WHOLE STEP. An empty SystemSKU is
            # invisible today: the fact is simply absent from the log, so a rule
            # keyed on it that never matches has no explanation anywhere.
            # THROUGH A VARIABLE, never @(ConvertFrom-Json ...) - helpers README
            # F12. Inline, the parse result does not come back as the object it
            # looks like and setting a property on it fails with "cannot be
            # found on this object", which reads exactly like a missing fixture
            # field and is not one.
            $instance = @{}
            foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                $parsed = ConvertFrom-Json -InputObject $text
                $instance[$file.BaseName] = [object[]] @($parsed)
            }

            $blankSku = $instance['Win32_ComputerSystem']
            $blankSku[0].SystemSKUNumber = ''

            $override = New-HDTFakeCimProvider -Instance $instance `
                -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

            $null = & $script:gather @{ CimProvider = $override }

            $script:bag['HDTSystemSKU'].Determined | Should -BeFalse
            $script:bag['HDTSystemSKU'].Reason | Should -Match 'empty'
        }

        It 'says a whole class was missing rather than blaming the property' {
            # WinPE without the TPM optional component is a class that is not
            # there at all, and that is a different sentence from "SpecVersion
            # was blank" - one is an image to rebuild, the other is a machine
            # without a TPM.
            $instance = @{}
            foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
                $instance[$file.BaseName] = [object[]] @(Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
            }

            $noTpm = New-HDTFakeCimProvider -Instance $instance

            $null = & $script:gather @{ CimProvider = $noTpm }

            $script:bag['HDTTPMVersion'].Determined | Should -BeFalse
            $script:bag['HDTTPMVersion'].Reason | Should -Match 'no instances|not available'
        }

        It 'treats a boolean that was actually read as determined' {
            # False IS an answer. SecureBoot off is a fact about the machine, not
            # a fact the machine declined to give - and reporting it as
            # undetermined would put a real value in the "could not determine"
            # list on every BIOS machine.
            $null = & $script:gather $null

            $script:bag['HDTSecureBootEnabled'].Determined | Should -BeTrue
        }

        It 'treats a chassis derivation with no enclosure as undetermined, not as False' {
            # ALL THREE COME BACK False WHEN NOTHING WAS READ, which is
            # indistinguishable from a machine that is genuinely none of them.
            $instance = @{}
            foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
                if ($file.BaseName -eq 'Win32_SystemEnclosure') { continue }
                $instance[$file.BaseName] = [object[]] @(Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
            }

            $noEnclosure = New-HDTFakeCimProvider -Instance $instance `
                -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

            $null = & $script:gather @{ CimProvider = $noEnclosure }

            $script:bag['HDTIsLaptop'].Determined | Should -BeFalse
            $script:bag['HDTIsDesktop'].Determined | Should -BeFalse
        }

        It 'gives every undetermined fact a reason rather than a blank' {
            # A NAME WITH NO REASON IS A SECOND MYSTERY. Asserted over the SET so
            # a fact added later cannot land in the list with nothing to say.
            $noTpm = New-HDTFakeCimProvider -FixturePath $script:cimFixturePath

            $null = & $script:gather @{ CimProvider = $noTpm }

            foreach ($name in @($script:bag.Keys)) {
                if ($script:bag[$name].Determined) { continue }

                $script:bag[$name].Reason | Should -Not -BeNullOrEmpty -Because "$name is reported as undetermined and must say why"
            }
        }
    }
}
