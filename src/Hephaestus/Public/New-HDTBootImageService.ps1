function New-HDTBootImageService {
    <#
        .SYNOPSIS
            Creates the real IBootImageService adapter over the DISM image
            cmdlets, dism.exe and oscdimg.exe.

        .DESCRIPTION
            The one place in HDT that names Mount-WindowsImage,
            Dismount-WindowsImage, Add-WindowsPackage, Add-WindowsDriver,
            Get-WindowsPackage, Get-WindowsImage, Export-WindowsImage,
            dism.exe or oscdimg.exe. PROJECT constraint 4 forbids engine logic
            from touching hardware or a tool directly, so Update-HDTBootImage and
            New-HDTBootIso receive this object and can be swapped for
            New-HDTFakeBootImageService in a test with no ADK, no elevation and
            nothing mounted.

            ELEVEN METHODS, AND THE EXACT MECHANISM EACH WRAPS:

              MountImage(imagePath, index, mountPath)
                  Mount-WindowsImage -ImagePath -Index -Path

              DismountImage(mountPath, save)
                  Dismount-WindowsImage -Path -Save   (save $true)
                  Dismount-WindowsImage -Path -Discard (save $false)

              AddPackage(mountPath, packagePath)
                  Add-WindowsPackage -Path -PackagePath

              AddDriver(mountPath, driverPath, recurse)
                  Add-WindowsDriver -Path -Driver [-Recurse], projected to
                  Inf / Provider / Version / Date, which is what the build
                  manifest records.

              GetPackage(mountPath)
                  Get-WindowsPackage -Path, projected to Name / State.

              GetImageInfo(imagePath)
                  Get-WindowsImage -ImagePath, projected to Index / Name /
                  SizeBytes. The ADK's winpe.wim has one index and is
                  340 134 390 bytes; a finished HDT boot image is about 480 MB,
and the difference is how "the build applied
                  nothing" is spotted.

              ExportImage(sourcePath, index, destinationPath)
                  Export-WindowsImage -SourceImagePath -SourceIndex
                      -DestinationImagePath -CompressionType Max
                  which is /Compress:max.

              SetScratchSpace(mountPath, megabyte)
                  dism.exe /Image:<mount> /Set-ScratchSpace:<mb>. THERE IS NO
                  CMDLET for this - the Dism module exposes no scratch-space
                  verb at all - so it is the one image operation that shells out.

              SetTimeZone(mountPath, name)
                  dism.exe /Image:<mount> /Set-TimeZone:"<id>". ALSO NO CMDLET,
                  and offline only - dism refuses it against /Online. It writes
                  the STANDARD half of
                  HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation and
                  VALIDATES the id against the image first, which is why the zone
                  is set here rather than by a command in startnet.cmd that WinPE
                  turned out not to have.

              SetTimeZoneDaylight(mountPath, value)
                  The DAYLIGHT half, which dism does not write at all - measured
                  by reading the key back out of a built image. Loads the mounted
                  image's own SYSTEM hive under a scratch key, writes the values
                  ConvertTo-HDTTimeZoneDaylightValue produced, unloads. Without
                  it every WinPE clock runs on the standard bias all year, an
                  hour out for every zone that observes daylight time.

              NewIso(mediaRoot, isoPath, argument)
                  oscdimg.exe @argument <mediaRoot> <isoPath>

            NewIso TAKES THE ARGUMENT ARRAY ALREADY BUILT. Every decision -
            firmware, -NoPromptForKey, the space-free staging oscdimg requires
            - lives in Get-HDTBootIsoArgument, which is pure string logic and is
            therefore fully tested. This method runs the process and checks
            $LASTEXITCODE. That division is the whole adapter rule in one
            method.

            THIS IS AN UNTESTED ADAPTER, and deliberately so:
            ten of its eleven methods mount a WIM, write into a mounted image,
            export half a gigabyte or burn an ISO, and every one of them needs
            elevation. Its contract row calls GetImageInfo and nothing else; the
            rest is proven in tests/integration/BootImage.Integration.Tests.ps1,
            which builds a real image and re-mounts it read-only to read
            startnet.cmd back out. The price of not testing it is that it must
            stay dumb. THE ONLY BRANCHES BELOW ARE TWO EXISTENCE GUARDS, FIVE
            EXIT-CODE CHECKS (dism twice, oscdimg once, reg load once, and reg
            unload once - that last one WARNS rather than throws because it sits
            in a finally block), ONE LAZY PATH RESOLUTION AND ONE ARGUMENT
            CONSTRUCTION FROM THE BOOLEAN THE INTERFACE CARRIES, each commented
            as such. Do not add logic here.

            EVERY NATIVE FAILURE CARRIES THE TOOL'S OWN OUTPUT. "oscdimg failed"
            without oscdimg's own sentence is the log entry that wastes an hour.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER OscdimgPath
            An explicit oscdimg.exe. Left empty, NewIso resolves it through
            Get-HDTAdkPath at call time rather than at construction time, so this
            service can be created on a machine with no ADK - which is what the
            contract test's fake row and every unit test do.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the eleven
            IBootImageService ScriptMethods. Note that
            Get-Member -MemberType Method does NOT list a ScriptMethod - use
            -MemberType Method, ScriptMethod.

        .EXAMPLE
            $boot = New-HDTBootImageService
            $boot.GetImageInfo((Get-HDTAdkPath -Asset WinPeWim)) | Format-Table Index, Name, SizeBytes

            The source WinPE a boot image build starts from.

        .EXAMPLE
            $boot = New-HDTBootImageService
            $boot.MountImage('C:\scratch\HDTPE_x64.wim', 1, 'C:\scratch\mount')
            $boot.AddPackage('C:\scratch\mount', 'C:\Adk\WinPE_OCs\WinPE-WMI.cab')
            $boot.DismountImage('C:\scratch\mount', $true)

            The mount/apply/commit cycle, as three calls.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. The destructive methods it exposes are called by Update-HDTBootImage and New-HDTBootIso, which carry SupportsShouldProcess.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string] $OscdimgPath = '',

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'BootImageService'
        OscdimgPath = $OscdimgPath
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    # Existence guard, not logic. It gives this adapter and the fake the same
    # failure for the same mistake - a WIM path that is not there - where
    # Get-WindowsImage would otherwise report a DISM error that does not say
    # plainly that the file is missing.
    $service | Add-Member -MemberType ScriptMethod -Name AssertImage -Value {
        param([string] $ImagePath)

        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new(
                "Could not find image '$ImagePath'.", $ImagePath)
        }
    }

    # The whole of the allowed logic in a native call: run it, and if it failed,
    # throw with the tool's own output attached (DESIGN 12.2.3).
    $service | Add-Member -MemberType ScriptMethod -Name AssertExitCode -Value {
        param([int] $ExitCode, [string] $Tool, [string] $CommandLine, [object[]] $Output)

        if ($ExitCode -ne 0) {
            throw [System.InvalidOperationException]::new(
                ("{0} exited {1} for: {2}{3}{4}" -f $Tool, $ExitCode, $CommandLine,
                    [System.Environment]::NewLine, (@($Output) -join [System.Environment]::NewLine)))
        }
    }

    # -- IBootImageService --------------------------------------------------

    $service | Add-Member -MemberType ScriptMethod -Name MountImage -Value {
        param([string] $ImagePath, [int] $Index, [string] $MountPath)

        $this.Record('MountImage', @($ImagePath, $Index, $MountPath))
        $this.AssertImage($ImagePath)

        Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $MountPath | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name DismountImage -Value {
        param([string] $MountPath, [bool] $Save)

        $this.Record('DismountImage', @($MountPath, $Save))

        # Argument construction from the boolean the interface carries, not a
        # decision: the caller already decided whether this build is being
        # committed or thrown away. Dismount-WindowsImage takes -Save and
        # -Discard as separate switches and there is no boolean form of either.
        $switch = @{ Discard = $true }
        if ($Save) { $switch = @{ Save = $true } }

        Dismount-WindowsImage -Path $MountPath @switch | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name AddPackage -Value {
        param([string] $MountPath, [string] $PackagePath)

        $this.Record('AddPackage', @($MountPath, $PackagePath))

        Add-WindowsPackage -Path $MountPath -PackagePath $PackagePath | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name AddDriver -Value {
        param([string] $MountPath, [string] $DriverPath, [bool] $Recurse)

        $this.Record('AddDriver', @($MountPath, $DriverPath, $Recurse))

        # -Recurse:$Recurse is parameter binding, not a branch.
        $added = @(Add-WindowsDriver -Path $MountPath -Driver $DriverPath -Recurse:$Recurse)

        $row = foreach ($item in $added) {
            [pscustomobject] @{
                Inf      = [string] $item.Driver
                Provider = [string] $item.ProviderName
                Version  = [string] $item.Version
                Date     = [string] $item.Date
            }
        }

        # The unary comma is mandatory: a ScriptMethod returning an array
        # collapses a one-element array to a scalar without it, and one boot
        # driver is a perfectly ordinary boot image (tests/helpers/README.md F3).
        return , ([object[]] @($row))
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetPackage -Value {
        param([string] $MountPath)

        $this.Record('GetPackage', @($MountPath))

        $row = foreach ($item in @(Get-WindowsPackage -Path $MountPath)) {
            [pscustomobject] @{
                Name  = [string] $item.PackageName
                State = [string] $item.PackageState
            }
        }

        return , ([object[]] @($row))
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetImageInfo -Value {
        param([string] $ImagePath)

        $this.Record('GetImageInfo', @($ImagePath))
        $this.AssertImage($ImagePath)

        $row = foreach ($image in @(Get-WindowsImage -ImagePath $ImagePath)) {
            [pscustomobject] @{
                Index     = [int] $image.ImageIndex
                Name      = [string] $image.ImageName
                SizeBytes = [long] $image.ImageSize
            }
        }

        return , ([object[]] @($row))
    }

    $service | Add-Member -MemberType ScriptMethod -Name ExportImage -Value {
        param([string] $SourcePath, [int] $Index, [string] $DestinationPath)

        $this.Record('ExportImage', @($SourcePath, $Index, $DestinationPath))
        $this.AssertImage($SourcePath)

        # -CompressionType Max is DESIGN 5.1's /Compress:max. It is the reason a
        # 480 MB mounted image exports to something a PXE client pulls quickly.
        Export-WindowsImage -SourceImagePath $SourcePath -SourceIndex $Index `
            -DestinationImagePath $DestinationPath -CompressionType Max | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetScratchSpace -Value {
        param([string] $MountPath, [int] $Megabyte)

        $this.Record('SetScratchSpace', @($MountPath, $Megabyte))

        # THERE IS NO CMDLET. The Dism module has no scratch-space verb, so this
        # is the one image operation that shells out to dism.exe.
        $imageArgument = '/Image:{0}' -f $MountPath
        $scratchArgument = '/Set-ScratchSpace:{0}' -f $Megabyte

        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes. No branch: rule 1 holds.
        $ErrorActionPreference = 'Continue'

        $output = @(& "$env:SystemRoot\System32\dism.exe" $imageArgument $scratchArgument 2>&1)

        $this.AssertExitCode($LASTEXITCODE, 'dism.exe',
            ('dism {0} {1}' -f $imageArgument, $scratchArgument), $output)
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetTimeZone -Value {
        param([string] $MountPath, [string] $Name)

        $this.Record('SetTimeZone', @($MountPath, $Name))

        # THE ZONE IS SET IN THE IMAGE, NOT AT BOOT, AND THAT IS THE WHOLE POINT.
        # HDT used to write `tzutil /s "<id>"` into startnet.cmd. tzutil.exe IS
        # NOT IN WinPE - captured proof in
        # tests/fixtures/winpe/winpe-command-amd64.json, and confirmed at a real
        # WinPE prompt - so cmd.exe printed "is not recognized", startnet ran on
        # to the next line, and every deployment stayed on the image's baked-in
        # Pacific Standard Time. Nothing failed anywhere. The symptom was an
        # engine reporting a UTC eleven hours out while `time` at the prompt read
        # correctly: the hardware clock was right and the ZONE had never moved.
        #
        # /Set-TimeZone WRITES
        # HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation IN THE
        # OFFLINE IMAGE - the very key whose Pacific default produced that -8.
        #
        # IT WRITES THE STANDARD HALF OF THAT KEY AND ONLY THAT HALF, which this
        # comment claimed otherwise for a release and cost a second measured
        # defect. Read back out of a built image, dism leaves:
        #
        #   Bias -120, StandardBias 0, TimeZoneKeyName and StandardName correct;
        #   DaylightBias 0, DaylightName empty, StandardStart and DaylightStart
        #   ALL ZEROS, no ActiveTimeBias at all, and DynamicDaylightTimeDisabled
        #   left at the 1 the ADK ships.
        #
        # With no ActiveTimeBias the kernel falls back to Bias + StandardBias -
        # -120 the year round, where a correct machine reads -180 between the
        # March and October transitions. That is the hour every WinPE timestamp
        # on the live Dell run was ahead of true UTC by, and it is not WinPE
        # refusing to perform daylight transitions: the image was never given a
        # rule to perform. SetTimeZoneDaylight below supplies the missing half.
        #
        # IT VALIDATES BEFORE IT WRITES. DISM checks the id against the image, so
        # a zone that does not exist there fails the BUILD, at a build host, with
        # a message - rather than failing a boot in a datacentre with silence.
        # That is the property the old mechanism could not have at any price.
        #
        # OFFLINE ONLY. dism refuses /Set-TimeZone against /Online, which is why
        # it takes a mount path and never a switch.
        $imageArgument = '/Image:{0}' -f $MountPath
        $zoneArgument = '/Set-TimeZone:{0}' -f $Name

        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes. No branch: rule 1 holds.
        $ErrorActionPreference = 'Continue'

        $output = @(& "$env:SystemRoot\System32\dism.exe" $imageArgument $zoneArgument 2>&1)

        $this.AssertExitCode($LASTEXITCODE, 'dism.exe',
            ('dism {0} {1}' -f $imageArgument, $zoneArgument), $output)
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetTimeZoneDaylight -Value {
        param([string] $MountPath, [object[]] $Value)

        $this.Record('SetTimeZoneDaylight', @($MountPath, $Value))

        # THE HALF dism DOES NOT WRITE. See SetTimeZone above for the measured
        # shape of what it leaves behind. The values come from
        # ConvertTo-HDTTimeZoneDaylightValue, which is where every decision about
        # them lives - including the one not to emit ActiveTimeBias, so that
        # nothing here bakes the build day's answer into an image that is booted
        # for months. This method writes what it is handed and decides nothing.
        #
        # THE OFFLINE HIVE HAS TO BE LOADED TO BE WRITTEN. There is no dism verb
        # for these values and no Dism cmdlet either, so the image's own SYSTEM
        # hive is mounted under a scratch key, written, and unloaded again.
        $hivePath = [System.IO.Path]::Combine($MountPath, 'Windows\System32\config\SYSTEM')
        $scratchKey = 'HDTBootImageTimeZone'
        $scratchPath = 'HKLM\{0}' -f $scratchKey

        $loadOutput = @(& "$env:SystemRoot\System32\reg.exe" load $scratchPath $hivePath 2>&1)

        # EXIT-CODE CHECK, not a decision.
        $this.AssertExitCode($LASTEXITCODE, 'reg.exe',
            ('reg load {0} {1}' -f $scratchPath, $hivePath), $loadOutput)

        try {
            # ControlSet001 BY NAME, AND THAT IS CORRECT HERE RATHER THAN LAZY.
            # An offline hive has no CurrentControlSet - that link is made at
            # boot - and a WinPE image has exactly ONE control set: the ADK's
            # winpe.wim SYSTEM hive carries ControlSet001, DriverDatabase,
            # Keyboard Layout, RNG, Select, Setup, Software and WPA, and nothing
            # else. Resolving Select\Current would be a branch that can only ever
            # answer 1.
            $keyPath = 'HKLM:\{0}\ControlSet001\Control\TimeZoneInformation' -f $scratchKey

            foreach ($item in @($Value)) {
                Set-ItemProperty -LiteralPath $keyPath -Name ([string] $item.Name) `
                    -Value $item.Data -Type ([string] $item.Kind)
            }
        } finally {
            # THE UNLOAD FAILS WITHOUT THIS, AND IT WAS MEASURED FAILING.
            # PowerShell's registry provider keeps a handle open on every key it
            # has touched, so reg unload answers "Access is denied" and the hive
            # stays loaded - after which the image cannot be dismounted and the
            # build fails somewhere that says nothing about a registry.
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()

            $unloadOutput = @(& "$env:SystemRoot\System32\reg.exe" unload $scratchPath 2>&1)

            # EXIT-CODE CHECK, not a decision - and it warns rather than throws
            # because this is a finally block: a hive that would not unload must
            # not replace the real failure that brought us here.
            if ($LASTEXITCODE -ne 0) {
                Write-Warning ("reg unload of '{0}' exited {1}, so the image's SYSTEM hive is still loaded and the dismount will fail: {2}" -f
                    $scratchPath, $LASTEXITCODE, (@($unloadOutput) -join ' '))
            }
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name NewIso -Value {
        param([string] $MediaRoot, [string] $IsoPath, [string[]] $Argument)

        $this.Record('NewIso', @($MediaRoot, $IsoPath, $Argument))

        # Resolved at CALL time, not at construction time, so this service can be
        # created on a machine with no ADK - which is what every unit test and
        # the contract's fake row do.
        $oscdimg = $this.OscdimgPath
        if ([string]::IsNullOrWhiteSpace($oscdimg)) {
            $oscdimg = Get-HDTAdkPath -Asset Oscdimg
        }

        $full = @($Argument) + @($MediaRoot, $IsoPath)

        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes. No branch: rule 1 holds.
        $ErrorActionPreference = 'Continue'

        $output = @(& $oscdimg @full 2>&1)

        $this.AssertExitCode($LASTEXITCODE, 'oscdimg.exe',
            ('{0} {1}' -f $oscdimg, ($full -join ' ')), $output)
    }

    return $service
}
