function Remove-HDTBootImageComponent {
    <#
        .SYNOPSIS
            Stops a WinPE optional component being applied to the boot image,
            leaving every other line of workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to drop a WinPE optional
            component, and the one anything with a Remove button has to run.

            REMOVING THE LAST ONE WRITES AN EMPTY LIST, NOT NOTHING. An absent
            optionalComponents key means "the administrator did not say" and takes
            three defaults; an explicit empty list means "the required six and
            nothing else". Deleting the key would therefore bring back the very
            components that had just been removed, so the key stays and becomes
            [].

            A COMPONENT THAT IS NOT THERE IS AN ERROR, and that includes one that
            was only ever there by default: removing an unstated default writes
            the remaining defaults out, which is the only way to say "these two
            and not the third".

            THE REQUIRED SIX CANNOT BE REMOVED, because they are not in this list
            to begin with. WinPE-WMI, WinPE-NetFx, WinPE-Scripting,
            WinPE-PowerShell, WinPE-StorageWMI and WinPE-DismCmdlets are applied
            to every HDT boot image; the engine rests on PowerShell and DISM
            inside WinPE, so an image without them is not one this toolkit can
            deploy from.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The components to remove.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the components removed.

        .EXAMPLE
            Remove-HDTBootImageComponent -Line $line -Name 'WinPE-WDS-Tools'

        .LINK
            Add-HDTBootImageComponent

        .LINK
            Get-HDTAdkComponent
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
        [void] $declared.Add([string] $current)
    }

    $going = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($Name)) {
        $at = -1

        for ($i = 0; $i -lt $declared.Count; $i++) {
            if ([string] $declared[$i] -eq $current) { $at = $i; break }
            if (([string] $declared[$i]).ToLowerInvariant() -eq $current.ToLowerInvariant()) { $at = $i; break }
        }

        if ($at -lt 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $current -Category ObjectNotFound `
                        -Message ("'{0}' is not a component this boot image applies. It carries {1}, plus the six every HDT image applies whatever the document says." -f
                            $current, (@($declared) -join ', '))))
        }

        if ($going -contains ([string] $declared[$at])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $current `
                        -Message ("'{0}' was named twice in one removal." -f $current)))
        }

        [void] $going.Add([string] $declared[$at])
    }

    if (-not $PSCmdlet.ShouldProcess((@($Name) -join ', '), 'Remove from the boot image components')) {
        return [string[]] @($Line)
    }

    $result = [string[]] @($Line)
    $block = Get-HDTWorkspaceKey -Line $result -Path @('bootImage', 'optionalComponents')

    if ($null -eq $block) {
        # THE DEFAULTS, MINUS THE ONES GOING, WRITTEN OUT. There is nothing in the
        # file to splice, and deleting from an unstated list has to say what is
        # left or it says nothing at all.
        $remaining = @($declared | Where-Object { $going -notcontains [string] $_ })
        $written = New-Object -TypeName System.Collections.ArrayList

        if (@($remaining).Count -eq 0) {
            # An empty list is written as one rather than as a key with nothing
            # under it, which the engine reads as a null.
            [void] $written.Add('optionalComponents: []')
        } else {
            [void] $written.Add('optionalComponents:')

            foreach ($current in @($remaining)) {
                [void] $written.Add('  - {0}' -f (ConvertTo-HDTRuleScalarText -Value ([string] $current)))
            }
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $result -Path @('bootImage', 'optionalComponents') `
                -Text ([string[]] @($written)))
    } else {
        # Highest position first, so removing one does not move the next.
        $position = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in @($going)) {
            [void] $position.Add([int] ([array]::IndexOf([string[]] @($declared), [string] $current)))
        }

        foreach ($at in @(@($position) | Sort-Object -Descending)) {
            $result = [string[]] @(Remove-HDTWorkspaceItem -Line $result `
                    -Path @('bootImage', 'optionalComponents') -Position ([int] $at) `
                    -EmptyText ([string[]] @('optionalComponents: []')))
        }
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
