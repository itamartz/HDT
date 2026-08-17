function Get-HDTStringTable {
    <#
        .SYNOPSIS
            The text a window shows, read from a file rather than from its
            markup.

        .DESCRIPTION
            EVERY LABEL, HINT, BUTTON AND TAB HEADER USED TO BE A LITERAL IN
            XAML. Changing a sentence meant editing a window; translating one
            meant forking it; and a string that appeared in two windows was two
            strings that drifted apart. This is the table they move into: one
            .psd1 per culture in the module's Strings folder, keyed by the
            control it belongs to.

            THE KEY IS Control.Property, which is what Set-HDTWindowText splits
            on: 'HDTBootImageNameBox.ToolTip' names a control and the property
            to write. Nothing in the key says which window - a control name is
            already unique across this module, and a key carrying its window as
            well would have to be renamed the day a control moves.

            IT FALLS BACK RATHER THAN FAILS, TWICE. A culture nobody has
            translated loads en-us; a KEY nobody has translated takes the en-us
            string, so a half-finished translation is a console with some
            English in it rather than a console with holes in it. That is what
            makes it safe to ship a language before it is finished.

            en-us IS THE FLOOR AND ITS ABSENCE IS AN ERROR. Without it a missing
            key has nothing to fall back to, and the window would show blanks
            nobody could explain from a screenshot.

            IT IS A .psd1 AND NOT JSON OR YAML. Import-PowerShellDataFile parses
            it without executing it, it is the format PowerShell itself uses for
            module manifests and message tables, and an administrator editing
            one gets quoting rules they already know. YAML would need
            powershell-yaml, which is a module the console would then have to
            carry to draw a window.

        .PARAMETER Culture
            The culture to load, as a folder-style name: en-us, he-il, de-de.
            Defaults to the current thread's.

        .PARAMETER Path
            The Strings folder. Defaults to the module's own.

        .PARAMETER PassThruCulture
            Return the culture that was actually loaded rather than the table -
            'en-us' when the asked-for one does not exist. For a caller that
            wants to log which it got.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Collections.Hashtable - case-insensitive, key to string.
            With -PassThruCulture, System.String.

        .EXAMPLE
            $string = Get-HDTStringTable
            Set-HDTWindowText -Root $window -String $string

        .EXAMPLE
            Get-HDTStringTable -Culture 'he-il'

            The Hebrew table, with every untranslated key filled from en-us.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $Culture = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter()]
        [switch] $PassThruCulture
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $root = $Path
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = [System.IO.Path]::Combine($script:HDTModuleRoot, 'Strings')
    }

    $fallbackPath = [System.IO.Path]::Combine($root, 'en-us.psd1')

    if (-not (Test-Path -LiteralPath $fallbackPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new(
            ("there is no en-us.psd1 in '{0}'. It is the table every other culture falls back to, so a console cannot be drawn without it." -f $root),
            $fallbackPath)
    }

    $wanted = $Culture
    if ([string]::IsNullOrWhiteSpace($wanted)) {
        $wanted = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    }

    # THE FOLDER-STYLE NAME IS THE FILE NAME. en-US and en-us are the same
    # culture and a case-sensitive file system is not this module's problem.
    $wantedPath = [System.IO.Path]::Combine($root, ('{0}.psd1' -f $wanted.ToLowerInvariant()))

    $loaded = 'en-us'
    if ((Test-Path -LiteralPath $wantedPath -PathType Leaf) -and
        -not [string]::Equals($wanted, 'en-us', [System.StringComparison]::OrdinalIgnoreCase)) {

        $loaded = $wanted.ToLowerInvariant()
    }

    if ($PassThruCulture) { return $loaded }

    $table = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    # ENGLISH FIRST, THE TRANSLATION OVER THE TOP. That order is what makes a
    # half-finished translation usable: every key exists, and the ones somebody
    # has got to are the ones that changed.
    foreach ($file in @($fallbackPath, $wantedPath)) {

        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

        $data = Import-PowerShellDataFile -LiteralPath $file

        foreach ($key in @($data.Keys)) {
            $table[[string] $key] = [string] $data[$key]
        }
    }

    return $table
}
