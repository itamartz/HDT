function Set-HDTDriverState {
    <#
        .SYNOPSIS
            Turns one driver on or off without taking it off the share.

        .DESCRIPTION
            Workbench's "Enable this driver" tick box. IT IS NOT A DELETE: the
            driver stays where it is, and every selection profile that includes
            its folder skips it. That is how one bad driver comes out of a vendor
            pack of forty without throwing the other thirty-nine away and without
            the next re-import putting it back.

            IT WRITES ONLY WHAT IS OFF, to Control\driver-state.yaml. Anything
            not named there is on, so a share nobody has disabled anything on has
            no document at all and a pack imported tomorrow arrives enabled. See
            Get-HDTDriverState for why that beats an index carrying a copy of
            every driver.

            ENABLING THE LAST DISABLED DRIVER REMOVES THE DOCUMENT rather than
            leaving 'disabled: []' behind. An empty list and no file mean the
            same thing, and two spellings of one state is one more thing to keep
            in step.

            THE PATH IS CHECKED AGAINST THE SHARE. A driver that is not there
            cannot be disabled - the commonest way to reach that is a stale
            console holding a path somebody has since deleted, and silently
            recording it would leave a document naming a file nobody can find.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Path
            The driver's .inf, relative to Drivers\.

        .PARAMETER Enabled
            Whether it should be injected.

        .PARAMETER FileSystem
            The IFileSystem to write with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Enabled and
            Changed.

        .EXAMPLE
            Set-HDTDriverState -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell WinPE 11 x64\network\e1d68x64.inf' -Enabled $false

            One driver out of a vendor pack, without deleting the pack.

        .EXAMPLE
            Set-HDTDriverState -Root 'C:\HDTLab\Share' -Path 'WinPE\HP\net.inf' -Enabled $true

            Back on again.

        .LINK
            Get-HDTDriver
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 2)]
        [bool] $Enabled,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $relative = $Path.Trim().TrimStart('\', '/')

    $store = Get-HDTWorkspacePath -Root $Root -Kind Drivers
    $full = [System.IO.Path]::Combine($store, $relative)

    if (-not $FileSystem.TestPath($full)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $full `
                    -Category ObjectNotFound `
                    -Message ("there is no driver at '{0}' on this share, so its state cannot be set." -f $relative)))
    }

    $disabled = New-Object -TypeName System.Collections.ArrayList
    foreach ($one in @(Get-HDTDriverState -Root $Root -FileSystem $FileSystem)) { [void] $disabled.Add($one) }

    $already = @($disabled | Where-Object { $_ -eq $relative })
    $changed = $false

    if ($Enabled -and (@($already).Count -gt 0)) {
        $keep = @($disabled | Where-Object { $_ -ne $relative })
        $disabled = New-Object -TypeName System.Collections.ArrayList
        foreach ($one in $keep) { [void] $disabled.Add($one) }
        $changed = $true
    }

    if ((-not $Enabled) -and (@($already).Count -eq 0)) {
        [void] $disabled.Add($relative)
        $changed = $true
    }

    if (-not $changed) {
        return [pscustomobject] @{ Path = $relative; Enabled = $Enabled; Changed = $false }
    }

    $action = 'Disable this driver'
    if ($Enabled) { $action = 'Enable this driver' }

    if (-not $PSCmdlet.ShouldProcess($relative, $action)) {
        return [pscustomobject] @{ Path = $relative; Enabled = (-not $Enabled); Changed = $false }
    }

    $statePath = Get-HDTWorkspacePath -Root $Root -Kind Control -ChildPath 'driver-state.yaml'

    # NOTHING OFF MEANS NO DOCUMENT. An empty list and an absent file say the
    # same thing, and keeping both spellings is one more thing to keep in step.
    if (@($disabled).Count -eq 0) {
        if ($FileSystem.TestPath($statePath)) { $FileSystem.RemoveItem($statePath, $false) }

        return [pscustomobject] @{ Path = $relative; Enabled = $Enabled; Changed = $true }
    }

    $line = New-Object -TypeName System.Collections.ArrayList
    [void] $line.Add('# Drivers turned off on this share. Anything not listed here is injected.')
    [void] $line.Add('#')
    [void] $line.Add('# The paths are relative to Drivers\ so this survives the share being')
    [void] $line.Add('# moved or mounted under another letter.')
    [void] $line.Add('schemaVersion: 1')
    [void] $line.Add('disabled:')

    foreach ($one in @($disabled | Sort-Object)) {
        [void] $line.Add(('  - {0}' -f (ConvertTo-HDTRuleScalarText -Value ([string] $one))))
    }

    $FileSystem.WriteAllText($statePath, (@($line) -join "`r`n"))

    return [pscustomobject] @{ Path = $relative; Enabled = $Enabled; Changed = $true }
}
