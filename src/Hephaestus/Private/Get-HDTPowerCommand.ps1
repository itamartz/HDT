function Get-HDTPowerCommand {
    <#
        .SYNOPSIS
            Decides which executable ends the machine, and with what arguments.

        .DESCRIPTION
            ROADMAP M2 deferred one question to phase 05: "does WinPE need
            wpeutil reboot rather than shutdown.exe". A read-only mount of the
            boot image Update-HDTBootImage builds answers it, and the answer is
            not a preference:

                Windows\System32\shutdown.exe   ABSENT
                Windows\System32\wpeutil.exe    PRESENT, 32768 bytes

            shutdown.exe is not in WinPE. So a Restart step running in WinPE
            through the old adapter called a command that does not exist. It was
            never noticed because DEMO-M3 and DEMO-M4 both deliberately have no
            Restart step and the IPowerService contract's real row is skipped -
            a contract test may not reboot the machine running it.

            tests/integration/WinPeContent.Integration.Tests.ps1 holds that fact
            against a real mounted image, so the day Microsoft changes it,
            somebody is told.

            THIS FUNCTION IS THE ONLY PLACE THAT BRANCHES ON IT. The adapter
            New-HDTPowerService is a shell-out with no `if` in it at all, which
            is what earns it CLAUDE.md rule 1's exemption from TDD; every
            decision it would otherwise have made is here, pure, and asserted as
            an exact argument array.

              FullOS   shutdown.exe /r|/s /t <delay> /f     the command delays
              WinPE    wpeutil.exe  reboot|shutdown         the caller sleeps

            The delay is the one real difference. `wpeutil reboot` and
            `wpeutil shutdown` take no arguments, so there is nowhere to put a
            delay - and dropping it silently would make a sequence's
            `delaySecond:` a lie in WinPE. SleepSecond carries it instead, and
            the adapter sleeps that long before invoking. Saying so in the
            returned object is deliberate: the adapter must not be the thing
            that knows.

        .PARAMETER Environment
            WinPE or FullOS. There is no default and no detection: the two
            payloads that build a power service already know which world they
            are in - Start-HDTDeployment.ps1 is the WinPE entry point and
            Start-HDTResume.ps1 runs in the deployed OS.

        .PARAMETER Operation
            Restart or Stop.

        .PARAMETER DelaySecond
            How long to wait before the machine goes. Refused if negative:
            shutdown.exe /t -5 is an error, and a negative sleep is nonsense.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Environment,
            Operation, Command, Argument (string[]), SleepSecond and Reason.

        .EXAMPLE
            Get-HDTPowerCommand -Environment WinPE -Operation Restart -DelaySecond 0

            Command wpeutil.exe, Argument @('reboot').

        .EXAMPLE
            Get-HDTPowerCommand -Environment FullOS -Operation Stop -DelaySecond 30

            Command shutdown.exe, Argument @('/s', '/t', '30', '/f').
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Environment,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Restart', 'Stop')]
        [string] $Operation,

        [Parameter()]
        [int] $DelaySecond = 0
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($DelaySecond -lt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                    -Message ("A power delay cannot be negative, and {0} was asked for. Use 0 to go immediately." -f $DelaySecond) `
                    -TargetObject $DelaySecond))
    }

    # The verb each world spells the same operation with.
    $winPeVerb = @{ Restart = 'reboot'; Stop = 'shutdown' }
    $fullOsSwitch = @{ Restart = '/r'; Stop = '/s' }

    if ($Environment -eq 'WinPE') {
        # Bare, not "$env:SystemRoot\System32\wpeutil.exe": this function reads
        # no environment, and System32 is on the PATH in WinPE - SPIKES S11.3
        # records startnet.cmd resolving `wpeinit` and `powershell.exe` exactly
        # that way inside an image this repository built.
        return [pscustomobject] @{
            Environment = $Environment
            Operation   = $Operation
            Command     = 'wpeutil.exe'
            Argument    = [string[]] @($winPeVerb[$Operation])
            SleepSecond = $DelaySecond
            Reason      = ('WinPE has no shutdown.exe; wpeutil {0} is the only way to end a machine there, and it takes no delay, so the {1}s delay is a sleep.' -f $winPeVerb[$Operation], $DelaySecond)
        }
    }

    return [pscustomobject] @{
        Environment = $Environment
        Operation   = $Operation
        Command     = 'shutdown.exe'
        Argument    = [string[]] @($fullOsSwitch[$Operation], '/t', ([string] $DelaySecond), '/f')
        SleepSecond = 0
        Reason      = ('The deployed OS has shutdown.exe, which owns the {0}s delay itself, so nothing sleeps.' -f $DelaySecond)
    }
}
