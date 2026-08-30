# EVERY ANSWER FILE THIS MODULE SHIPS, AGAINST WHAT WINDOWS SETUP ACTUALLY ACCEPTS.
#
# WHAT THIS EXISTS TO CATCH, because it has already happened. On 2026-08-28 a
# full deployment reached step 10 of 11, the machine rebooted, and Windows Setup
# refused the answer file with "a component or setting specified in the answer
# file does not exist", naming the oobeSystem pass. Two things had been added to
# the shipped template by one commit:
#
#   EnableFirstLogonAnimation in oobeSystem Microsoft-Windows-Shell-Setup.
#     Not an unattend setting at all - it is a Group Policy / Policy CSP value
#     (Policy CSP - WindowsLogon). This is the one Setup refused.
#
#   Microsoft-Windows-PnpCustomizationsNonWinPE in the specialize pass.
#     A real component, in a pass Microsoft does not document it for.
#
# BOTH WOULD HAVE BEEN CAUGHT HERE, and neither was caught by anything else: the
# document is well-formed XML, it validates against nothing - there is no schema
# for unattend.xml in this repository - and every unit test that reads it only
# cares that tokens expand. The only thing that ever refused it was a real
# machine, an hour into a deployment.
#
# IT IS DRIVEN OFF THE PARSED XML AND A DOCUMENTED MAP, NOT OFF A LIST OF THE
# TWO THINGS THAT BROKE (CLAUDE.md rule 8). Every element in every shipped
# answer file has to appear in the map below with its documented passes. Add a
# setting and this test refuses it until somebody looks it up; put a legal
# setting in an illegal pass and it names the pass.
#
# -- PROVENANCE OF THE MAP -----------------------------------------------------
#
# Every entry is the "Valid Configuration Passes" section of that setting's own
# page in the Unattended Windows Setup Reference, read rather than remembered.
# The page is named per entry. Three sources agree and are recorded here so the
# next person does not have to re-derive them:
#
#   1. THE REFERENCE, learn.microsoft.com/windows-hardware/customize/desktop/
#      unattend/... - the authority, and what each entry cites.
#   2. THE CAPTURE, tests/fixtures/unattend/win11-client.xml - an answer file
#      that DEPLOYED A REAL WINDOWS 11 MACHINE (SPIKES S7). Nothing in it can be
#      illegal, and this file asserts that by walking the capture too.
#   3. PSD, C:\HDTLab\reference\PSD\Templates\Unattend_x64.xml - MIT, the
#      closest prior art. Consulted for where a working MDT-derived template
#      puts PnpCustomizationsNonWinPE, which is offlineServicing and never
#      specialize. Read for mechanism only; nothing is copied from it.
#
# A CONTAINER RESTRICTS ITS CHILDREN. OOBE is oobeSystem-only, so every child of
# OOBE is oobeSystem-only whatever the child's own page says in isolation.

$script:HDTRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# -- the shipped answer file, and the capture it is measured against ----------

$script:HDTShippedUnattendPath = Join-Path -Path $script:HDTRepoRoot -ChildPath 'src/Hephaestus/Templates/unattend.xml'
$script:HDTCapturedUnattendPath = Join-Path -Path $script:HDTRepoRoot -ChildPath 'tests/fixtures/unattend/win11-client.xml'

# -- the documents ------------------------------------------------------------
#
# A GLOB, not a list. A second answer file added to Templates\ or beside a
# sample sequence is checked the day it lands.

$script:HDTUnattendDocument = @()
foreach ($relative in @('src/Hephaestus/Templates', 'samples/workspace', 'tests/fixtures/unattend')) {
    $full = Join-Path -Path $script:HDTRepoRoot -ChildPath $relative
    if (-not (Test-Path -LiteralPath $full)) { continue }

    $script:HDTUnattendDocument += @(Get-ChildItem -LiteralPath $full -Filter 'unattend*.xml' -File -Recurse)
}

# The capture is named win11-client.xml, so the glob above misses it. It is the
# one document that MUST pass, being the one a machine accepted.
$script:HDTUnattendDocument += @(Get-Item -LiteralPath $script:HDTCapturedUnattendPath)

