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

            ONE BLOCK PER WINDOW, AND THE KEY INSIDE IT IS Control.Property.
            A translator works through a screen at a time and can see when one
            is finished, which a flat list of four hundred keys does not allow;
            and a window's strings can be handed to Set-HDTWindowText without
            carrying every other window's along with them.

              @{
                  BootImage = @{
                      'HDTBootImageImageNameLabel.Text' = 'Image name'
                  }
              }

            -Page RETURNS ONE BLOCK, and without it every block is merged into
            one table - which is what a caller filling several windows from one
            load wants.

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

        .PARAMETER Page
            The block to return - BootImage, Wizard. Omitted, every block is
            merged: a control name is unique across this module, so the merge
            cannot collide.

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
            $string = Get-HDTStringTable -Page BootImage
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
        [AllowEmptyString()]
        [string] $Page = '',

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
    $seen = $false

    # ENGLISH FIRST, THE TRANSLATION OVER THE TOP. That order is what makes a
    # half-finished translation usable: every key exists, and the ones somebody
    # has got to are the ones that changed.
    foreach ($file in @($fallbackPath, $wantedPath)) {

        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

        $data = Import-PowerShellDataFile -LiteralPath $file

        foreach ($block in @($data.Keys | Sort-Object { [string]::Equals([string] $_, 'Common', [System.StringComparison]::OrdinalIgnoreCase) } -Descending)) {

            # A BLOCK IS A WINDOW, EXCEPT Common, WHICH IS EVERY WINDOW. Save,
            # Cancel, Browse: words that belong to no one screen and must be
            # spelled the same way on all of them. It is merged FIRST, so a page
            # naming the same control still wins.
            $isCommon = [string]::Equals([string] $block, 'Common', [System.StringComparison]::OrdinalIgnoreCase)

            if (-not [string]::IsNullOrWhiteSpace($Page) -and -not $isCommon -and
                -not [string]::Equals([string] $block, $Page, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if (-not $isCommon) { $seen = $true }
            $strings = $data[$block]
            if ($null -eq $strings -or $strings -isnot [System.Collections.IDictionary]) { continue }

            foreach ($key in @($strings.Keys)) {
                $table[[string] $key] = [string] $strings[$key]
            }
        }
    }

    # A PAGE NOBODY HAS IS A TYPO, AND IT USED TO BE INVISIBLE. The markup
    # carries no text any more, so an empty table is not "nothing to translate"
    # - it is a window of blank labels, and the mistake is a page name nobody
    # can see from a screenshot.
    if (-not [string]::IsNullOrWhiteSpace($Page) -and -not $seen) {
        throw [System.Collections.Generic.KeyNotFoundException]::new(
            ("there is no '{0}' block in '{1}'. The blocks are: {2}." -f $Page, $fallbackPath,
                ((@((Import-PowerShellDataFile -LiteralPath $fallbackPath).Keys) | Sort-Object) -join ', ')))
    }

    return $table
}
