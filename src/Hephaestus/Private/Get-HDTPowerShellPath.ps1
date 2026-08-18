function Get-HDTPowerShellPath {
    <#
        .SYNOPSIS
            Returns the PowerShell console host that a relaunch may start.

        .DESCRIPTION
            A HOST IS NOT ALWAYS A CONSOLE, and Start-HDTConsole assumed it was.
            It relaunched GetCurrentProcess().MainModule.FileName, which is right
            in powershell.exe and wrong everywhere else. In the ISE that resolves
            to powershell_ise.exe, and the ISE takes exactly three parameters -
            -File, -Mta and -NoProfile. It has never had -STA. So

                Start-HDTConsole -Detach C:\HDTLab\Share

            from the ISE started a second ISE with a switch the ISE does not
            have, and reported an error about STA from the command whose whole
            job is getting the apartment right.

            The same hole is open in any WPF or WinForms application hosting
            PowerShell, and in anything embedding
            System.Management.Automation: none of them can be handed -File and
            told to run a script.

            $PSHOME IS THE ANSWER because it is where the console host that
            matches THIS engine lives - the 5.1 directory under the ISE, the
            pwsh directory under pwsh. Picking powershell.exe off PATH would
            silently move a pwsh 7 session onto 5.1.

        .PARAMETER ProcessPath
            The executable of the process asking - normally
            [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName.

        .PARAMETER InstallPath
            Where to look when ProcessPath is not a console host. Normally
            $PSHOME.

        .OUTPUTS
            System.String - the full path of a console host.

        .EXAMPLE
            Get-HDTPowerShellPath -ProcessPath 'C:\...\powershell_ise.exe' -InstallPath $PSHOME

            C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe

        .LINK
            Start-HDTConsole
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ProcessPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $InstallPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $leaf = [System.IO.Path]::GetFileName($ProcessPath)

    if (@('powershell.exe', 'pwsh.exe') -contains $leaf) {
        return $ProcessPath
    }

    foreach ($candidate in @('pwsh.exe', 'powershell.exe')) {
        $path = Join-Path -Path $InstallPath -ChildPath $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    # IT NAMES THE HOST AND THE DIRECTORY. "STA" as an error sends somebody to
    # read about apartment states; the cause is that the thing they are typing
    # into cannot run a script file, and only this message can say so.
    throw ("'{0}' is not a PowerShell console host, and neither pwsh.exe nor powershell.exe is in '{1}'. Open the console from powershell.exe or pwsh.exe, or run Show-HDTConsole here instead - this host is already STA." -f $leaf, $InstallPath)
}
