function Get-HDTLogPath {
    <#
        .SYNOPSIS
            Returns DESIGN 4.4.1's _HDTLogPath for a phase.

        .DESCRIPTION
            _HDTLogPath is the single canonical log directory, set by the engine
            and available to every step, every condition and every user script.
            Nothing writes a log anywhere else (DESIGN 4.4.1).

            It follows the deployment rather than staying put:

              WinPE, before a disk exists          X:\HDT\Logs
              WinPE, after the volume is formatted <target>\HDT\Logs
              Full OS                              C:\HDT\Logs

            In the full OS the target volume IS the system volume, so a
            -TargetVolume is ignored there rather than silently pointing the logs
            at a drive letter that no longer means what it meant in WinPE.

            This is pure string logic. It reads nothing, asks no service and has
            no IFileSystem parameter, so the answer is the same on any machine -
            which is why -SystemDrive exists rather than $env:SystemDrive.

        .PARAMETER Phase
            WinPE or FullOS.

        .PARAMETER TargetVolume
            The formatted target volume, once one exists. Only used in WinPE. A
            trailing separator is accepted; 'W:' and 'W:\' name the same volume.

        .PARAMETER SystemDrive
            The full-OS system drive. Defaults to C:.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTLogPath -Phase WinPE

            X:\HDT\Logs - the RAM disk, before any volume is formatted.

        .EXAMPLE
            Get-HDTLogPath -Phase WinPE -TargetVolume 'W:'

            W:\HDT\Logs - where the logs move to so the WinPE to OS transition
            keeps its history.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Phase,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $TargetVolume,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $SystemDrive = 'C:'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $root = $SystemDrive

    if ($Phase -eq 'WinPE') {
        # X: is the WinPE RAM disk. It is where the logs live until a real volume
        # exists to move them to.
        $root = 'X:'

        if (-not [string]::IsNullOrWhiteSpace($TargetVolume)) {
            $root = $TargetVolume
        }
    }

    $root = $root.TrimEnd('\', '/')

    return ('{0}\HDT\Logs' -f $root)
}
