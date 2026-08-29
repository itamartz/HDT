function Get-HDTTimeZone {
    <#
        .SYNOPSIS
            The time zones this machine can name, id and display together.

        .DESCRIPTION
            WHAT THE WINDOWS PE WINDOW OFFERS AND WHAT DISM TAKES.
            dism /Set-TimeZone wants the ID - 'Israel Standard Time' - and
            nobody knows the ids;
            what an administrator is looking for is '(UTC+02:00) Jerusalem'. This
            returns both, so a list can show one and store the other.

            IT READS .NET, NOT A PROCESS. TimeZoneInfo::GetSystemTimeZones returns
            the same set from the same registry without starting a process, which
            matters because the console asks for this list every time the window
            opens.

            IT IS THIS MACHINE'S LIST, and that is worth knowing: Windows adds
            time zones, so a build host patched last year offers fewer than one
            patched last week. The document is not validated against it - a
            workspace edited on one machine and built on another would otherwise
            be refused for naming a zone the editor had never heard of.

        .PARAMETER Id
            One time zone, by id. Omitted, every one this machine knows.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] with Id, Display and
            BaseUtcOffset.

        .EXAMPLE
            Get-HDTTimeZone | Where-Object { $_.Display -like '*Jerusalem*' }

        .EXAMPLE
            Get-HDTTimeZone -Id 'UTC'

        .LINK
            Set-HDTBootImageTimeZone
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Id
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = New-Object -TypeName System.Collections.ArrayList

    foreach ($zone in @([System.TimeZoneInfo]::GetSystemTimeZones())) {
        if (-not [string]::IsNullOrWhiteSpace($Id) -and [string] $zone.Id -ne $Id) { continue }

        [void] $result.Add([pscustomobject] @{
                Id            = [string] $zone.Id

                # DisplayName IS ALREADY '(UTC+02:00) Jerusalem' on Windows, and
                # it is localised - which is right: the person choosing is
                # sitting at this machine.
                Display       = [string] $zone.DisplayName
                BaseUtcOffset = [string] $zone.BaseUtcOffset
            })
    }

    return [pscustomobject[]] @($result)
}
