function Update-HDTDriverFolderReference {
    <#
        .SYNOPSIS
            Rewrites a driver folder path inside a control document.

        .DESCRIPTION
            A DRIVER FOLDER IS NAMED IN MORE PLACES THAN THE FILE SYSTEM, and a
            rename that moves only the directory breaks all of them silently:

              selection-profiles.yaml   a profile pointing at the old name
                                        injects NOTHING into a boot image and
                                        says nothing about it
              driver-state.yaml         the drivers somebody turned OFF, by
                                        path - renamed around, a disabled driver
                                        quietly comes back

            Neither fails loudly. They fail as a boot image with no NIC driver,
            found on a bench, weeks later.

            IT SPLICES, IT DOES NOT RE-SERIALISE. These documents are YAML so an
            administrator can comment them, and comments do not survive
            ConvertFrom-Yaml followed by ConvertTo-Yaml - they are gone at parse
            time. So this rewrites the LINES that carry the old path and leaves
            every other byte alone, which is the rule the rest of this module
            follows for the same reason.

            IT MATCHES A PATH SEGMENT, NOT A SUBSTRING. Renaming 'Dell' must not
            touch 'Dell Precision': the old value matches only when the rest of
            the line is the end of the path or a separator. Getting that wrong
            corrupts a document while looking like it worked.

            A DOCUMENT THAT IS NOT THERE IS NOT AN ERROR. A share where nobody
            has written a selection profile, or disabled a driver, simply has
            neither file - which is the ordinary case, not a broken one.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Kind
            The workspace folder the document lives in.

        .PARAMETER Document
            The file name inside it.

        .PARAMETER Old
            The path as it is written now.

        .PARAMETER New
            What it becomes.

        .PARAMETER FileSystem
            The IFileSystem to read and write through.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean - whether anything was rewritten.

        .EXAMPLE
            Update-HDTDriverFolderReference -Root 'C:\S' -Kind Control -Document 'selection-profiles.yaml' -Old 'Drivers\WinPE\Dell' -New 'Drivers\WinPE\Dell WinPE' -FileSystem $fs
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller owns the ShouldProcess for the rename this is part of.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Control')]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Document,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Old,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $New,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $path = Get-HDTWorkspacePath -Root $Root -Kind $Kind -ChildPath $Document

    if (-not $FileSystem.TestPath($path)) { return $false }

    $text = [string] $FileSystem.ReadAllText($path)
    if ([string]::IsNullOrEmpty($text)) { return $false }

    # THE LINE ENDINGS ARE THE DOCUMENT'S, not this function's. Rewriting a CRLF
    # file with LF makes every line of a git diff change and hides the one line
    # that actually did.
    $newLine = "`n"
    if ($text -match "`r`n") { $newLine = "`r`n" }

    $line = @($text -split "`r?`n")
    $changed = $false

    # THE LINE'S VALUE, NOT A SUBSTRING OF THE LINE. The first attempt matched
    # the old path followed by "end, separator or WHITESPACE" - and a space is a
    # legitimate part of a folder name, so renaming 'Dell' also rewrote
    # 'Dell Precision' and corrupted the profile beside it. There is no
    # character class that separates the two, because the difference is not in
    # the characters: it is whether the old path is the WHOLE value or a parent
    # of it.
    #
    # So the value is taken off the line - a list item or a key - and compared
    # as a path. Anything else on the line, including the indentation and any
    # trailing comment, is put back untouched.
    for ($i = 0; $i -lt $line.Count; $i++) {
        $current = [string] $line[$i]

        # A COMMENT IS NOT A REFERENCE. Rewriting a path inside somebody's note
        # changes prose that explained the old layout into prose describing a
        # layout nobody ever had.
        if ($current.TrimStart().StartsWith('#')) { continue }

        # '  - Drivers\WinPE\Dell'  or  '  drivers: Drivers\WinPE\Dell'
        if ($current -notmatch '^(\s*(?:-\s*|[A-Za-z_][\w.-]*:\s*))(.*)$') { continue }

        $head = [string] $Matches[1]
        $value = [string] $Matches[2]

        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        # A trailing comment is not part of the value, and neither are the
        # quotes an administrator may have put round a path with a space in it.
        $tail = ''
        $body = $value.TrimEnd()

        if ($body.Length -lt $value.Length) { $tail = $value.Substring($body.Length) }

        $quote = ''
        if ($body.Length -ge 2 -and ($body[0] -eq "'" -or $body[0] -eq '"') -and $body[-1] -eq $body[0]) {
            $quote = [string] $body[0]
            $body = $body.Substring(1, $body.Length - 2)
        }

        # THE WHOLE VALUE, OR A PARENT OF IT. 'WinPE\Dell' renames
        # 'WinPE\Dell' and 'WinPE\Dell\net.inf', and leaves 'WinPE\Dell
        # Precision' alone - which is the distinction the character class could
        # not draw.
        $isExact = $body.Equals($Old, [System.StringComparison]::OrdinalIgnoreCase)
        $isChild = $body.StartsWith($Old.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)

        if (-not $isExact -and -not $isChild) { continue }

        $rewritten = $New
        if ($isChild) { $rewritten = $New.TrimEnd('\') + $body.Substring($Old.TrimEnd('\').Length) }

        $line[$i] = '{0}{1}{2}{1}{3}' -f $head, $quote, $rewritten, $tail
        $changed = $true
    }

    if (-not $changed) { return $false }

    $FileSystem.WriteAllText($path, ($line -join $newLine))

    return $true
}
