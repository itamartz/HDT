function New-HDTBadgeFile {
    <#
        .SYNOPSIS
            Writes a shields.io endpoint document for one badge.

        .DESCRIPTION
            A BADGE IS A FOUR-KEY JSON FILE, NOT AN IMAGE. shields.io renders

                https://img.shields.io/endpoint?url=<public url of this file>

            from {schemaVersion, label, message, color}. CI writes these, pushes
            them to the orphan `badges` branch, and the README points at their
            raw URL - so the numbers on the front page come from the run that
            produced them, no coverage service is signed up to, and no token is
            stored anywhere.

            NO BYTE ORDER MARK, AND THAT IS THE WHOLE REASON THIS IS A FUNCTION.
            Under Windows PowerShell 5.1 every convenient way of writing a file -
            Out-File, Set-Content, Add-Content, `>` - emits UTF-8 WITH a BOM, and
            a BOM in front of `{` is not valid JSON to a strict parser. The badge
            renders as "invalid" while the file looks perfect in every editor.
            WriteAllText with UTF8Encoding($false) is the only safe spelling, and
            it is written down once here rather than remembered at each call.

        .PARAMETER Path
            Where to write the document. The directory is created if it is
            missing - out/ is removed by the clean task, so the first badge of
            every full build writes into a directory that does not exist yet.

        .PARAMETER Label
            The grey left-hand half: 'tests', 'coverage'.

        .PARAMETER Message
            The coloured right-hand half: '7950 passed', '83%'.

        .PARAMETER Color
            A shields.io colour name or hex value. Get-HDTBadgeColor turns a
            percentage into one.

        .OUTPUTS
            None.

        .EXAMPLE
            New-HDTBadgeFile -Path './out/badges/coverage.json' -Label 'coverage' -Message '83%' -Color 'green'

        .LINK
            Get-HDTBadgeColor
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Label,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Color
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    # [ordered] so a diff of the badges branch reads the same way every run.
    $document = [ordered] @{
        schemaVersion = 1
        label         = $Label
        message       = $Message
        color         = $Color
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write badge')) {
        [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document), (New-Object System.Text.UTF8Encoding($false)))
    }
}
