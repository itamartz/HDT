function Get-HDTWizardFocus {
    <#
        .SYNOPSIS
            Which control the cursor belongs in when a wizard page opens, and
            what to try next if that one will not take it.

        .DESCRIPTION
            MEASURED BEFORE IT WAS BUILT. An STA probe walked MoveFocus down the
            Computer Details page and found focus sitting on the WINDOW, with
            Tab 1 landing on the progress rail, Tab 2 on the page host, and Tab
            3 finally reaching HDTComputerNameBox. The first two are fixed in
            the markup with IsTabStop="False"; this is the other half - nothing
            in New-HDTWizardHost ever called Focus(), so a technician reached
            for the mouse or pressed Tab three times to get into a box that was
            already in front of them.

            A COMMAND, BECAUSE "FIRST" IS A DECISION. The adapter walks this
            list and focuses the first control that exists and will take focus;
            the ORDER is decided here, and the adapter stays a thing that
            decides nothing.

            THE ORDER IS collect's ORDER. A page already declares the controls
            it fills, in the order it fills them - MDT's panes read top to
            bottom and so do these - so the first thing declared is the first
            thing asked. Nothing new to author, and nothing that can drift out
            of step with the markup, because it IS the markup's own list.

            A LIST RATHER THAN ONE NAME, BECAUSE HALF A PAGE MAY BE DISABLED.
            Computer Details offers a domain OR a workgroup and disables
            whichever was not chosen; a control that cannot take focus must not
            cost the page its focus altogether. The host takes the first that
            will have it.

            EACH CONTROL ONCE. ComputerDetail's account box fills HDTDomainAdmin
            and, through the split, HDTDomainAdminDomain - two declarations, one
            box. Focus is about controls, not variables.

            A PAGE THAT COLLECTS NOTHING GETS NOTHING. The Summary page asks for
            nothing and its Deploy button is IsDefault, so Enter already works
            there; moving focus onto some arbitrary element would be worse than
            leaving it where WPF put it.

        .PARAMETER Page
            One page, as Import-HDTWizardDocument projects it. Null answers with
            nothing rather than throwing: the host calls this on every render,
            and a page that failed to load must not become a second failure on
            the way to the screen.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - control names, most-wanted first. Empty for a page
            that collects nothing.

        .EXAMPLE
            $provider = New-HDTLocalContentProvider -Root 'Z:\Deploy'
            $ask = Import-HDTWizardDocument -Provider $provider
            $page = @($ask.Page | Where-Object { $_.Id -eq 'ComputerDetail' })[0]
            Get-HDTWizardFocus -Page $page

            HDTComputerNameBox, then the rest of that page's boxes behind it.

        .EXAMPLE
            $provider = New-HDTLocalContentProvider -Root 'Z:\Deploy'
            $ask = Import-HDTWizardDocument -Provider $provider
            $page = @($ask.Page | Where-Object { $_.Id -eq 'Summary' })[0]
            @(Get-HDTWizardFocus -Page $page).Count

            0 - Ready to Deploy asks for nothing, so nothing is focused.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Page
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Page) { return [string[]] @() }
    if ($null -eq $Page.PSObject.Properties['Collect']) { return [string[]] @() }

    $wanted = New-Object -TypeName System.Collections.ArrayList
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList (
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($declaration in @($Page.Collect)) {

        if ($null -eq $declaration) { continue }
        if ($null -eq $declaration.PSObject.Properties['Control']) { continue }

        $control = ([string] $declaration.Control).Trim()
        if ([string]::IsNullOrWhiteSpace($control)) { continue }

        if (-not $seen.Add($control)) { continue }

        [void] $wanted.Add($control)
    }

    return [string[]] @($wanted)
}