# EVERYTHING THE RUN PHASE NEEDS LIVES HERE, and that is a Pester 5 rule rather
# than a preference. This file is executed TWICE - once to discover tests, once
# to run them - and the run phase gets a fresh scope: neither a function nor a
# $script: variable declared at file scope survives into an It. Only the file
# glob below stays outside, because -ForEach is evaluated during discovery.
BeforeAll {
    $script:HDTRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:HDTShippedUnattendPath = Join-Path -Path $script:HDTRepoRoot -ChildPath 'src/Hephaestus/Templates/unattend.xml'
    $script:HDTCapturedUnattendPath = Join-Path -Path $script:HDTRepoRoot -ChildPath 'tests/fixtures/unattend/win11-client.xml'

    # -- the components, and the passes each is documented for --------------------

    $script:HDTUnattendComponentPass = @{
        # microsoft-windows-setup - windowsPE only.
        'Microsoft-Windows-Setup'                     = @('windowsPE')

        # microsoft-windows-shell-setup. The settings under it differ widely, and
        # the per-setting map below is what actually decides; this is the union.
        'Microsoft-Windows-Shell-Setup'               = @('auditSystem', 'auditUser', 'generalize', 'offlineServicing', 'oobeSystem', 'specialize')

        # microsoft-windows-international-core-inputlocale and its siblings.
        'Microsoft-Windows-International-Core'        = @('offlineServicing', 'oobeSystem', 'specialize')

        # microsoft-windows-pnpcustomizationsnonwinpe - "copied to the driver store
        # of the Windows installation during the auditSystem configuration pass",
        # and DriverPaths, PathAndCredentials, Path and Key each list auditSystem
        # and offlineServicing. NOT specialize, which is where a driver-staging
        # commit put it on 2026-08-28.
        'Microsoft-Windows-PnpCustomizationsNonWinPE' = @('auditSystem', 'offlineServicing')

        # -- THE GENERALIZE PASS, WHICH ONLY THE SYSPREP ANSWER FILE REACHES ---
        #
        # Neither of these appears in the deployment's unattend.xml and neither
        # can: generalize runs on the REFERENCE machine while sysprep turns it
        # back into an image, and Setup never runs that pass on a deployed one.
        #
        # microsoft-windows-security-spp - "This component is applied during the
        # generalize configuration pass", and SkipRearm is its only setting.
        'Microsoft-Windows-Security-SPP'              = @('generalize')

        # microsoft-windows-pnpsysprep - generalize alone. Its two settings
        # decide whether the captured image keeps the reference machine's driver
        # bindings and non-present devices, which is a question that exists only
        # at the moment of generalizing.
        'Microsoft-Windows-PnpSysprep'                = @('generalize')
    }

    # -- the settings, keyed Component/Element/Path -------------------------------

    $script:HDTUnattendSettingPass = @{
        # -- Microsoft-Windows-Setup, windowsPE ----------------------------------
        'Microsoft-Windows-Setup/Display'                                       = @('windowsPE')
        'Microsoft-Windows-Setup/Display/ColorDepth'                            = @('windowsPE')
        'Microsoft-Windows-Setup/Display/HorizontalResolution'                  = @('windowsPE')
        'Microsoft-Windows-Setup/Display/RefreshRate'                           = @('windowsPE')
        'Microsoft-Windows-Setup/Display/VerticalResolution'                    = @('windowsPE')

        # -- Microsoft-Windows-Shell-Setup ---------------------------------------
        # microsoft-windows-shell-setup-computername
        'Microsoft-Windows-Shell-Setup/ComputerName'                            = @('offlineServicing', 'specialize')
        # microsoft-windows-shell-setup-registeredowner
        'Microsoft-Windows-Shell-Setup/RegisteredOwner'                         = @('auditUser', 'generalize', 'offlineServicing', 'oobeSystem', 'specialize')
        # microsoft-windows-shell-setup-registeredorganization
        'Microsoft-Windows-Shell-Setup/RegisteredOrganization'                  = @('auditUser', 'generalize', 'offlineServicing', 'oobeSystem', 'specialize')
        # microsoft-windows-shell-setup-productkey - specialize ALONE.
        'Microsoft-Windows-Shell-Setup/ProductKey'                              = @('specialize')
        # microsoft-windows-shell-setup-timezone
        'Microsoft-Windows-Shell-Setup/TimeZone'                                = @('auditSystem', 'oobeSystem', 'specialize')

        # microsoft-windows-shell-setup-oobe - oobeSystem, and it restricts every
        # child below it.
        'Microsoft-Windows-Shell-Setup/OOBE'                                    = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/OOBE/HideEULAPage'                       = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/OOBE/HideLocalAccountScreen'             = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/OOBE/HideOEMRegistrationScreen'          = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/OOBE/HideOnlineAccountScreens'           = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/OOBE/HideWirelessSetupInOOBE'            = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/OOBE/NetworkLocation'                    = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/OOBE/ProtectYourPC'                      = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/OOBE/UnattendEnableRetailDemo'           = @('oobeSystem')

        # microsoft-windows-shell-setup-useraccounts
        'Microsoft-Windows-Shell-Setup/UserAccounts'                            = @('auditSystem', 'oobeSystem')
        'Microsoft-Windows-Shell-Setup/UserAccounts/AdministratorPassword'      = @('auditSystem', 'oobeSystem')
        'Microsoft-Windows-Shell-Setup/UserAccounts/AdministratorPassword/Value' = @('auditSystem', 'oobeSystem')
        'Microsoft-Windows-Shell-Setup/UserAccounts/AdministratorPassword/PlainText' = @('auditSystem', 'oobeSystem')

        # microsoft-windows-shell-setup-autologon
        'Microsoft-Windows-Shell-Setup/AutoLogon'                               = @('auditSystem', 'oobeSystem', 'specialize')
        'Microsoft-Windows-Shell-Setup/AutoLogon/Enabled'                       = @('auditSystem', 'oobeSystem', 'specialize')
        'Microsoft-Windows-Shell-Setup/AutoLogon/LogonCount'                    = @('auditSystem', 'oobeSystem', 'specialize')
        'Microsoft-Windows-Shell-Setup/AutoLogon/Username'                      = @('auditSystem', 'oobeSystem', 'specialize')
        'Microsoft-Windows-Shell-Setup/AutoLogon/Domain'                        = @('auditSystem', 'oobeSystem', 'specialize')
        'Microsoft-Windows-Shell-Setup/AutoLogon/Password'                      = @('auditSystem', 'oobeSystem', 'specialize')
        'Microsoft-Windows-Shell-Setup/AutoLogon/Password/Value'                = @('auditSystem', 'oobeSystem', 'specialize')
        'Microsoft-Windows-Shell-Setup/AutoLogon/Password/PlainText'            = @('auditSystem', 'oobeSystem', 'specialize')

        # microsoft-windows-shell-setup-firstlogoncommands
        'Microsoft-Windows-Shell-Setup/FirstLogonCommands'                      = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand'   = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand/Order' = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand/CommandLine' = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand/Description' = @('oobeSystem')
        'Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand/RequiresUserInput' = @('oobeSystem')

        # -- Microsoft-Windows-International-Core --------------------------------
        'Microsoft-Windows-International-Core/InputLocale'                      = @('offlineServicing', 'oobeSystem', 'specialize')
        'Microsoft-Windows-International-Core/SystemLocale'                     = @('offlineServicing', 'oobeSystem', 'specialize')
        'Microsoft-Windows-International-Core/UILanguage'                       = @('offlineServicing', 'oobeSystem', 'specialize')
        'Microsoft-Windows-International-Core/UserLocale'                       = @('offlineServicing', 'oobeSystem', 'specialize')

        # -- Microsoft-Windows-PnpCustomizationsNonWinPE -------------------------
        # THE SHIPPED TEMPLATE CARRIES THIS AGAIN, in offlineServicing, which is
        # where BOTH authorities put it: MDT's own Templates\Unattend_x64.xml:168
        # and PSD's Templates\Unattend_x64.xml:124. Putting it back in specialize
        # fails here, which is the whole point of driving this off the map.
        'Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths'                                = @('auditSystem', 'offlineServicing')
        'Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths/PathAndCredentials'             = @('auditSystem', 'offlineServicing')
        'Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths/PathAndCredentials/Path'        = @('auditSystem', 'offlineServicing')
        'Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths/PathAndCredentials/Credentials' = @('auditSystem', 'offlineServicing')

        # -- Microsoft-Windows-Security-SPP, generalize --------------------------
        # microsoft-windows-security-spp-skiprearm. generalize alone, and the
        # reason it is set is that a Windows installation may be rearmed three
        # times: every /generalize without it spends one, so the fourth capture
        # of a monthly reference image fails, months later, as an activation
        # problem on the deployed fleet.
        'Microsoft-Windows-Security-SPP/SkipRearm'                              = @('generalize')

        # -- Microsoft-Windows-PnpSysprep, generalize ----------------------------
        # microsoft-windows-pnpsysprep-persistalldeviceinstalls and
        # microsoft-windows-pnpsysprep-donotcleanupnonpresentdevices. Both
        # generalize alone; both false, which is what makes a captured image
        # hardware-independent rather than a copy of one machine's device tree.
        'Microsoft-Windows-PnpSysprep/PersistAllDeviceInstalls'                 = @('generalize')
        'Microsoft-Windows-PnpSysprep/DoNotCleanUpNonPresentDevices'            = @('generalize')
    }

    # -- things that LOOK like settings and are not -------------------------------
    #
    # An unknown element already fails without this. These entries exist so the
    # failure says WHY, because "EnableFirstLogonAnimation is not a setting" is a
    # sentence somebody has already argued with once and lost a deployment to.

    $script:HDTUnattendNotASetting = @{
        'Microsoft-Windows-Shell-Setup/EnableFirstLogonAnimation' = 'a Group Policy / Policy CSP value - Policy CSP WindowsLogon, registry Software\Microsoft\Windows\CurrentVersion\Policies\System - and NOT an unattend setting. There is no Microsoft-Windows-Shell-Setup EnableFirstLogonAnimation in the Unattended Windows Setup Reference, and Windows Setup refuses the WHOLE answer file over it. Suppress the animation with a registry write from a FirstLogonCommands entry instead.'
    }

    # EVERY ELEMENT THE SHIPPED TEMPLATE ADDS BEYOND THE ONE THAT DEPLOYED A
    # MACHINE, each with the reason it is safe to add.
    #
    # THE DELTA IS WHERE BOTH OF 2026-08-28's DEFECTS LIVED, and neither had a
    # reason written down anywhere. An element that is in the template and not in
    # the capture is an element no machine has ever accepted here, so it earns a
    # sentence saying why somebody believes it will be.

    $script:HDTUnattendDeltaReason = @{
        'specialize/Microsoft-Windows-Shell-Setup/RegisteredOwner'        = 'MDT parity - RegisteredOwner and RegisteredOrganization are what its Windows Settings page writes. specialize is documented for both. Cosmetic, and it cannot fail a pass.'
        'specialize/Microsoft-Windows-Shell-Setup/RegisteredOrganization' = 'as RegisteredOwner.'
        'specialize/Microsoft-Windows-Shell-Setup/ProductKey'             = 'specialize is the only documented pass for it, and Invoke-HDTApplyUnattendStep REMOVES the whole element when nothing supplies the key - an EMPTY ProductKey fails the pass, and so does the literal unexpanded token. The capture predates key support.'
        'specialize/Microsoft-Windows-Shell-Setup/TimeZone'               = 'documented for specialize. A machine with no TimeZone gets one derived from the locale, so this only makes the choice explicit.'
        'oobeSystem/Microsoft-Windows-Shell-Setup/OOBE/HideLocalAccountScreen'   = 'documented for oobeSystem. Its own page says it applies to Windows Server editions only, so it is inert on the client the capture was taken from rather than wrong there.'
        'oobeSystem/Microsoft-Windows-Shell-Setup/OOBE/UnattendEnableRetailDemo' = 'documented as a child of OOBE in oobeSystem. false is the default; stating it stops a retail demo image turning one on.'
        'oobeSystem/Microsoft-Windows-Shell-Setup/FirstLogonCommands'                          = 'the capture stripped the spike own instrumentation, not the element - SPIKES S7 records FirstLogonCommands EXECUTING on the machine it built. This is how the task sequence resumes in the full OS.'
        'oobeSystem/Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand'       = 'as FirstLogonCommands.'
        'oobeSystem/Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand/Order' = 'as FirstLogonCommands.'
        'oobeSystem/Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand/CommandLine'       = 'as FirstLogonCommands.'
        'oobeSystem/Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand/Description'       = 'as FirstLogonCommands.'
        'oobeSystem/Microsoft-Windows-Shell-Setup/FirstLogonCommands/SynchronousCommand/RequiresUserInput' = 'as FirstLogonCommands.'

        # THE DRIVER PATH, WHICH IS THE WHOLE REASON DRIVERS INSTALL AT ALL.
        # ApplyDrivers stages matched packages to <OSVolume>\Drivers and nothing
        # else tells Windows to look there. The capture predates driver staging.
        # Both authorities declare exactly this, in this pass, with this path:
        # MDT Templates\Unattend_x64.xml:167-175 and PSD's :124-131.
        'offlineServicing/Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths'                         = 'MDT Unattend_x64.xml:170 and PSD Unattend_x64.xml:126. offlineServicing is the pass DISM processes when the answer file is applied to the offline image, which Invoke-HDTApplyUnattendStep now does through IImageService.ApplyUnattend.'
        'offlineServicing/Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths/PathAndCredentials'      = 'as DriverPaths. wcm:keyValue="1" wcm:action="add" is the shape both authorities use.'
        'offlineServicing/Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths/PathAndCredentials/Path' = 'as DriverPaths. The value is \Drivers, image-root-relative, which resolves to <OSVolume>\Drivers - the exact folder ApplyDrivers stages to, asserted below rather than believed.'
    }

    # AND THE SAME DISCIPLINE FOR A WHOLE COMPONENT. A component the capture
    # never carried is a component no machine has ever accepted here, and the
    # component test used to have no allow-list at all - so the only way to add
    # one was to make that test fail and argue with it. It earns a sentence now,
    # exactly as a setting does.
    $script:HDTUnattendDeltaComponentReason = @{
        'offlineServicing/Microsoft-Windows-PnpCustomizationsNonWinPE' = 'the driver path component. Documented for auditSystem and offlineServicing; MDT Unattend_x64.xml:168 and PSD Unattend_x64.xml:125 both put it in offlineServicing, and HDT applies the staged answer file to the offline image so that pass is reached.'
    }

    # FLATTENS AN ANSWER FILE INTO ONE RECORD PER ELEMENT: Pass, Component and Path,
    # where Path is the element's position relative to its component -
    # 'OOBE/HideEULAPage'. A component itself comes back with an empty Path.
    #
    # wcm:action and wcm:keyValue are ATTRIBUTES and are not settings, so attributes
    # are not walked at all.
    #
    # A SCRIPTBLOCK AND NOT A FUNCTION, which is the pattern the unit suites here
    # already use. Pester 5 executes this file once for discovery and again for the
    # run, and a function declared at file scope is NOT visible inside an It in the
    # run phase - script-scope VARIABLES are. A function here fails with
    # "The term 'Get-HDTUnattendSetting' is not recognized", once per test.
    $script:HDTUnattendSetting = {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Path
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $xml = New-Object -TypeName System.Xml.XmlDocument
        $xml.Load($Path)

        $found = New-Object -TypeName System.Collections.ArrayList

        foreach ($settings in @($xml.DocumentElement.ChildNodes)) {
            if ($settings.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($settings.LocalName -ne 'settings') { continue }

            $pass = [string] $settings.GetAttribute('pass')

            foreach ($component in @($settings.ChildNodes)) {
                if ($component.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                if ($component.LocalName -ne 'component') { continue }

                $name = [string] $component.GetAttribute('name')

                [void] $found.Add([pscustomobject] @{ Pass = $pass; Component = $name; Path = '' })

                # AN EXPLICIT STACK rather than a recursive helper: the walk has to
                # carry a prefix down with each node, and a stack of node-plus-prefix
                # pairs says that in one place.
                $stack = New-Object -TypeName System.Collections.Stack
                foreach ($child in @($component.ChildNodes)) {
                    $stack.Push(@{ Node = $child; Prefix = '' })
                }

                while ($stack.Count -gt 0) {
                    $item = $stack.Pop()
                    $node = $item['Node']

                    if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }

                    $relative = [string] $node.LocalName
                    if (-not [string]::IsNullOrEmpty([string] $item['Prefix'])) {
                        $relative = '{0}/{1}' -f $item['Prefix'], $node.LocalName
                    }

                    [void] $found.Add([pscustomobject] @{ Pass = $pass; Component = $name; Path = $relative })

                    foreach ($child in @($node.ChildNodes)) {
                        $stack.Push(@{ Node = $child; Prefix = $relative })
                    }
                }
            }
        }

        return @($found)
    }
}

Describe 'the answer files this module ships' {

    It "<Name> puts every component in a pass Microsoft documents it for" -ForEach @(
        @($script:HDTUnattendDocument | ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } })
    ) {
        $offence = @()

        foreach ($setting in @(& $script:HDTUnattendSetting -Path $FullName)) {
            if ($setting.Path -ne '') { continue }

            if (-not $script:HDTUnattendComponentPass.ContainsKey($setting.Component)) {
                $offence += ("{0} is a component this contract has never been told about. Add it to HDTUnattendComponentPass with the passes its own page in the Unattended Windows Setup Reference lists." -f $setting.Component)
                continue
            }

            $legal = @($script:HDTUnattendComponentPass[$setting.Component])
            if ($legal -notcontains $setting.Pass) {
                $offence += ("{0} is in the '{1}' pass. Microsoft documents it for {2} only." -f
                    $setting.Component, $setting.Pass, ($legal -join ', '))
            }
        }

        ($offence -join "`n") | Should -BeNullOrEmpty
    }

    It "<Name> declares only real settings, each in a pass that accepts it" -ForEach @(
        @($script:HDTUnattendDocument | ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } })
    ) {
        $offence = @()

        foreach ($setting in @(& $script:HDTUnattendSetting -Path $FullName)) {
            if ($setting.Path -eq '') { continue }

            $key = '{0}/{1}' -f $setting.Component, $setting.Path

            if ($script:HDTUnattendNotASetting.ContainsKey($key)) {
                $offence += ("{0} is {1}" -f $key, $script:HDTUnattendNotASetting[$key])
                continue
            }

            if (-not $script:HDTUnattendSettingPass.ContainsKey($key)) {
                $offence += ("{0} is not a setting this contract knows. Look it up in the Unattended Windows Setup Reference and add it to HDTUnattendSettingPass with the passes its page lists - and if it is not in the reference at all, Windows Setup will refuse the whole answer file over it." -f $key)
                continue
            }

            $legal = @($script:HDTUnattendSettingPass[$key])
            if ($legal -notcontains $setting.Pass) {
                $offence += ("{0} is in the '{1}' pass. Its page documents {2} only." -f
                    $key, $setting.Pass, ($legal -join ', '))
            }
        }

        ($offence -join "`n") | Should -BeNullOrEmpty
    }
}

