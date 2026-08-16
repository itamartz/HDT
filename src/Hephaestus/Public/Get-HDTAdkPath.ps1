function Get-HDTAdkPath {
    <#
        .SYNOPSIS
            Resolves a Windows ADK asset to a path, at runtime, through the
            registry rather than from a literal.

        .DESCRIPTION
            PROJECT.md: "Resolve ADK paths at runtime via Get-HDTAdkPath; the
            layout has moved between ADK releases." This is that command, and it
            is the only place in the engine that knows where anything in the ADK
            lives.

            THE ROOT COMES FROM THE REGISTRY, IN THIS ORDER, STOPPING AT THE
            FIRST THAT ANSWERS:

              1. -Root, when the caller supplies one;
              2. HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed
                 Roots -> KitsRoot10;
              3. HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots ->
                 KitsRoot10, the 32-bit view, for a session that is not
                 WOW-redirected.

            THERE IS NO FALLBACK TO A HARDCODED KIT PATH, and this file
            deliberately does not write one down even as an example - the
            contract check for that is a grep. A hardcoded fallback is how
            "resolve at runtime" gets quietly broken:
            it would work on the developer's machine forever and fail in the
            field, which is the failure mode the rule exists to prevent. When no
            key answers, this throws and names both keys.

            KitsRoot10 ends with a separator ('...\Windows Kits\10\'). It is
            trimmed, because the build manifest records these strings and a
            doubled separator in a manifest is noise.

            EVERY ASSET IS EXISTENCE-CHECKED THROUGH IFileSystem AND A MISS
            THROWS, naming the asset, the path it looked at, and which ADK
            feature installs it - Deployment Tools or the Windows PE add-on,
            which are separate installers and separately forgettable. The class
            is HDTDependencyError, matching ConvertFrom-HDTYaml's missing-parser
            gate, because a missing ADK is the same kind of problem: not the
            administrator's document, the machine's software.

            -All never throws for a missing asset. It returns Name / Path /
            Exists for every asset in table order, which is what the boot image
            manifest records and what an operator runs when a build fails.

            THE ASSET SET IS CLOSED, exactly as Get-HDTWorkspacePath -Kind is:
            an unknown asset is a defect, not a path.

              Root                            <KitsRoot10>Assessment and Deployment Kit
              DeploymentTools                 <root>\Deployment Tools\<arch>
              OscdimgDirectory                <root>\Deployment Tools\<arch>\Oscdimg
              Oscdimg                         ...\Oscdimg\oscdimg.exe
              EtfsBoot                        ...\Oscdimg\etfsboot.com
              EfiSys                          ...\Oscdimg\efisys.bin
              EfiSysNoPrompt                  ...\Oscdimg\efisys_noprompt.bin
              WinPeRoot                       <root>\Windows Preinstallation Environment\<arch>
              WinPeWim                        <winPeRoot>\<language>\winpe.wim
              WinPeMedia                      <winPeRoot>\Media
              WinPeOptionalComponent          <winPeRoot>\WinPE_OCs
              WinPeOptionalComponentLanguage  <winPeRoot>\WinPE_OCs\<language>

            SPIKES S3: efisys_noprompt.bin lives under Deployment Tools\<arch>\
            Oscdimg, NOT under the WinPE add-on's Media\EFI tree, which carries
            bootloaders and no El Torito boot image. DESIGN 5.2 was corrected to
            match, and this table is where that correction is now enforced.

        .PARAMETER Asset
            The ADK asset to resolve. Closed set; see the table above.

        .PARAMETER All
            Return every asset as a row of Name, Path and Exists, in table
            order, without throwing for a missing one.

        .PARAMETER Architecture
            The target architecture folder. amd64 (default) or arm64. Root is
            the one asset it does not affect.

        .PARAMETER Language
            The language folder, used by WinPeWim and
            WinPeOptionalComponentLanguage only. Defaults to en-us.

        .PARAMETER Root
            An explicit ADK root, which wins over the registry. For a build host
            pointed at a copied ADK, and for a test that must not read this
            machine's registry.

        .PARAMETER Registry
            An IRegistryService. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER SkipExistenceCheck
            Construct the path without checking that it is there. For the unit
            test that proves path CONSTRUCTION independently of what happens to
            be installed, and for a caller building a path on a machine that is
            not the build host.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String for -Asset.
            System.Management.Automation.PSCustomObject for -All: Name, Path,
            Exists.

        .EXAMPLE
            Get-HDTAdkPath -Asset Oscdimg

            The oscdimg.exe that builds the ISO.

        .EXAMPLE
            Get-HDTAdkPath -Asset EfiSysNoPrompt

            The El Torito image that removes "Press any key to boot from CD or
            DVD". Under Oscdimg, not under Media\EFI.

        .EXAMPLE
            Get-HDTAdkPath -Asset WinPeWim -Language en-us

            The 340 MB source WinPE the boot image is built from.

        .EXAMPLE
            Get-HDTAdkPath -All | Format-Table Name, Exists, Path -AutoSize

            What to run when a boot image build says the ADK is incomplete.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Asset')]
    [OutputType([string], ParameterSetName = 'Asset')]
    [OutputType([pscustomobject], ParameterSetName = 'All')]
    param(
        # Closed on purpose: an unknown asset is a defect, not a path.
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Asset')]
        [ValidateSet('Root', 'DeploymentTools', 'OscdimgDirectory', 'Oscdimg', 'EtfsBoot',
            'EfiSys', 'EfiSysNoPrompt', 'WinPeRoot', 'WinPeWim', 'WinPeMedia',
            'WinPeOptionalComponent', 'WinPeOptionalComponentLanguage')]
        [string] $Asset,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch] $All,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture = 'amd64',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Language = 'en-us',

        [Parameter()]
        [string] $Root,

        [Parameter()]
        [AllowNull()]
        [object] $Registry,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter(ParameterSetName = 'Asset')]
        [switch] $SkipExistenceCheck
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Registry) { $Registry = New-HDTRegistryService }
    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $wowKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    $nativeKey = 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'

    # -- the root -------------------------------------------------------------

    $adkRoot = ''

    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $adkRoot = $Root.TrimEnd('\', '/')
    } else {
        $kitsRoot = ''

        foreach ($key in @($wowKey, $nativeKey)) {
            if (-not [string]::IsNullOrWhiteSpace($kitsRoot)) { continue }

            $value = $Registry.GetValue($key, 'KitsRoot10')
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string] $value)) {
                $kitsRoot = ([string] $value).TrimEnd('\', '/')
            }
        }

        if ([string]::IsNullOrWhiteSpace($kitsRoot)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTDependencyError' -Category NotInstalled `
                        -TargetObject $wowKey `
                        -Message ("the Windows ADK could not be located: neither '{0}' nor '{1}' carries a KitsRoot10 value. Install the Windows ADK Deployment Tools (and the Windows PE add-on) on this machine, or pass -Root to name an ADK root explicitly." -f $wowKey, $nativeKey)))
        }

        $adkRoot = [System.IO.Path]::Combine($kitsRoot, 'Assessment and Deployment Kit')
    }

    # -- the table ------------------------------------------------------------
    #
    # [IO.Path]::Combine, not Join-Path: Get-HDTWorkspacePath's comment explains
    # why - a path must be constructible for a drive that is not mounted, and an
    # ADK root can name a share or a staged copy this session cannot see.

    $deploymentTools = [System.IO.Path]::Combine($adkRoot, 'Deployment Tools', $Architecture)
    $oscdimgDirectory = [System.IO.Path]::Combine($deploymentTools, 'Oscdimg')
    $winPeRoot = [System.IO.Path]::Combine($adkRoot, 'Windows Preinstallation Environment', $Architecture)
    $optionalComponent = [System.IO.Path]::Combine($winPeRoot, 'WinPE_OCs')

    # Ordered, because -All returns rows in this order and the boot image
    # manifest records them in it.
    $table = [System.Collections.Specialized.OrderedDictionary]::new()
    $table['Root'] = $adkRoot
    $table['DeploymentTools'] = $deploymentTools
    $table['OscdimgDirectory'] = $oscdimgDirectory
    $table['Oscdimg'] = [System.IO.Path]::Combine($oscdimgDirectory, 'oscdimg.exe')
    $table['EtfsBoot'] = [System.IO.Path]::Combine($oscdimgDirectory, 'etfsboot.com')
    $table['EfiSys'] = [System.IO.Path]::Combine($oscdimgDirectory, 'efisys.bin')
    $table['EfiSysNoPrompt'] = [System.IO.Path]::Combine($oscdimgDirectory, 'efisys_noprompt.bin')
    $table['WinPeRoot'] = $winPeRoot
    $table['WinPeWim'] = [System.IO.Path]::Combine($winPeRoot, $Language, 'winpe.wim')
    $table['WinPeMedia'] = [System.IO.Path]::Combine($winPeRoot, 'Media')
    $table['WinPeOptionalComponent'] = $optionalComponent
    $table['WinPeOptionalComponentLanguage'] = [System.IO.Path]::Combine($optionalComponent, $Language)

    # Which ADK installer puts each asset there. Two separate downloads, so an
    # operator who has one and not the other reads the right sentence.
    $feature = @{
        Root                           = 'Deployment Tools'
        DeploymentTools                = 'Deployment Tools'
        OscdimgDirectory               = 'Deployment Tools'
        Oscdimg                        = 'Deployment Tools'
        EtfsBoot                       = 'Deployment Tools'
        EfiSys                         = 'Deployment Tools'
        EfiSysNoPrompt                 = 'Deployment Tools'
        WinPeRoot                      = 'Windows PE add-on'
        WinPeWim                       = 'Windows PE add-on'
        WinPeMedia                     = 'Windows PE add-on'
        WinPeOptionalComponent         = 'Windows PE add-on'
        WinPeOptionalComponentLanguage = 'Windows PE add-on'
    }

    if ($All) {
        $row = New-Object -TypeName System.Collections.ArrayList

        foreach ($name in @($table.Keys)) {
            [void] $row.Add([pscustomobject] @{
                    Name   = [string] $name
                    Path   = [string] $table[$name]
                    Exists = [bool] $FileSystem.TestPath([string] $table[$name])
                })
        }

        return [pscustomobject[]] @($row)
    }

    $path = [string] $table[$Asset]

    if (-not $SkipExistenceCheck) {
        if (-not $FileSystem.TestPath($path)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTDependencyError' -Category ObjectNotFound `
                        -TargetObject $path `
                        -Message ("the ADK asset '{0}' is not at '{1}'. It is installed by the Windows ADK {2}; install that feature, or pass -Root to name the ADK root that has it. Get-HDTAdkPath -All lists every asset and whether it is present." -f $Asset, $path, $feature[$Asset])))
        }
    }

    return $path
}
