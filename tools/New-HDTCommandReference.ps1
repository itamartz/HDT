<#
.SYNOPSIS
    Regenerates docs/command-reference.html from the module's own help.

.DESCRIPTION
    The page had been written by hand. Its own generator meta tag said "edit the
    help, not this file", but nothing enforced that and nothing rebuilt it, so it
    drifted 32 commands behind the module before anybody noticed - the whole
    driver store and every selection profile command, missing from the reference
    an administrator reads.

    So the page is a build artifact now. Everything an entry says comes from
    Get-Help on the imported module: synopsis, syntax, parameters, examples, the
    long-form description behind "How it works", .NOTES, .OUTPUTS. The only
    editorial decision left is which group a command is listed under, and that
    lives in docs/command-categories.psd1 - one line per command, checked
    against FunctionsToExport by
    tests/contract/CommandReference.Contract.Tests.ps1.

    The page shell - the palette, the filter box, the theme toggle - is
    tools/CommandReference.template.html, which this fills in at three tokens:
    HDT:NAV, HDT:STATS and HDT:BODY.

    RUN IT UNDER WINDOWS POWERSHELL 5.1. The syntax lines come from
    Get-Command -Syntax, and 5.1 is the shell the engine runs in, so it is 5.1's
    rendering an administrator will be matching against what they typed.

.PARAMETER Path
    Where to write the page. Defaults to docs/command-reference.html beside this
    repository's tools folder.

.PARAMETER ModulePath
    The module manifest to document. Defaults to src/Hephaestus/Hephaestus.psd1.

.PARAMETER CategoryPath
    The grouping data file. Defaults to docs/command-categories.psd1.

.EXAMPLE
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File tools/New-HDTCommandReference.ps1

    Rebuilds the page in place, the way the contract test expects to find it.

.EXAMPLE
    tools/New-HDTCommandReference.ps1 -Path "$env:TEMP\preview.html"

    Renders to a scratch file, for looking at a change before it lands in docs.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Path,
    [string] $ModulePath,
    [string] $CategoryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $Path) { $Path = [IO.Path]::Combine($repositoryRoot, 'docs', 'command-reference.html') }
if (-not $ModulePath) { $ModulePath = [IO.Path]::Combine($repositoryRoot, 'src', 'Hephaestus', 'Hephaestus.psd1') }
if (-not $CategoryPath) { $CategoryPath = [IO.Path]::Combine($repositoryRoot, 'docs', 'command-categories.psd1') }
$templatePath = [IO.Path]::Combine($PSScriptRoot, 'CommandReference.template.html')

