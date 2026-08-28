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
        # KEPT IN THE MAP ALTHOUGH NO SHIPPED DOCUMENT USES IT ANY MORE, so that
        # re-adding it in the wrong pass fails here rather than on a machine.
        'Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths'                                = @('auditSystem', 'offlineServicing')
        'Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths/PathAndCredentials'             = @('auditSystem', 'offlineServicing')
        'Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths/PathAndCredentials/Path'        = @('auditSystem', 'offlineServicing')
        'Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths/PathAndCredentials/Credentials' = @('auditSystem', 'offlineServicing')
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

        ($shipped | Where-Object { $captured -notcontains $_ }) -join "`n" | Should -BeNullOrEmpty
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
