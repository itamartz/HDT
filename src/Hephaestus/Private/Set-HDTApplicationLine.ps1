function Set-HDTApplicationLine {
    <#
        .SYNOPSIS
            Replaces one top-level key of an app.yaml, leaving every other line
            byte-identical.

        .DESCRIPTION
            THE SPLICE BEHIND Set-HDTApplication, and the reason that command
            does not parse-then-write. app.yaml is hand-edited from the day it is
            written - the sample catalog is half commentary - and a round trip
            through the YAML writer drops every comment in the file. So the
            document stays text, and only the lines belonging to the named key are
            rewritten.

            A KEY'S BLOCK IS THE KEY LINE PLUS EVERYTHING INDENTED UNDER IT. That
            is what makes 'detect' replaceable as a whole: swapping an msiProduct
            rule for a file rule has to take productCode with it, or the file
            would carry a key the new type does not allow and the validator would
            refuse the result. A blank line, a comment at column 0 and the next
            top-level key all end the block.

            AN ABSENT KEY IS APPENDED. There is no way to guess where an author
            would have put it, and inventing a position would move the lines
            around it - which is the one thing this function exists not to do.

            IT IS TEXT IN AND TEXT OUT. Nothing here reads or writes a file, and
            nothing here validates: Set-HDTApplication holds the spliced result
            to Assert-HDTApplicationDocument before any of it reaches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Key
            The top-level key to replace - 'name', 'install', 'detect' and so on.

        .PARAMETER Text
            The lines to write in its place. Empty removes the key and its block.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document, spliced.

        .EXAMPLE
            Set-HDTApplicationLine -Line $line -Key 'name' -Text @('name: 7-Zip 24.09 x64')

        .EXAMPLE
            Set-HDTApplicationLine -Line $line -Key 'detect' -Text @()

            Removes the detection rule, which is DESIGN 8's "install every time".
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Takes lines and returns lines. Nothing here reads or writes a file; Set-HDTApplication is what touches the share, and it declares SupportsShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pattern = '^{0}\s*:' -f [regex]::Escape($Key)

    $found = -1
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -match $pattern) {
            $found = $i
            break
        }
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    if ($found -lt 0) {
        foreach ($current in $Line) { [void] $result.Add($current) }
        foreach ($current in $Text) { [void] $result.Add($current) }

        return [string[]] @($result)
    }

    # The block ends at the first line that is not indented under the key. A
    # blank line ends it too: an author's paragraph break belongs to the file,
    # not to the key above it.
    $last = $found
    for ($i = $found + 1; $i -lt $Line.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($Line[$i])) { break }
        if ($Line[$i] -notmatch '^\s') { break }

        $last = $i
    }

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($i -eq $found) {
            foreach ($current in $Text) { [void] $result.Add($current) }
            continue
        }

        if ($i -gt $found -and $i -le $last) { continue }

        [void] $result.Add($Line[$i])
    }

    return [string[]] @($result)
}