Describe 'the shipped template against the answer file that deployed a machine' {

    # tests/fixtures/unattend/win11-client.xml is not a second opinion, it is
    # EVIDENCE: SPIKES S7 captured it off a Windows 11 Enterprise LTSC machine
    # it had just built. Everything in it is known to be accepted. Everything
    # the template adds on top of it is not, and has to say why.

    It 'adds nothing to the deployed capture without a reason recorded for it' {
        $shipped = @(& $script:HDTUnattendSetting -Path $script:HDTShippedUnattendPath |
                Where-Object { $_.Path -ne '' } |
                ForEach-Object { '{0}/{1}/{2}' -f $_.Pass, $_.Component, $_.Path })

        $captured = @(& $script:HDTUnattendSetting -Path $script:HDTCapturedUnattendPath |
                Where-Object { $_.Path -ne '' } |
                ForEach-Object { '{0}/{1}/{2}' -f $_.Pass, $_.Component, $_.Path })

        $unjustified = @($shipped |
                Where-Object { $captured -notcontains $_ } |
                Where-Object { -not $script:HDTUnattendDeltaReason.ContainsKey($_) })

        ($unjustified -join "`n") | Should -BeNullOrEmpty
    }

    It 'adds no component the deployed capture did not carry without a reason recorded for it' {
        $shipped = @(& $script:HDTUnattendSetting -Path $script:HDTShippedUnattendPath |
                Where-Object { $_.Path -eq '' } |
                ForEach-Object { '{0}/{1}' -f $_.Pass, $_.Component })

        $captured = @(& $script:HDTUnattendSetting -Path $script:HDTCapturedUnattendPath |
                Where-Object { $_.Path -eq '' } |
                ForEach-Object { '{0}/{1}' -f $_.Pass, $_.Component })

        $unjustified = @($shipped |
                Where-Object { $captured -notcontains $_ } |
                Where-Object { -not $script:HDTUnattendDeltaComponentReason.ContainsKey($_) })

        ($unjustified -join "`n") | Should -BeNullOrEmpty
    }

    # AS FOR SETTINGS: a reason naming a component the template no longer
    # carries is permission nobody granted.
    It 'records no reason for a component the template does not actually carry' {
        $shipped = @(& $script:HDTUnattendSetting -Path $script:HDTShippedUnattendPath |
                Where-Object { $_.Path -eq '' } |
                ForEach-Object { '{0}/{1}' -f $_.Pass, $_.Component })

        $stale = @(@($script:HDTUnattendDeltaComponentReason.Keys) | Where-Object { $shipped -notcontains $_ })

        ($stale -join "`n") | Should -BeNullOrEmpty
    }

    # THE ALLOW-LIST IS NOT A PLACE TO PARK A DELETED ELEMENT. An entry naming
    # something the template no longer has is a reason for a decision nobody
    # made any more, and the next person reads it as permission.
    It 'records no reason for an element the template does not actually carry' {
        $shipped = @(& $script:HDTUnattendSetting -Path $script:HDTShippedUnattendPath |
                Where-Object { $_.Path -ne '' } |
                ForEach-Object { '{0}/{1}/{2}' -f $_.Pass, $_.Component, $_.Path })

        $stale = @(@($script:HDTUnattendDeltaReason.Keys) | Where-Object { $shipped -notcontains $_ })

        ($stale -join "`n") | Should -BeNullOrEmpty
    }
}

