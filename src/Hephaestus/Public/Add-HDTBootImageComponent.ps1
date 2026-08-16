function Add-HDTBootImageComponent {
    <#
        .SYNOPSIS
            Declares a WinPE optional component for the boot image, leaving every
            other line of workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to add a WinPE optional component,
            and the one anything with an Add Component button has to run.

            RUN Get-HDTAdkComponent FIRST to see what this build host can offer,
            what each cab costs and what it depends on. This command checks the
            NAME's shape; whether a cab of that name exists is settled against the
            ADK, by Get-HDTAdkComponent now or by the build later.

            ADDING NEVER REMOVES. An absent optionalComponents key does not mean
            "no components": it means the administrator did not say, and the
            engine applies WinPE-SecureStartup, WinPE-EnhancedStorage and
            WinPE-WDS-Tools. Writing only the new name would delete those three
            from the image, which is the last thing anybody typing Add expects -
            so the first add to an unstated list writes the defaults out with it.
            The defaults come from the engine's own reader rather than from a copy
            kept here, so there is one place they can change.

            THE REQUIRED SIX ARE NOT WRITTEN AND CANNOT BE ADDED. WinPE-WMI,
            WinPE-NetFx, WinPE-Scripting, WinPE-PowerShell, WinPE-StorageWMI and
            WinPE-DismCmdlets are applied to every HDT boot image, first, in an
            order a machine that booted verified. They are not configuration, and
            a document that listed them would be a document that could disagree
            with the engine.

            IT SPLICES LINES AND NEVER PARSES AND RE-EMITS, so the trailing
            comment somebody wrote beside an existing component - `- WinPE-SecureStartup    # BitLocker` -
            is still there afterwards.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The components to add, in the order they should be written. A
            component is named as the ADK names its cab - WinPE-WMI, WinPE-NetFx;
            note the lowercase x.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the components added.

        .EXAMPLE
            Add-HDTBootImageComponent -Line $line -Name 'WinPE-HTA'

        .EXAMPLE
            Add-HDTBootImageComponent -Line $line -Name @('WinPE-Setup', 'WinPE-Setup-Client')

            A component and the one it depends on, in one edit.

        .LINK
            Get-HDTAdkComponent

        .LINK
            Get-HDTBootImageComponent
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line

    $declared = New-Object -TypeName System.Collections.ArrayList
    foreach ($current in @($workspace.BootImage.OptionalComponent)) {
        [void] $declared.Add(([string] $current).ToLowerInvariant())
    }

    foreach ($current in @($Name)) {
        if ($current -notmatch '^WinPE-[A-Za-z0-9-]+$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $current `
                        -Message ("'{0}' is not a WinPE optional component name. A component is named as the ADK names its cab, for example WinPE-WMI or WinPE-NetFx - note the lowercase x. Run Get-HDTAdkComponent for the ones this build host can offer." -f $current)))
        }

        $comparable = $current.ToLowerInvariant()

        if ($declared -contains $comparable) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $current `
                        -Message ("'{0}' is already in this boot image. Component names are compared without regard to case, and applying a cab twice is not a thing to ask for by accident." -f $current)))
        }

        [void] $declared.Add($comparable)
    }

    if (-not $PSCmdlet.ShouldProcess((@($Name) -join ', '), 'Add to the boot image components')) {
        return [string[]] @($Line)
    }

    $block = Get-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'optionalComponents')
    $result = [string[]] @($Line)

    if ($null -ne $block) {
        # ONE ENTRY PER LINE, APPENDED. Rewriting the list would lose whatever
        # was written beside the components already in it.
        foreach ($current in @($Name)) {
            $block = Get-HDTWorkspaceKey -Line $result -Path @('bootImage', 'optionalComponents')

            $result = [string[]] @(Add-HDTWorkspaceItem -Line $result -Block $block `
                    -Text ([string[]] @('- {0}' -f (ConvertTo-HDTRuleScalarText -Value $current))))
        }
    } else {
        # THE UNSTATED DEFAULTS ARE WRITTEN OUT WITH THE NEW ONE, so an add adds.
        $written = New-Object -TypeName System.Collections.ArrayList
        [void] $written.Add('optionalComponents:')

        foreach ($current in @(@($workspace.BootImage.OptionalComponent) + @($Name))) {
            [void] $written.Add('  - {0}' -f (ConvertTo-HDTRuleScalarText -Value ([string] $current)))
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $result -Path @('bootImage', 'optionalComponents') `
                -Text ([string[]] @($written)))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
