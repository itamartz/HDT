function New-HDTConsoleShareReader {
    <#
        .SYNOPSIS
            Builds the script block the console runs, once its window is up, to
            read the shares and turn them into the tree's root rows.

        .DESCRIPTION
            THIS EXISTS BECAUSE OF TWO SCOPING TRAPS, and it exists as its own
            function because that is the only way to avoid both at once.

            A PLAIN SCRIPT BLOCK READS THE CALLER'S VARIABLES. Handed to the
            window host and invoked from inside its ContentRendered handler, an
            unbound block resolves names against the scope that INVOKED it - so
            `$share.Add(...)` found the host's own `$share`, which is the banner
            TextBlock, and failed with "does not contain a method named 'Add'".
            A window that opened and never filled, saying nothing.

            AND GetNewClosure COPIES EVERY VARIABLE IN SCOPE, attributes
            included, re-validating each as it goes - so calling it inside
            Show-HDTConsole throws on whichever parameter belongs to the OTHER
            parameter set and is sitting there null under a [ValidateNotNull()].
            The message names an attribute rather than a parameter set.

            SO THE CLOSURE IS MADE HERE, where the only variables in scope are
            this function's own parameters and they carry no attributes to
            re-validate. The block that comes back is bound to those, and to
            nothing a caller happens to have named the same.

        .PARAMETER Path
            The shares to read, in the order they should appear.

        .PARAMETER FileSystem
            An IFileSystem, passed through to Get-HDTConsoleWorkspace.

        .PARAMETER Share
            The list the shares are added to. The caller keeps it: what the
            console returns includes the shares it showed.

        .PARAMETER Carried
            A dictionary the block writes Node into, for the same reason - the
            row count is only known once the read has happened.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.ScriptBlock - returns the depth-0 rows.

        .EXAMPLE
            $fill = New-HDTConsoleShareReader -Path $Path -FileSystem $FileSystem -Share $share -Carried $carried
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a script block; nothing is read or written until the window invokes it.')]
    # EVERY PARAMETER IS USED INSIDE THE CLOSURE, which is the whole point of
    # the function - and which PSReviewUnusedParameter does not follow.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Used inside a closure, which PSReviewUnusedParameter does not follow.')]
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]] $Path,

        [Parameter(Position = 1)]
        [object] $FileSystem = $null,

        [Parameter(Mandatory = $true, Position = 2)]
        [object] $Share,

        [Parameter(Mandatory = $true, Position = 3)]
        [object] $Carried
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE COMMAND ITSELF, NOT ITS NAME. The block below is invoked by the window
    # host - and, in the tests, by a fake defined outside this module - and a
    # name resolved at that moment is resolved against THEIR session state,
    # where a private function of this module does not exist. The failure showed
    # up as "the term 'New-HDTConsoleShareFailure' is not recognized", on the
    # one path that is only taken when a share will not open.
    #
    # A CommandInfo captured HERE is bound to this module and works wherever it
    # is called from. The two public commands need no such treatment, which is
    # why only this one gets it.
    $failureRow = Get-Command -Name 'New-HDTConsoleShareFailure' -Module 'Hephaestus' -ErrorAction SilentlyContinue

    if ($null -eq $failureRow) {
        $failureRow = Get-Command -Name 'New-HDTConsoleShareFailure' -CommandType Function
    }

    return {
        foreach ($current in @($Path)) {
            try {
                # A SHARE THAT WILL NOT OPEN BECOMES A ROW, not an exception:
                # three good shares must not disappear because of a fourth.
                if ($null -eq $FileSystem) {
                    [void] $Share.Add((Get-HDTConsoleWorkspace -Path $current))
                } else {
                    [void] $Share.Add((Get-HDTConsoleWorkspace -Path $current -FileSystem $FileSystem))
                }
            } catch {
                [void] $Share.Add((& $failureRow -Path $current -Message ([string] $_.Exception.Message)))
            }
        }

        $Carried['Node'] = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($Share)))

        return [object[]] @($Carried['Node'] | Where-Object { $_.Depth -eq 0 })
    }.GetNewClosure()
}
