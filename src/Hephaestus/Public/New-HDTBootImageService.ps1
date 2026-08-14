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

            NINE METHODS, AND THE EXACT MECHANISM EACH WRAPS:

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
                  340 134 390 bytes; a finished HDT boot image is about 480 MB
                  (SPIKES S1), and the difference is how "the build applied
                  nothing" is spotted.

              ExportImage(sourcePath, index, destinationPath)
                  Export-WindowsImage -SourceImagePath -SourceIndex
                      -DestinationImagePath -CompressionType Max
                  which is DESIGN 5.1's /Compress:max.

              SetScratchSpace(mountPath, megabyte)
                  dism.exe /Image:<mount> /Set-ScratchSpace:<mb>. THERE IS NO
                  CMDLET for this - the Dism module exposes no scratch-space
                  verb at all - so it is the one image operation that shells out.

              NewIso(mediaRoot, isoPath, argument)
                  oscdimg.exe @argument <mediaRoot> <isoPath>

            NewIso TAKES THE ARGUMENT ARRAY ALREADY BUILT. Every decision -
            firmware, -NoPromptForKey, the space-free staging SPIKES S2 requires
            - lives in Get-HDTBootIsoArgument, which is pure string logic and is
            therefore fully tested. This method runs the process and checks
            $LASTEXITCODE. That division is the whole of DESIGN 12.2.3 in one
            method.

            THIS IS AN UNTESTED ADAPTER (DESIGN 12.2.3), and deliberately so:
            eight of its nine methods mount a WIM, write into a mounted image,
            export half a gigabyte or burn an ISO, and every one of them needs
            elevation. Its contract row calls GetImageInfo and nothing else; the
            rest is proven in tests/integration/BootImage.Integration.Tests.ps1,
            which builds a real image and re-mounts it read-only to read
            startnet.cmd back out. The price of not testing it is that it must
            stay dumb. THE ONLY BRANCHES BELOW ARE TWO EXISTENCE GUARDS, TWO
            EXIT-CODE CHECKS, ONE LAZY PATH RESOLUTION AND ONE ARGUMENT
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
            System.Management.Automation.PSCustomObject with the nine
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

            The mount/apply/commit cycle DESIGN 5.1 specifies, as three calls.
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
