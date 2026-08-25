function Get-HDTWizardSelection {
    <#
        .SYNOPSIS
            What a column of tick boxes answers with: the ticked rows' ids, in
            one string.

        .DESCRIPTION
            wizard.yaml's collect declarations read ONE property off ONE control
            - Text, SelectedValue, Password, IsChecked - and "every ticked row,
            joined" is none of them. That is exactly why the Applications page
            shipped collecting nothing: rather than bend a single-value
            declaration into a multi-value one from the markup side, the page
            went out honest and this is the shape it needed.

            A COMMAND, NOT A BRANCH INSIDE THE ADAPTER. New-HDTWizardHost is
            exempt from TDD only for as long as it decides nothing, and the
            separator, the ordering and what to do with a row carrying no id are
            all decisions. The host calls this and assigns the answer.

            THE ROWS, NOT THE VISUAL TREE. The page binds each CheckBox TwoWay to
            its row's IsSelected, so the technician's ticks are on the objects
            the host handed the control - which is what lets this be a pure
            function with no window, no desktop and no WinPE anywhere near it.

            ', ' BECAUSE THAT IS WHAT THE STEP SPLITS ON.
            Invoke-HDTInstallApplicationsStep splits HDTApplications on
            [,;\r\n]; a separator it does not split on would arrive as one very
            long id and fail after the technician had answered everything.

            DOCUMENT ORDER, NOT CLICK ORDER. The rows arrive sorted and the
            technician ticks them in whatever order they read the page. A
            variable that came back in click order would differ between two
            identical deployments and the report would show a difference nobody
            made.

            A ROW WITH NO ID IS SKIPPED. A blank between two commas is an id the
            installer would look up and fail on.

            A ROW WITH NO IsSelected READS AS UNTICKED. Set-StrictMode makes a
            missing property an exception and these rows come from a command a
            site is free to replace; unticked is the safe reading, because it
            installs nothing nobody asked for.

        .PARAMETER Row
            The rows the control was filled with. Null and empty both answer
            with an empty string - a page may declare a list it never fills.

        .PARAMETER Property
            The row property carrying the value to collect. Defaults to Id,
            which is what Get-HDTWizardApplication's rows carry; nothing here
            knows the word "application".

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String. Empty when nothing is ticked, which is a normal
            answer - a base image with no applications is most of what a lab
            deploys.

        .EXAMPLE
            $row = @(
                [pscustomobject] @{ Id = '7Zip-24.09'; IsSelected = $true }
                [pscustomobject] @{ Id = 'VSCode-1.96'; IsSelected = $false })
            Get-HDTWizardSelection -Row $row

            '7Zip-24.09'

        .EXAMPLE
            $root = 'Z:\Deploy'
            $catalog = Get-HDTWizardApplication -WorkspaceRoot $root
            Get-HDTWizardSelection -Row $catalog.Choice

            What a rules.yaml already selected, in the form HDTApplications
            takes - which is how the summary shows a page nobody changed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Row,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Property = 'Id'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $ticked = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($Row)) {

        if ($null -eq $current) { continue }

        # PSObject.Properties RATHER THAN A DIRECT READ. Under Set-StrictMode a
        # property that is not there is a terminating error, and a page that
        # threw while the window was being closed would lose every other answer
        # on it as well.
        if ($null -eq $current.PSObject.Properties[$Property]) { continue }
        if ($null -eq $current.PSObject.Properties['IsSelected']) { continue }

        if (-not [bool] $current.IsSelected) { continue }

        $value = [string] $current.$Property
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        [void] $ticked.Add($value.Trim())
    }

    return [string] (@($ticked) -join ', ')
}
