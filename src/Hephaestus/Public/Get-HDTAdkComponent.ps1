function Get-HDTAdkComponent {
    <#
        .SYNOPSIS
            Every WinPE optional component this build host's ADK can inject, with
            its size, its language packs and what it depends on.

        .DESCRIPTION
            THE QUESTION THAT COMES BEFORE THE COMPONENT LIST. Until this existed,
            the only way to find out what could be added to a boot image was to
            open the ADK folder in Explorer, or to guess a name and wait for a
            build to refuse it. Get-HDTBootImageComponent validates a list an
            administrator has already written; this is what tells them what there
            is to write.

            THE FOLDER IS RESOLVED, NEVER A LITERAL. The ADK layout has moved
            between releases, so the WinPE_OCs path comes from Get-HDTAdkPath,
            which reads the kit root out of the registry. Passing -ComponentRoot
            overrides that, for a staged copy or for a machine that is not the
            build host.

            SIZE IS HERE BECAUSE IT DECIDES THINGS. A boot image is held in RAM on
            the machine that booted it, and the components differ by three orders
            of magnitude - the .NET component is tens of megabytes, a cmdlet
            component is tens of kilobytes. An administrator choosing between two
            ways to do something should be able to see what each costs.

            LANGUAGE PACKS ARE PROBED, NEVER ASSUMED. Twelve of this ADK's
            thirty-three components ship none at all, so LanguagePack is empty for
            them rather than missing - and a build applies those components
            without one instead of failing.

            Requires IS THE SAME TABLE THE BUILD ENFORCES, every row of it
            transcribed from the component's own package manifest inside the cab.
            A component with a dependency that is not in the boot image is refused
            at build time, naming both; seeing it here is how that is avoided
            rather than discovered.

            Required MARKS THE SIX EVERY HDT BOOT IMAGE APPLIES whatever the
            workspace says - the engine rests on PowerShell and DISM inside WinPE.
            They are not configuration and they are not in any document.

            Declared IS WHAT THE WORKSPACE ASKED FOR, when one is named. It
            reflects the optionalComponents list with the engine's defaults
            already applied, so it answers "will this be in my image" rather than
            "is this key written down".

            IT READS THROUGH AN IFileSystem like everything else, so a console can
            populate a picker from it and a test can prove it with no ADK
            installed.

        .PARAMETER ComponentRoot
            The WinPE_OCs folder. Resolved through Get-HDTAdkPath when omitted.

        .PARAMETER Architecture
            Which architecture's WinPE_OCs to resolve. Ignored when
            -ComponentRoot names one outright.

        .PARAMETER Name
            Return only the components whose name matches this wildcard.

        .PARAMETER WorkspaceRoot
            A deployment share whose workspace.yaml decides the Declared column.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter by default.

        .PARAMETER Registry
            An IRegistryService, for resolving the ADK root. Defaults to the real
            adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per component, in
            name order:

              Name          [string]   WinPE-WMI
              CabPath       [string]   <root>\WinPE-WMI.cab
              SizeBytes     [long]
              LanguagePack  [string[]] the languages a pack exists for
              Requires      [string[]] the components it needs beside it
              Required      [bool]     one of the six every image applies
              Declared      [bool]     the named workspace asks for it

        .EXAMPLE
            Get-HDTAdkComponent | Format-Table Name, Required, SizeBytes -AutoSize

            What this build host can offer.

        .EXAMPLE
            Get-HDTAdkComponent -Name 'WinPE-Setup*'

            The setup components, and which of them depend on which.

        .EXAMPLE
            Get-HDTAdkComponent -WorkspaceRoot 'C:\HDTLab\Share' |
                Where-Object { $_.Declared -or $_.Required }

            Exactly what the next boot image build from that share will apply.

        .LINK
            Add-HDTBootImageComponent

        .LINK
            Get-HDTBootImageComponent

        .LINK
            Get-HDTAdkPath
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $ComponentRoot,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture = 'amd64',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = '*',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        # DEFAULTED, NOT MANDATORY, because this is a command an administrator
        # types. A test still passes the fake explicitly, and must.
        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem),

        [Parameter()]
        [AllowNull()]
        [object] $Registry
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The boot-verified six, applied to every HDT boot image whatever a workspace
    # says. Get-HDTBootImageComponent owns the ORDER; this only has to know which
    # names are in the set.
    $requiredComponent = @('WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting',
        'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets')

    $dependency = Get-HDTBootImageComponentDependency

    # -- the folder -----------------------------------------------------------

    $root = $ComponentRoot

    if ([string]::IsNullOrWhiteSpace($root)) {
        $adkSplat = @{
            Asset        = 'WinPeOptionalComponent'
            Architecture = $Architecture
            FileSystem   = $FileSystem
        }
        if ($null -ne $Registry) { $adkSplat['Registry'] = $Registry }

        $root = Get-HDTAdkPath @adkSplat
    }

    if (-not $FileSystem.TestPath($root)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTDependencyError' -Category ObjectNotFound `
                    -TargetObject $root `
                    -Message ("there is no WinPE optional component folder at '{0}'. It is installed by the Windows ADK Windows PE add-on, which is a separate download from the Deployment Tools; install that feature, or pass -ComponentRoot to name a staged copy. Get-HDTAdkPath -All lists every ADK asset and whether it is present." -f $root)))
    }

    # -- what is in it --------------------------------------------------------
    #
    # A directory has no length, so GetLength is what separates the component
    # cabs from the language folders beside them. It is the same test
    # Update-HDTBootImage uses to walk the engine tree, and the IFileSystem
    # contract does not carry a "is this a directory" method.

    $cab = New-Object -TypeName System.Collections.ArrayList
    $languageFolder = New-Object -TypeName System.Collections.ArrayList

    foreach ($child in @($FileSystem.GetChildItem($root))) {
        $leaf = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))

        $size = [long] 0
        $isFile = $true
        try { $size = [long] $FileSystem.GetLength($child) } catch { $isFile = $false }

        if (-not $isFile) {
            [void] $languageFolder.Add($leaf)
            continue
        }

        # lp.cab sits in every language folder and is the language pack for WinPE
        # itself, not an optional component. Nothing at the top of this folder is
        # a component unless it is named like one.
        if ($leaf -notmatch '^(WinPE-[A-Za-z0-9-]+)\.cab$') { continue }

        [void] $cab.Add([pscustomobject] @{
                Name      = $Matches[1]
                CabPath   = [string] $child
                SizeBytes = $size
            })
    }

    # -- the language packs beside them ---------------------------------------

    $pack = @{}

    foreach ($folder in @($languageFolder)) {
        $folderPath = [System.IO.Path]::Combine($root, $folder)

        foreach ($child in @($FileSystem.GetChildItem($folderPath))) {
            $leaf = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))

            if ($leaf -notmatch ('^(WinPE-[A-Za-z0-9-]+)_{0}\.cab$' -f [regex]::Escape($folder))) { continue }

            $component = $Matches[1]
            if (-not $pack.ContainsKey($component)) { $pack[$component] = New-Object -TypeName System.Collections.ArrayList }

            [void] $pack[$component].Add($folder)
        }
    }

    # -- what the workspace asks for ------------------------------------------

    $declared = New-Object -TypeName System.Collections.ArrayList

    if ($PSBoundParameters.ContainsKey('WorkspaceRoot')) {
        $workspacePath = [System.IO.Path]::Combine($WorkspaceRoot, 'workspace.yaml')
        $workspace = Import-HDTWorkspaceDocument -Path $workspacePath -FileSystem $FileSystem

        foreach ($current in @($workspace.BootImage.OptionalComponent)) {
            [void] $declared.Add(([string] $current).ToLowerInvariant())
        }
    }

    # -- the rows -------------------------------------------------------------

    $row = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($cab | Sort-Object -Property Name)) {
        if ([string] $current.Name -notlike $Name) { continue }

        $requires = [string[]] @()
        if ($dependency.ContainsKey([string] $current.Name)) {
            $requires = [string[]] @($dependency[[string] $current.Name].Requires)
        }

        $language = [string[]] @()
        if ($pack.ContainsKey([string] $current.Name)) {
            $language = [string[]] @(@($pack[[string] $current.Name]) | Sort-Object)
        }

        [void] $row.Add([pscustomobject] @{
                Name         = [string] $current.Name
                CabPath      = [string] $current.CabPath
                SizeBytes    = [long] $current.SizeBytes
                LanguagePack = $language
                Requires     = $requires
                Required     = [bool] ($requiredComponent -contains [string] $current.Name)
                Declared     = [bool] ($declared -contains ([string] $current.Name).ToLowerInvariant())
            })
    }

    return [pscustomobject[]] @($row)
}
