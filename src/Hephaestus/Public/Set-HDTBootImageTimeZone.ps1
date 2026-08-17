function Set-HDTBootImageTimeZone {
    <#
        .SYNOPSIS
            Names the time zone WinPE runs in.

        .DESCRIPTION
            WinPE'S ANSWER FILE CANNOT SET THIS, and that is why the command
            exists. The windowsPE configuration pass carries
            Microsoft-Windows-International-Core-WinPE, which is InputLocale,
            SystemLocale, UILanguage and UserLocale - there is no TimeZone in it.
            Microsoft's TimeZone setting belongs to Microsoft-Windows-Shell-Setup
            and is valid only in specialize, oobeSystem and auditSystem, which
            are passes of the DEPLOYED OS. So a booted WinPE runs on whatever the
            hardware clock says, which is UTC in practice.

            tzutil IS THE SUPPORTED WAY TO MOVE IT, and startnet.cmd is where a
            command that has to run on every boot belongs. Named here,
            Get-HDTStartnetScript writes `tzutil /s "<id>"` after wpeinit.

            IT IS A WINDOWS TIME ZONE ID, not an offset: 'Israel Standard Time',
            not '+02:00'. Run Get-HDTTimeZone, or tzutil /l, for the list. The
            id is NOT validated here - this document is edited and validated on
            machines that are not the one deploying, and a time zone Windows
            added last month would be refused by an engine that shipped before
            it.

            WHAT IT DOES NOT DO IS SET THE DEPLOYED MACHINE'S TIME ZONE. That is
            HDTTimeZone, which the task sequence's unattend.xml carries into the
            specialize pass. Start-HDTDeployment seeds it from this value so one
            choice covers both, and a rule may override it per machine.

            IT IS SHAPED LIKE Set-HDTBootImageUnattend - one value, -Clear to
            take it away, the key removed rather than written empty.

        .PARAMETER Line
            The workspace.yaml lines to edit.

        .PARAMETER Name
            The Windows time zone id.

        .PARAMETER Clear
            Leave WinPE on the hardware clock, which is what it does today.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the workspace.yaml lines, spliced.

        .EXAMPLE
            $line = Set-HDTBootImageTimeZone -Line $line -Name 'Israel Standard Time'

        .EXAMPLE
            Get-HDTTimeZone | Where-Object { $_.Display -like '*Jerusalem*' }

            Finding the id to pass.

        .LINK
            Get-HDTTimeZone
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Set')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Set')]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
        [switch] $Clear
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    [void] (ConvertFrom-HDTWorkspaceLine -Line $Line)

    if ($Clear) {
        if (-not $PSCmdlet.ShouldProcess('bootImage: timeZone', 'Leave WinPE on the hardware clock')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'timeZone') `
                -Text ([string[]] @()))
    } else {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name `
                        -Message 'a time zone is a Windows time zone id, for example ''Israel Standard Time''. Pass -Clear to leave WinPE on the hardware clock; run Get-HDTTimeZone for the ids.'))
        }

        if (-not $PSCmdlet.ShouldProcess($Name, 'Run WinPE in this time zone')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'timeZone') `
                -Text ([string[]] @('timeZone: {0}' -f (ConvertTo-HDTRuleScalarText -Value $Name))))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