# THE HALF-FEATURE THIS SUITE EXISTS TO REFUSE.
#
# On 2026-08-28 the PnP component was DELETED from the shipped template because
# it sat in a pass that does not accept it. That was half right - the pass was
# wrong, the component was not - and the deletion left ApplyDrivers copying
# packages onto a disk with nothing anywhere telling Windows to install them.
# The tests below are the two halves of that, asserted rather than assumed:
# the declaration EXISTS, and it names the folder the staging step ACTUALLY
# writes to.

Describe 'a driver that is staged is also installable' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        $script:HDTShippedUnattendPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/unattend.xml'

        # THE DECLARED PATH, READ OUT OF THE REAL TEMPLATE. Not a literal: the
        # next person to edit that element fails here.
        $script:HDTDeclaredDriverPath = {
            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'

            $xml = New-Object -TypeName System.Xml.XmlDocument
            $xml.Load($script:HDTShippedUnattendPath)

            $manager = New-Object -TypeName System.Xml.XmlNamespaceManager -ArgumentList $xml.NameTable
            $manager.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')

            $node = @($xml.SelectNodes(
                    "/u:unattend/u:settings/u:component[@name='Microsoft-Windows-PnpCustomizationsNonWinPE']" +
                    '/u:DriverPaths/u:PathAndCredentials/u:Path', $manager))

            return @(@($node) | ForEach-Object { [string] $_.InnerText })
        }
    }

    It 'declares a driver path at all, in a pass that installs from it' {
        $found = @(& $script:HDTUnattendSetting -Path $script:HDTShippedUnattendPath |
                Where-Object { $_.Component -eq 'Microsoft-Windows-PnpCustomizationsNonWinPE' -and $_.Path -eq '' })

        # PRESENT. Deleting the component is what shipped drivers nobody installs.
        @($found).Count | Should -BeGreaterThan 0 -Because (
            'ApplyDrivers stages packages to <OSVolume>\Drivers and NOTHING else tells Windows to look there. ' +
            'Microsoft-Windows-PnpCustomizationsNonWinPE is the declaration that makes a staged driver an installed one.')

        # AND IN A LEGAL PASS, decided by the same map every other component is
        # measured against - so putting it back in specialize fails here.
        foreach ($one in $found) {
            @($script:HDTUnattendComponentPass[$one.Component]) |
                Should -Contain $one.Pass -Because 'a component in a pass Windows does not accept fails the WHOLE answer file.'
        }
    }

    It 'declares exactly the folder the staging step writes to' {
        $declared = @(& $script:HDTDeclaredDriverPath)
        @($declared).Count | Should -Be 1

        # -- the staging side, driven by running the REAL step ----------------
        #
        # Not by reading a constant out of the source: the assertion that was
        # missing is that these two agree, so both sides have to come from the
        # code that actually runs.
        $inf = @(
            '[version]'
            'Signature   = "$Windows NT$"'
            'Class       = Net'
            'ClassGUID   = {4d36e972-e325-11ce-bfc1-08002be10318}'
            'Provider    = %Acme%'
            'DriverVer   = 11/28/2024,10.74.1128.2024'
            ''
            '[Manufacturer]'
            '%Acme% = Acme, NTamd64.10.0'
            ''
            '[Acme.NTamd64.10.0]'
            '%Nic.DeviceDesc% = Nic.ndi, PCI\VEN_10EC&DEV_8168'
            ''
            '[Strings]'
            'Acme = "Acme"'
            'Nic.DeviceDesc = "Acme GbE"'
        ) -join "`r`n"

        $groupPath = 'Z:\Deploy\Drivers\Win11\Acme\Box'
        $fileSystem = New-HDTFakeFileSystem -File @{ ('{0}\net-acme.inf' -f $groupPath) = $inf }
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 1, 0, 0, [System.DateTimeKind]::Utc))

        $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock `
            -Image (New-HDTFakeImageService) -Cim (New-HDTFakeCimProvider)

        $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $fileSystem -Clock $clock -Level Debug

        $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $variable['HDTOSVolume'] = 'W'
        $variable['HDTMake'] = 'Acme'
        $variable['HDTModel'] = 'Box'

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
            -Variable $variable -Service $catalog -Log $log

        $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $property['group'] = 'Win11\Acme\Box'

        $step = [pscustomobject] @{
            Index = 5; Name = 'Inject Drivers'; Type = 'ApplyDrivers'; TimeoutMinutes = 30; Log = $null; Property = $property
        }

        $result = Invoke-HDTApplyDriversStep -Step $step -Context $context
        $result.Status | Should -Be 'Completed'

        # WHERE THE FILES ACTUALLY LANDED on the fake volume, which is the only
        # honest answer to "what does staging do".
        $staged = @(@($fileSystem.File.Keys) |
                Where-Object { $_ -like 'W:\*' -and $_ -like '*.inf' })

        @($staged).Count | Should -BeGreaterThan 0 -Because 'the step reported Completed, so it staged something'

        # -- and the two sides, compared --------------------------------------
        #
        # The declared Path is IMAGE-ROOT-RELATIVE. DISM is handed the OS volume
        # as the image root (/Image:W:\), so '\Drivers' resolves to 'W:\Drivers'
        # - which is also what that path means once the volume is C: at boot.
        $expected = '{0}:{1}' -f $variable['HDTOSVolume'], $declared[0]

        foreach ($one in $staged) {
            $one | Should -BeLike ('{0}\*' -f $expected) -Because (
                ("the answer file declares '{0}', so Windows installs from '{1}' and NOWHERE else. " -f $declared[0], $expected) +
                'A staged driver outside that folder is a file on a disk that nothing will ever install.')
        }
    }
}
