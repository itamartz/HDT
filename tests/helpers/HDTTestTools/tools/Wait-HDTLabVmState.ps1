function Wait-HDTLabVmState {
    <#
        .SYNOPSIS
            Waits for an HDT test VM to reach a power state, or to report an
            integration-services heartbeat.

        .DESCRIPTION
            TWO WAYS TO KNOW A DEPLOYMENT ENDED, and the second is the more
            interesting one.

            -State waits for Off, Running or any other Hyper-V state.
            Start-HDTLabDeployment shuts the machine down when the sequence
            finishes, whatever the outcome, so 'Off' is how the harness knows
            the run ended rather than by guessing at a duration.

            -Heartbeat waits for the integration-services heartbeat to report
            Ok. THIS IS THE EXIT CRITERION'S ASSERTION: WinPE carries no
            integration services and never reports a heartbeat at all, and full
            Windows does. So a heartbeat is a deterministic "the machine booted
            into Windows" signal - far better than reading pixels off a
            screenshot, which is diagnosis rather than assertion.

            -SettleMinute holds the heartbeat for a window before returning.
            ComputerName is applied in the specialize pass and the heartbeat can
            appear while Setup is still working, so a VM stopped at the first Ok
            may not have committed it yet.

            Every Hyper-V command is module-qualified (SPIKES S8).

        .PARAMETER Name
            The VM. Must be HDT-*.

        .PARAMETER State
            The power state to wait for.

        .PARAMETER Heartbeat
            Wait for an Ok* heartbeat instead of a power state.

        .PARAMETER TimeoutMinute
            How long to wait before returning $false.

        .PARAMETER SettleMinute
            With -Heartbeat, how long the heartbeat must stay Ok* before this
            returns $true.

        .PARAMETER PollSecond
            Interval between checks.

        .OUTPUTS
            System.Boolean - whether the condition was reached in time.

        .EXAMPLE
            Wait-HDTLabVmState -Name 'HDT-M3-Deploy' -State Off -TimeoutMinute 45

        .EXAMPLE
            Wait-HDTLabVmState -Name 'HDT-M3-Deploy' -Heartbeat -TimeoutMinute 20 -SettleMinute 3
    #>
    [CmdletBinding(DefaultParameterSetName = 'State')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Mandatory = $true, ParameterSetName = 'State')]
        [ValidateNotNullOrEmpty()]
        [string] $State,

        [Parameter(Mandatory = $true, ParameterSetName = 'Heartbeat')]
        [switch] $Heartbeat,

        [Parameter()]
        [ValidateRange(1, 720)]
        [int] $TimeoutMinute = 30,

        [Parameter(ParameterSetName = 'Heartbeat')]
        [ValidateRange(0, 60)]
        [int] $SettleMinute = 0,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int] $PollSecond = 10
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Assert-HDTLabVmName -Name $Name

    $deadline = (Get-Date).AddMinutes($TimeoutMinute)
    $settleUntil = $null

    while ((Get-Date) -lt $deadline) {
        $vm = @(Hyper-V\Get-VM -Name $Name -ErrorAction SilentlyContinue)

        if ($vm.Count -eq 1) {
            if ($Heartbeat) {
                $status = ''
                try {
                    $service = @(Hyper-V\Get-VMIntegrationService -VMName $Name -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -eq 'Heartbeat' })

                    if ($service.Count -eq 1 -and $null -ne $service[0].PrimaryStatusDescription) {
                        $status = [string] $service[0].PrimaryStatusDescription
                    }
                } catch {
                    $status = ''
                }

                if ($status -like 'Ok*') {
                    if ($SettleMinute -le 0) {
                        return $true
                    }

                    if ($null -eq $settleUntil) {
                        $settleUntil = (Get-Date).AddMinutes($SettleMinute)
                        Write-Verbose ("'{0}' reported a heartbeat; settling until {1}" -f $Name, $settleUntil)
                    } elseif ((Get-Date) -ge $settleUntil) {
                        return $true
                    }
                } else {
                    # A heartbeat that came and went is not a settled machine.
                    $settleUntil = $null
                }
            } elseif ([string] $vm[0].State -eq $State) {
                return $true
            }
        }

        Start-Sleep -Seconds $PollSecond
    }

    return $false
}
