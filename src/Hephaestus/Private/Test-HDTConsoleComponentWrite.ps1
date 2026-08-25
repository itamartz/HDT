function Test-HDTConsoleComponentWrite {
    <#
        .SYNOPSIS
            Whether ticking or unticking an optional component should touch the
            boot image document.

        .DESCRIPTION
            ALREADY THERE MEANS WPF RAISED THIS, NOT A PERSON. The Features tab's
            checkboxes are built the first time that tab is clicked, and every
            one of them raises Checked as it takes its bound value.
            Add-HDTBootImageComponent refuses a duplicate outright, so without
            this guard the window DIED on the first click of the tab - not on an
            edge case, on the ordinary path.

            A LOCKED ROW IS NOT THE DOCUMENT'S TO NAME, and this is the subtler
            half. The six components the engine applies to every image are shown
            ticked and cannot be unticked, and the document does not list them -
            so they PASS the already-there test and would be written into
            optionalComponents by the very click that first draws them. That is
            how a share which named nothing ended up naming ten, freezing
            today's defaults into a file that is meant to inherit tomorrow's.

            The two guards therefore cannot be collapsed: one is about a
            component the document has, the other about a component the document
            must never gain.

            UNTICKING IS THE MIRROR AND NEEDS NO LOCK TEST. Not-there means there
            is nothing to remove, and a locked component is never in the document
            - so the same check covers both, and adding a lock test to the
            removal path would be a guard that can only ever be redundant.

            THE COMPARISON IS CASE-INSENSITIVE, because -contains is, and the
            document's component names are not case sensitive.

        .PARAMETER Row
            The component row behind the checkbox: Name, and CanChange for
            whether the engine applies it regardless.

        .PARAMETER Declared
            The component names the document currently lists.

        .PARAMETER Ticking
            The box was ticked rather than unticked.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean - whether to write the document.

        .EXAMPLE
            Test-HDTConsoleComponentWrite -Row $row -Declared $book.View.DeclaredName -Ticking

        .EXAMPLE
            if (Test-HDTConsoleComponentWrite -Row $row -Declared $book.View.DeclaredName) {
                $book.Line = @(Remove-HDTBootImageComponent -Line $book.Line -Name $row.Name)
            }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Row,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Declared,

        [Parameter()]
        [switch] $Ticking
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Row) { return $false }

    $named = @()
    if ($null -ne $Declared) { $named = @($Declared) }

    $name = [string] $Row.Name
    $isDeclared = ($named -contains $name)

    if (-not $Ticking) {
        # NOT THERE MEANS THERE IS NOTHING TO REMOVE. See the mirror note above.
        return $isDeclared
    }

    # ALREADY THERE MEANS WPF RAISED THIS.
    if ($isDeclared) { return $false }

    # A LOCKED ROW IS NOT THE DOCUMENT'S TO NAME - and it got here precisely
    # because the document is silent about it.
    if (-not [bool] $Row.CanChange) { return $false }

    return $true
}
