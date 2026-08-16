function New-HDTConsoleShareFailure {
    <#
        .SYNOPSIS
            Builds the console's model of a deployment share that would not open.

        .DESCRIPTION
            A SHARE THAT CANNOT BE OPENED IS STILL ONE OF THE SHARES. With
            several open, a bad path - a server that is down, a share the
            signed-in user cannot reach, a folder that is not a workspace - must
            not take the other shares off the screen with it. So the failure gets
            the same shape a share has, with Status 'Error' and the reason on it,
            and Get-HDTConsoleShareNode renders it as one row that says which
            path failed and why.

            THE SHAPE IS THE SAME ON PURPOSE. Every consumer walks Status,
            TaskSequence, OperatingSystem and BootImage without asking first
            whether this share is real, so nothing downstream needs a special
            case for the unhappy path - which is where special cases go wrong.

        .PARAMETER Path
            The path that would not open.

        .PARAMETER Message
            Why it would not.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the same shape
            Get-HDTConsoleWorkspace returns, with Status 'Error'.

        .EXAMPLE
            New-HDTConsoleShareFailure -Path '\\down-server\HDTShare' -Message $_.Exception.Message
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a projection object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Message
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [pscustomobject] @{
        Root            = $Path
        WorkspacePath   = [System.IO.Path]::Combine($Path, 'workspace.yaml')
        SchemaVersion   = 0
        Id              = ''
        Name            = ''
        DeployRoot      = ''
        LogLevel        = ''
        CredentialUser  = ''
        Status          = 'Error'
        Error           = $Message
        TaskSequence    = [pscustomobject[]] @()   # each would carry Finding, ErrorCount and WarningCount
        OperatingSystem = [pscustomobject[]] @()

        # THE SAME SHAPE, EMPTY. A share that could not be opened has nothing
        # running on it as far as anybody can tell, and a caller that had to
        # check which kind of share it was holding before reading Monitor is a
        # caller that will one day forget.
        Monitor         = [pscustomobject] @{
            Status          = 'Ok'
            Message         = ''
            Run             = [pscustomobject[]] @()
            Summary         = 'There is no deployment running on this share.'
            Caption         = 'Monitoring'
            LiveCount       = 0
            StalledCount    = 0
            FinishedCount   = 0
            UnreadableCount = 0
            ActivePath      = [System.IO.Path]::Combine($Path, 'Logs\_active')
        }
        Driver          = [pscustomobject] @{
            Folder  = [System.IO.Path]::Combine($Path, 'Drivers')
            Present = $false
        }
        BootImage       = [pscustomobject] @{
            Name             = ''
            Architecture     = ''
            Language         = ''
            ManifestPath     = ''
            Status           = 'Missing'
            Error            = 'the share could not be opened, so its boot image was never looked for.'
            BuildId          = ''
            BuiltUtc         = $null
            BuiltOn          = ''
            EngineVersion    = ''
            WimPath          = ''
            WimSha256        = ''
            WimSizeBytes     = [long] 0
            IsoPath          = ''
            IsoSha256        = ''
            IsoSizeBytes     = [long] 0
            IsoBootWimSha256 = ''
            HashMatch        = $false
        }
    }
}