function ConvertTo-HDTReferenceHtmlText {
    <#
        .SYNOPSIS
            HTML-escapes one string, attribute-safe.
    #>
    param([string] $Text)

    if ($null -eq $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#x27;')
}

function Get-HDTReferenceParagraph {
    <#
        .SYNOPSIS
            Splits help text into paragraphs on blank lines.
    #>
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $normalised = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    @($normalised -split "`n\s*`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.TrimEnd() })
}

function Test-HDTReferencePreformatted {
    <#
        .SYNOPSIS
            Whether a paragraph's line breaks carry meaning.

        .DESCRIPTION
            Comment-based help is wrapped prose most of the time, and re-wrapping
            it to the reader's column width is what makes it readable on a phone.
            But some paragraphs are not prose: a code sample, a numbered list with
            a hanging indent, a two-column table held together by runs of spaces,
            an arrow map. Collapse those and they turn to mush.

            The tell is the same in every case - the author aligned something.
            A line that starts with a space, a run of two or more spaces inside a
            line, a line that opens with a variable or a pipeline, or a numbered
            item: any of those and the paragraph is emitted verbatim.
    #>
    param([string] $Paragraph)

    $line = @($Paragraph -split "`n")
    foreach ($one in $line) {
        if ($one -match '^\s+\S') { return $true }
        if ($one -match '\S {2,}\S') { return $true }
        if ($one -match '^\s*\$\w') { return $true }
        if ($one -match '^\s*\d+\.\s') { return $true }
        if ($one -match '^\s*[|>]') { return $true }
    }

    return $false
}

function ConvertTo-HDTReferenceProse {
    <#
        .SYNOPSIS
            Renders help text as paragraphs and preformatted blocks.
    #>
    param([string] $Text)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($paragraph in (Get-HDTReferenceParagraph -Text $Text)) {
        if (Test-HDTReferencePreformatted -Paragraph $paragraph) {
            $trimmed = ($paragraph -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
            $out.Add('<pre class="block">' + (ConvertTo-HDTReferenceHtmlText -Text $trimmed) + '</pre>')
        }
        else {
            $flat = ($paragraph -replace '\s+', ' ').Trim()
            $out.Add('<p>' + (ConvertTo-HDTReferenceHtmlText -Text $flat) + '</p>')
        }
    }

    $out -join "`n"
}

function Test-HDTReferenceExampleCode {
    <#
        .SYNOPSIS
            Whether a paragraph of an example's remarks is more of the command.

        .DESCRIPTION
            HELP CUTS AN EXAMPLE AFTER ITS FIRST LINE. Whatever the author wrote
            on line two - a backtick continuation, the next line of a pipeline,
            the second command in a two-command example - is handed back as the
            first paragraph of the REMARKS, ahead of the prose. Render remarks as
            prose and half the example turns into a sentence that will not run.

            Two tells put it back. A first line ending in a backtick or a pipe is
            unfinished by PowerShell's own rules, so what follows is its
            continuation whatever it looks like. Otherwise the paragraph is code
            when every line of it opens like code - a variable, a parameter, a
            pipe, a Verb-Noun - and it does not end in a full stop, which is what
            prose does and a command almost never does.
    #>
    param([string] $Code, [string] $Paragraph)

    if ([string]::IsNullOrWhiteSpace($Paragraph)) { return $false }

    $lastCodeLine = @($Code -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($lastCodeLine -and ($lastCodeLine[0].TrimEnd() -match '[`|]$')) { return $true }

    if ($Paragraph.TrimEnd().EndsWith('.')) { return $false }

    foreach ($one in @($Paragraph -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($one -notmatch '^\s*(\$|-\w|\||}|\{|\[|[A-Z][a-zA-Z]*-[A-Z][A-Za-z]+)') { return $false }
    }

    return $true
}

function Get-HDTReferenceProperty {
    <#
        .SYNOPSIS
            One property off a help object, or $null when help did not emit it.

        .DESCRIPTION
            Get-Help builds its objects a property at a time, so a parameter with
            no description simply has no 'description' property rather than an
            empty one - and under Set-StrictMode reading it is a terminating
            error. Every read of a help object goes through here.
    #>
    param($Object, [string] $Name)

    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Match($Name).Count -eq 0) { return $null }
    $Object.$Name
}

function Get-HDTReferenceList {
    <#
        .SYNOPSIS
            A property that holds a list, as a list, empty when help omitted it.
    #>
    param($Object, [string] $Name)

    $value = Get-HDTReferenceProperty -Object $Object -Name $Name
    @($value | Where-Object { $null -ne $_ })
}

function Get-HDTReferenceHelpText {
    <#
        .SYNOPSIS
            Flattens one of help's arrays-of-objects-with-a-Text-property.
    #>
    param($Node)

    if ($null -eq $Node) { return '' }
    (@($Node) | ForEach-Object {
            if ($null -eq $_) { '' }
            elseif ($_ -is [string]) { $_ }
            elseif ($_.PSObject.Properties.Match('Text').Count -gt 0) { $_.Text }
            else { [string] $_ }
        }) -join "`n"
}

# The verb families the chips colour by. A verb missing here is 'v-other', which
# is a chip that still says the verb - not a crash and not a blank.
$verbFamily = @{
    'Add'       = 'v-make'; 'Clear' = 'v-destroy'; 'ConvertTo' = 'v-shape'; 'Copy' = 'v-make'
    'Expand'    = 'v-shape'; 'Export' = 'v-read'; 'Get' = 'v-read'; 'Hide' = 'v-other'
    'Import'    = 'v-make'; 'Install' = 'v-act'; 'Invoke' = 'v-act'; 'Move' = 'v-write'
    'New'       = 'v-make'; 'Remove' = 'v-destroy'; 'Rename' = 'v-write'; 'Resolve' = 'v-read'
    'Save'      = 'v-make'; 'Select' = 'v-read'; 'Set' = 'v-write'; 'Show' = 'v-read'
    'Split'     = 'v-other'; 'Start' = 'v-act'; 'Stop' = 'v-act'; 'Test' = 'v-check'
    'Update'    = 'v-write'; 'Write' = 'v-make'
}

Import-Module -Name $ModulePath -Force -ErrorAction Stop
$manifest = Import-PowerShellDataFile -Path $ModulePath
$exported = @($manifest.FunctionsToExport)

$categoryData = Import-PowerShellDataFile -Path $CategoryPath
$category = @($categoryData.Category)

$listed = @($category | ForEach-Object { $_.Command })
$missing = @($exported | Where-Object { $listed -notcontains $_ })
$extra = @($listed | Where-Object { $exported -notcontains $_ })
if ($missing.Count -gt 0) {
    throw ("{0} is not listed in {1}: {2}. Add it to a group there - the page cannot invent one." -f
        (& { if ($missing.Count -eq 1) { 'A command' } else { "$($missing.Count) commands" } }),
        (Split-Path -Leaf $CategoryPath), ($missing -join ', '))
}
if ($extra.Count -gt 0) {
    throw ("{0} lists a command the module does not export: {1}." -f (Split-Path -Leaf $CategoryPath), ($extra -join ', '))
}

$navLine = New-Object System.Collections.Generic.List[string]
$bodyLine = New-Object System.Collections.Generic.List[string]
$withExample = 0
$withShouldProcess = 0

foreach ($group in $category) {
    $navLine.Add(('<li><a href="#{0}"><span class="nav-t">{1}</span><span class="nav-n">{2}</span></a></li>' -f
            $group.Id, (ConvertTo-HDTReferenceHtmlText -Text $group.Title), @($group.Command).Count))

    $head = '<section class="cat" id="{0}" data-cat="{0}"><header class="cat-head"><div class="cat-eyebrow">{1} commands</div><h2>{2}</h2><p class="cat-blurb">{3}</p></header><div class="cat-body">' -f
        $group.Id, @($group.Command).Count,
        (ConvertTo-HDTReferenceHtmlText -Text $group.Title),
        (ConvertTo-HDTReferenceHtmlText -Text $group.Blurb)
    $bodyLine.Add('    ' + $head.TrimEnd())

    foreach ($name in $group.Command) {
        $command = Get-Command -Name $name -ErrorAction Stop
        $help = Get-Help -Name $name -Full

        $synopsis = ($help.Synopsis -replace '\s+', ' ').Trim()

        $parameter = @(Get-HDTReferenceList -Object (Get-HDTReferenceProperty -Object $help -Name 'parameters') -Name 'parameter')

        # The filter matches on one lowercase string per command: its name, what
        # it is for, and every parameter - so 'driver inf' finds the command
        # whose synopsis says driver and whose parameter is -InfPath.
        $hay = (@($name, $synopsis) + @($parameter | ForEach-Object { $_.name })) -join ' '
        $bodyLine.Add(('<article class="fn" id="{0}" data-name="{1}" data-hay="{2}">' -f
                $name, $name.ToLowerInvariant(), (ConvertTo-HDTReferenceHtmlText -Text $hay.ToLowerInvariant())))

        $verb = ($name -split '-')[0]
        $family = 'v-other'
        if ($verbFamily.ContainsKey($verb)) { $family = $verbFamily[$verb] }

        $shouldProcess = [bool] $command.Parameters.ContainsKey('WhatIf')
        if ($shouldProcess) { $withShouldProcess++ }

        $bodyLine.Add('<header class="fn-head">')
        $bodyLine.Add(('<h3><a class="anchor" href="#{0}">{0}</a></h3>' -f $name))
        $tag = New-Object System.Collections.Generic.List[string]
        $tag.Add(('<span class="chip {0}">{1}</span>' -f $family, $verb))
        if ($shouldProcess) { $tag.Add('<span class="chip risk" title="Supports -WhatIf and -Confirm">ShouldProcess</span>') }
        $bodyLine.Add('<div class="tags">' + ($tag -join "`n") + "`n</div></header>")

        $bodyLine.Add('<p class="syn">' + (ConvertTo-HDTReferenceHtmlText -Text $synopsis) + '</p>')

        # Get-Command -Syntax, not the help's own rendering: it is the form the
        # shell itself shows, down to the lowercase <string>, so it matches what
        # an administrator sees when they get the call wrong.
        $syntax = @((Get-Command -Name $name -Syntax) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $sig = ($syntax | ForEach-Object { '<pre class="sig">' + (ConvertTo-HDTReferenceHtmlText -Text $_.Trim()) + '</pre>' }) -join ''
        $bodyLine.Add('<div class="sig-wrap">' + $sig + '</div>')

        if ($parameter.Count -gt 0) {
            $row = New-Object System.Collections.Generic.List[string]
            foreach ($p in $parameter) {
                $flag = New-Object System.Collections.Generic.List[string]
                if ((Get-HDTReferenceProperty -Object $p -Name 'required') -eq 'true') { $flag.Add('<span class="req">required</span>') }
                $pipeline = [string] (Get-HDTReferenceProperty -Object $p -Name 'pipelineInput')
                if ($pipeline -and $pipeline -notlike 'false*') { $flag.Add('<span class="pipe">pipeline</span>') }
                $flagHtml = ''
                if ($flag.Count -gt 0) { $flagHtml = '<div class="p-flags">' + ($flag -join ' ') + '</div>' }

                $typeName = [string] (Get-HDTReferenceProperty -Object (Get-HDTReferenceProperty -Object $p -Name 'type') -Name 'name')
                if (-not $typeName) { $typeName = 'Object' }

                $desc = ConvertTo-HDTReferenceProse -Text (Get-HDTReferenceHelpText -Node (Get-HDTReferenceProperty -Object $p -Name 'description'))
                if ([string]::IsNullOrWhiteSpace($desc)) { $desc = '<span class="muted">&mdash;</span>' }

                $row.Add(('<tr><td class="p-name"><code>-{0}</code>{1}</td><td class="p-type"><code>{2}</code></td><td class="p-desc">{3}</td></tr>' -f
                        $p.name, $flagHtml, (ConvertTo-HDTReferenceHtmlText -Text $typeName), $desc))
            }
            $bodyLine.Add('<section class="params"><h4>Parameters</h4><div class="table-wrap"><table>' + ($row -join '') + '</table></div></section>')
        }

        $example = @(Get-HDTReferenceList -Object (Get-HDTReferenceProperty -Object $help -Name 'examples') -Name 'example')
        if ($example.Count -gt 0) {
            $withExample++
            $block = New-Object System.Collections.Generic.List[string]
            $n = 0
            foreach ($e in $example) {
                $n++
                $code = [string] (Get-HDTReferenceProperty -Object $e -Name 'code')

                # Take back the continuation lines help handed to the remarks
                # before rendering what is left of them as prose.
                $paragraph = New-Object System.Collections.Generic.List[string]
                foreach ($one in (Get-HDTReferenceParagraph -Text (Get-HDTReferenceHelpText -Node (Get-HDTReferenceProperty -Object $e -Name 'remarks')))) {
                    $paragraph.Add($one)
                }
                while ($paragraph.Count -gt 0 -and (Test-HDTReferenceExampleCode -Code $code -Paragraph $paragraph[0])) {
                    $code = ($code.TrimEnd() + "`n" + $paragraph[0].Trim())
                    $paragraph.RemoveAt(0)
                }

                $remark = ConvertTo-HDTReferenceProse -Text ($paragraph -join "`n`n")
                $block.Add(('<div class="ex"><div class="ex-title">Example {0}</div><pre class="code">{1}</pre>{2}</div>' -f
                        $n, (ConvertTo-HDTReferenceHtmlText -Text $code.TrimEnd()), $remark))
            }
            $bodyLine.Add('<section class="examples"><h4>Examples</h4>' + ($block -join '') + '</section>')
        }

        $description = ConvertTo-HDTReferenceProse -Text (Get-HDTReferenceHelpText -Node (Get-HDTReferenceProperty -Object $help -Name 'description'))
        if (-not [string]::IsNullOrWhiteSpace($description)) {
            $bodyLine.Add('<details class="notes"><summary>How it works</summary><div class="prose">' + $description + '</div></details>')
        }

        $extraBlock = New-Object System.Collections.Generic.List[string]
        # Help files the .OUTPUTS prose into the return type's NAME, which reads
        # like a bug and is simply where PowerShell puts it.
        $returnValue = @(Get-HDTReferenceList -Object (Get-HDTReferenceProperty -Object $help -Name 'returnValues') -Name 'returnValue')
        $outputText = (@($returnValue | ForEach-Object {
                    [string] (Get-HDTReferenceProperty -Object (Get-HDTReferenceProperty -Object $_ -Name 'type') -Name 'name')
                }) | Where-Object { $_ }) -join "`n`n"
        if (-not [string]::IsNullOrWhiteSpace($outputText)) {
            $extraBlock.Add('<div class="kv"><span class="k">Outputs</span><div class="v">' + (ConvertTo-HDTReferenceProse -Text $outputText) + '</div></div>')
        }

        $alertText = Get-HDTReferenceHelpText -Node (Get-HDTReferenceList -Object (Get-HDTReferenceProperty -Object $help -Name 'alertSet') -Name 'alert')
        if (-not [string]::IsNullOrWhiteSpace($alertText)) {
            $extraBlock.Add('<div class="kv"><span class="k">Notes</span><div class="v">' + (ConvertTo-HDTReferenceProse -Text $alertText) + '</div></div>')
        }

        if ($extraBlock.Count -gt 0) { $bodyLine.Add('<div class="extra">' + ($extraBlock -join '') + '</div>') }

        $source = ''
        if ($command.ScriptBlock -and $command.ScriptBlock.File) {
            $source = $command.ScriptBlock.File
            if ($source.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $source = $source.Substring($repositoryRoot.Length).TrimStart('\', '/')
            }
            $source = $source.Replace('\', '/')
        }
        if ($source) { $bodyLine.Add('<footer class="src"><code>' + (ConvertTo-HDTReferenceHtmlText -Text $source) + '</code></footer>') }

        $bodyLine.Add('</article>')
    }

    $bodyLine.Add('</div></section>')
}

$stats = @(
    '      <div class="stats">'
    ('        <div class="stat"><div class="n">{0}</div><div class="l">exported commands</div></div>' -f $exported.Count)
    ('        <div class="stat"><div class="n">{0}</div><div class="l">groups</div></div>' -f $category.Count)
    ('        <div class="stat"><div class="n">{0}</div><div class="l">carry examples</div></div>' -f $withExample)
    ('        <div class="stat"><div class="n">{0}</div><div class="l">support -WhatIf</div></div>' -f $withShouldProcess)
    '      </div>'
) -join "`r`n"

$nav = '    <nav><ul>' + ($navLine -join "`r`n") + '</ul></nav>'

$template = [IO.File]::ReadAllText($templatePath)
foreach ($token in @('<!--HDT:NAV-->', '<!--HDT:STATS-->', '<!--HDT:BODY-->', '<!--HDT:VERSION-->')) {
    if ($template.IndexOf($token) -lt 0) { throw ("the template has no {0} token - {1} cannot fill it in." -f $token, $MyInvocation.MyCommand.Name) }
}

$html = $template.
    Replace('    <!--HDT:NAV-->', $nav).
    Replace('      <!--HDT:STATS-->', $stats).
    Replace('    <!--HDT:BODY-->', (($bodyLine -join "`r`n"))).
    Replace('<!--HDT:VERSION-->', [string] $manifest.ModuleVersion)

# One line ending for the whole file. Help text arrives with whatever the source
# file had, and a page that is half CRLF is a page whose every regeneration shows
# up as a diff in lines nobody touched.
$html = $html -replace "`r`n", "`n" -replace "`n", "`r`n"

if ($PSCmdlet.ShouldProcess($Path, 'write the command reference')) {
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding $false))
    Write-Verbose ("wrote {0} commands in {1} groups to {2}" -f $exported.Count, $category.Count, $Path)
}

[pscustomobject] @{
    Path            = $Path
    Command         = $exported.Count
    Group           = $category.Count
    WithExample     = $withExample
    WithWhatIf      = $withShouldProcess
}
