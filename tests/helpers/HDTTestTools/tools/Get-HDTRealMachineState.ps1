function Get-HDTRealMachineState {
    <#
        .SYNOPSIS
            Reads what this machine currently has at each of the given paths,
            as one comparable line per path.

        .DESCRIPTION
            THE TOOL A "IT TOUCHED NOTHING REAL" ASSERTION NEEDS. The fake-driven
            suites prove that the engine wrote only to its injected services, and
            the last mile of that proof has to look at the real machine: a step
            that reached past the service and called Set-Content itself would
            leave the journal spotless and the disk changed.

            The suites used to make that last mile by asserting the path is
            ABSENT - Test-Path 'C:\HDT\Logs\HDT.jsonl' | Should -BeFalse. That is
            a claim about the machine rather than about the run, and it stopped
            being true when the gate moved onto GHRUNNER01: HDT DEPLOYED THAT
            MACHINE, so C:\HDT\Logs there holds the log of the deployment that
            built it, and a suite that is green on a laptop went red on the
            runner for being a runner (the same defect fb3ef00 fixed in the
            lab-safety guards).

            So: take a reading before the run, take the same reading after, and
            assert they are IDENTICAL. That is true on a bare machine, true on a
            machine HDT deployed a year ago, and false the moment a run creates,
            grows or rewrites one of these paths. It assumes nothing about what
            the machine ought to contain, which is the whole point.

            IT RETURNS NO REGISTRY VALUE DATA, ONLY VALUE NAMES. The keys these
            suites watch are Winlogon and RunOnce, where DefaultPassword is the
            one value whose contents must never reach a failure message
            (tests/contract/SecretRedaction.Contract.Tests.ps1). A name set is
            enough to prove a run added nothing.

            AN UNMOUNTED DRIVE READS AS 'absent' RATHER THAN THROWING. X:\ is a
            WinPE RAM disk and Z:\ is a deployment share letter; both are paths
            these suites must be able to watch from a laptop where neither is
            mounted.

        .PARAMETER Path
            One or more filesystem or registry paths to read. Registry paths are
            recognised from the provider of the item, not from their spelling.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path and State.
            State is 'absent', 'file, N bytes, modified <round-trip UTC>',
            'directory, modified <round-trip UTC>', or 'registry key, values:
            <names>'.

        .EXAMPLE
            $before = @(Get-HDTRealMachineState -Path 'C:\HDT\Logs\HDT.jsonl')

            Takes the reading before the fake-driven run starts.

        .EXAMPLE
            @(Get-HDTRealMachineState -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon')[0].State

            'registry key, values: AutoRestartShell, DefaultUserName, Shell, Userinit'
            - the names, never the data.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path
    )

    begin {
        $reading = New-Object -TypeName System.Collections.ArrayList
    }

    process {
        foreach ($item in $Path) {
            $state = 'absent'

            # -ErrorAction SilentlyContinue, because an unmounted drive is a
            # non-terminating error here and 'absent' is the honest answer for
            # it. The try/catch below covers the rest: a path can disappear
            # between the test and the read, and a key can refuse a read.
            $exists = $false
            try {
                $exists = [bool] (Test-Path -LiteralPath $item -ErrorAction SilentlyContinue)
            } catch {
                $exists = $false
            }

            if ($exists) {
                try {
                    $entry = Get-Item -LiteralPath $item -Force -ErrorAction Stop

                    if ($entry.PSProvider.Name -eq 'Registry') {
                        # GetValueNames(), not the ETS Property list: it is the
                        # RegistryKey's own method and it returns the names
                        # WITHOUT the data, which is the property this tool must
                        # not lose.
                        $name = @($entry.GetValueNames() | Sort-Object)

                        if ($name.Count -eq 0) {
                            $state = 'registry key, no value'
                        } else {
                            $state = 'registry key, values: {0}' -f ($name -join ', ')
                        }
                    } elseif ($entry.PSIsContainer) {
                        $state = 'directory, modified {0}' -f $entry.LastWriteTimeUtc.ToString('o')
                    } else {
                        $state = 'file, {0} bytes, modified {1}' -f $entry.Length, $entry.LastWriteTimeUtc.ToString('o')
                    }
                } catch {
                    $state = 'absent'
                }
            }

            [void] $reading.Add([pscustomobject] @{
                    Path  = $item
                    State = $state
                })
        }
    }

    end {
        # No unary comma: the caller rewraps with @(), and a wrapped empty list
        # would arrive as one element that is an array.
        return @($reading)
    }
}
