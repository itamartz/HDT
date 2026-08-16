function Get-HDTBootImageComponent {
    <#
        .SYNOPSIS
            The ordered, dependency-validated, existence-checked list of WinPE
            optional components a boot image build will apply.

        .DESCRIPTION
            Update-HDTBootImage mounts a 340 MB WIM and applies these cabs to it,
            a run that takes about fifteen minutes and needs elevation. Every
            decision that can be made before that run is made here, against
            injected services, in milliseconds - which cabs, in what order,
            whether each one is actually on disk, and whether the admin's
            declaration is internally consistent.

            THE REQUIRED SET, AND ITS ORDER, IS THE BOOT-VERIFIED ONE:

                WinPE-WMI -> WinPE-NetFx -> WinPE-Scripting -> WinPE-PowerShell
                  -> WinPE-StorageWMI -> WinPE-DismCmdlets

            THAT ORDER WAS VERIFIED BY A MACHINE THAT BOOTED. DO NOT SORT IT and
            do not "tidy" it alphabetically. Note WinPE-NetFx - LOWERCASE x.
            An earlier draft capitalised that x, and
            no cab of the capitalised name exists. The misspelling is written
            nowhere in this repository's source, deliberately, so that a grep for
            it stays a usable check.

            UNSET AND SET-TO-NOTHING ARE DIFFERENT INSTRUCTIONS. Omitting
            -OptionalComponent means "the admin did not say", and takes DESIGN
            5.1's defaults - WinPE-SecureStartup, WinPE-EnhancedStorage,
            WinPE-WDS-Tools. Passing an explicit empty array means "the six and
            nothing else", and is honoured.

            MERGE RULES:
              - the six always come first, in their order, whatever was declared;
              - a declared component that is already required is dropped from the
                tail rather than applied twice, and does not reorder the six;
              - the remaining declarations keep the order they were written in
                ("merged with the required set below, order
                preserved");
              - comparison is case-insensitive throughout.

            DEPENDENCY VALIDATION comes from Get-HDTBootImageComponentDependency,
            whose every row is transcribed from the component's own package
            manifest inside the ADK cab. A component NOT in that table is allowed
            with no dependencies and no warning - the point is that
            a fleet needs components this project never anticipated. A component
            IN the table whose dependency is absent from the final list is
            REFUSED, naming both and telling the admin to add it. HDT does not
            insert it silently: an admin who is told gets a boot image they
            understand.

            -Dependency IS NOT A TEST HOOK. It is the same injection every other
            decision in this engine takes, it defaults to the shipped table, and
            it is what lets the RULE be proven against rows nobody has to believe
            while the shipped TABLE is proven separately by its own provenance
            test.

            FILESYSTEM CONTACT, AND ONLY THIS:
              - CabPath must exist, or this throws naming the component, the path
                and the component root. A build that applies a cab which is not
                there fails fifteen minutes in, with a WIM mounted.
              - LanguageCabPath is PROBED. Absent, the property is '' and one
                warning names the component. Twelve of this ADK's 33 components
                have no en-us pack - WinPE-FMAPI among them - so this must never
                be an error ("the builder must probe rather than
                assume").

        .PARAMETER OptionalComponent
            The components declared in workspace.yaml, or on
            Update-HDTBootImage -OptionalComponent. Omit for the defaults;
            pass @() for none.

        .PARAMETER ComponentRoot
            The WinPE_OCs folder, from Get-HDTAdkPath -Asset
            WinPeOptionalComponent.

        .PARAMETER Language
            The language pack folder under the component root. Defaults to en-us.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Dependency
            The dependency table. Defaults to
            Get-HDTBootImageComponentDependency.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per component, in
            the order they must be applied:

              Order            [int]    1-based
              Name             [string] WinPE-WMI
              Required         [bool]   true for the six
              CabPath          [string] <root>\WinPE-WMI.cab
              LanguageCabPath  [string] <root>\en-us\WinPE-WMI_en-us.cab, or ''

        .EXAMPLE
            Get-HDTBootImageComponent -ComponentRoot (Get-HDTAdkPath -Asset WinPeOptionalComponent)

            The nine components a default HDT boot image carries.

        .EXAMPLE
            $workspace = Import-HDTWorkspaceDocument -Path $path -FileSystem $fs
            Get-HDTBootImageComponent -OptionalComponent $workspace.BootImage.OptionalComponent `
                -ComponentRoot (Get-HDTAdkPath -Asset WinPeOptionalComponent) `
                -Language $workspace.BootImage.Language -FileSystem $fs

            What Update-HDTBootImage does: the document decides, this plans.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $OptionalComponent,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ComponentRoot,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Language = 'en-us',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Dependency
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Dependency) { $Dependency = Get-HDTBootImageComponentDependency }

    # SPIKES S1, verified by a machine that booted. Do not sort this.
    $requiredComponent = @('WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting',
        'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets')

    # DESIGN 5.1's defaults, applied only when the caller said nothing at all.
    $defaultOptionalComponent = @('WinPE-SecureStartup', 'WinPE-EnhancedStorage', 'WinPE-WDS-Tools')

    $declared = $defaultOptionalComponent
    if ($PSBoundParameters.ContainsKey('OptionalComponent')) {
        $declared = @($OptionalComponent)
    }

    # -- the merge ------------------------------------------------------------

    $plan = New-Object -TypeName System.Collections.ArrayList
    $seen = New-Object -TypeName System.Collections.ArrayList

    foreach ($name in $requiredComponent) {
        [void] $plan.Add([pscustomobject] @{ Name = $name; Required = $true })
        [void] $seen.Add($name.ToLowerInvariant())
    }

    foreach ($name in @($declared)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $comparable = $name.ToLowerInvariant()
        if ($seen -contains $comparable) { continue }

        [void] $plan.Add([pscustomobject] @{ Name = $name; Required = $false })
        [void] $seen.Add($comparable)
    }

    # -- dependency validation ------------------------------------------------
    #
    # Against the FINAL list, so a dependency declared later in the file still
    # satisfies one declared earlier - the admin's ordering of the tail is their
    # business, and refusing on it would be refusing a build that works.

    $planned = @($plan | ForEach-Object { $_.Name })

    foreach ($item in $plan) {
        if (-not $Dependency.ContainsKey($item.Name)) { continue }

        foreach ($requirement in @($Dependency[$item.Name].Requires)) {
            if ($seen -contains ([string] $requirement).ToLowerInvariant()) { continue }

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $item.Name `
                        -Message ("the WinPE component '{0}' requires '{1}', which is not in this boot image. Add '{1}' to optionalComponents in workspace.yaml, before or after '{0}' - HDT will not add it for you, because a boot image should hold what its administrator asked for. The components planned are: {2}. Source for this dependency: {3}" -f
                            $item.Name, $requirement, ($planned -join ', '), $Dependency[$item.Name].Source)))
        }
    }

    # -- the paths ------------------------------------------------------------

    $row = New-Object -TypeName System.Collections.ArrayList
    $order = 0

    foreach ($item in $plan) {
        $order++

        $cabPath = [System.IO.Path]::Combine($ComponentRoot, ('{0}.cab' -f $item.Name))

        if (-not $FileSystem.TestPath($cabPath)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $cabPath -Category ObjectNotFound `
                        -Message ("the WinPE component '{0}' has no cab at this path. It is not among the components '{1}' carries - check the spelling (note WinPE-NetFx has a lowercase x) or install the matching Windows PE add-on." -f $item.Name, $ComponentRoot)))
        }

        $languageCabPath = [System.IO.Path]::Combine($ComponentRoot, $Language,
            ('{0}_{1}.cab' -f $item.Name, $Language))

        if (-not $FileSystem.TestPath($languageCabPath)) {
            # NOT an error. WinPE-FMAPI and eleven others ship no language pack
            # in this ADK, and DESIGN 5.1 says to probe rather than assume.
            Write-Warning ("The WinPE component '{0}' has no {1} language pack in '{2}'. The component will be applied without one." -f $item.Name, $Language, $ComponentRoot)
            $languageCabPath = ''
        }

        [void] $row.Add([pscustomobject] @{
                Order           = $order
                Name            = [string] $item.Name
                Required        = [bool] $item.Required
                CabPath         = $cabPath
                LanguageCabPath = $languageCabPath
            })
    }

    return [pscustomobject[]] @($row)
}
