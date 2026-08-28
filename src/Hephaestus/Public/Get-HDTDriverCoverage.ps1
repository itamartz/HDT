function Get-HDTDriverCoverage {
    <#
        .SYNOPSIS
            Which models in a fleet have a driver group, and which do not.

        .DESCRIPTION
            THE QUESTION ASKED AT 3 A.M., ANSWERED IN THE AFTERNOON. A model with
            no driver group deploys - it just deploys without its network card,
            and nobody finds out until somebody is standing in front of it. This
            says which models the share can dress before a deployment proves it
            cannot.

            IT ASKS THE SHARE, NOT A DATABASE. The group for a model is whatever
            path a rule builds - 'Win11\%HDTMake%\%HDTModel%' is the line
            New-HDTWorkspace seeds - so coverage is decided by expanding that
            pattern per model and looking. There is no second list of what the
            share is supposed to contain, because a second list is a thing that
            goes stale against the first.

            A GROUP WITH NO .inf FILES IN IT IS NOT COVERAGE. An empty folder is
            the commonest way this goes wrong: somebody made the folder, the
            import failed or was never run, and every tree in the console shows a
            group that injects nothing. It is reported as Present with a count of
            zero and Covered false, which is a different problem from a folder
            nobody created and wants a different fix.

            THE FLEET COMES FROM WHEREVER THE ADMINISTRATOR HAS IT. -Model takes
            the list directly - from a CSV, from a CMDB, from
            Get-CimInstance across a room - because HDT does not own an
            inventory and inventing one would be a second source of truth about
            somebody else's estate.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Model
            The models to check, as Win32_ComputerSystem.Model reports them.

        .PARAMETER Make
            The manufacturer, as Win32_ComputerSystem.Manufacturer reports it.
            Used when the pattern names %HDTMake%.

        .PARAMETER Pattern
            The group path, with %HDTMake% and %HDTModel% in it. Defaults to the
            shape New-HDTWorkspace seeds.

        .PARAMETER FileSystem
            The IFileSystem to read with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per model, with Make,
            Model, Group, FullPath, Present, DriverCount and Covered.

        .EXAMPLE
            Get-HDTDriverCoverage -Root 'C:\HDTLab\Share' -Make 'Dell inc' -Model 'Dell Pro 3 16 P316265'

            Whether the one model on the bench is covered.

        .EXAMPLE
            Get-HDTDriverCoverage -Root 'C:\HDTLab\Share' -Make 'Dell inc' `
                -Model (Import-Csv .\fleet.csv | Select-Object -ExpandProperty Model) |
                Where-Object { -not $_.Covered }

            The models a deployment would leave without drivers - which is the
            list worth having before the deployment, not after it.

        .LINK
            Get-HDTDriver

        .LINK
            Get-HDTDriverGroup
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        # BOTH ATTRIBUTES, AND THEY MEAN DIFFERENT THINGS.
        # AllowEmptyCollection permits -Model @(); AllowEmptyString permits an
        # empty ELEMENT inside a non-empty one. Without the second, a fleet list
        # with a blank row in it - which is what Import-Csv gives you for a
        # trailing comma - fails at PARAMETER BINDING, before the body's
        # IsNullOrWhiteSpace skip can run, with a message about a parameter
        # rather than about the inventory. Every real fleet list has a blank row
        # in it somewhere.
        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Model,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Make = '',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Pattern = 'Win11\%HDTMake%\%HDTModel%',

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $store = Get-HDTWorkspacePath -Root $Root -Kind Drivers
    $row = New-Object -TypeName System.Collections.ArrayList

    foreach ($one in @($Model)) {
        $name = [string] $one
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        # THE SAME EXPANSION A RULE WOULD DO, so coverage answers for the path
        # the deployment will actually look in rather than one this command
        # invented.
        $group = $Pattern.Replace('%HDTMake%', $Make).Replace('%HDTModel%', $name)

        # [IO.Path]::Combine, not Join-Path: a share root is routinely a UNC path
        # or a drive this process has not got, and Join-Path resolves the drive
        # qualifier.
        $full = [System.IO.Path]::Combine($store, $group.TrimStart('\', '/'))

        $present = [bool] $FileSystem.TestPath($full)
        $count = 0

        if ($present) {
            try {
                $count = [int] (Measure-HDTDriverInf -Path $full -FileSystem $FileSystem)
            } catch {
                # A FOLDER THAT CANNOT BE COUNTED IS REPORTED AS ZERO, not as an
                # error that ends the report. This runs over a fleet; one
                # unreadable folder must not cost the answer for the other
                # four hundred.
                Write-Verbose ("the drivers in '{0}' could not be counted: {1}" -f
                    $full, [string] $_.Exception.Message)
                $count = 0
            }
        }

        [void] $row.Add([pscustomobject] @{
                Make        = [string] $Make
                Model       = $name
                Group       = [string] $group
                FullPath    = [string] $full
                Present     = $present

                # AN EMPTY FOLDER IS NOT COVERAGE. It is the commonest way this
                # goes wrong and it looks like success in every tree that shows
                # it.
                DriverCount = [int] $count
                Covered     = ($present -and $count -gt 0)
            })
    }

    return [pscustomobject[]] @($row)
}
