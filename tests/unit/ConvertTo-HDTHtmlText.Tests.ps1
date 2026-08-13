# The escaper the HTML report is built on.
#
# A step message routinely carries the characters that break HTML: a command line
# has & in it, an unattend fragment has < and >, a quoted argument has both kinds
# of quote. A report that renders those raw is a report that swallows the very
# line the technician opened it for - or worse, renders an attacker-supplied
# machine name as markup.
#
# So this is escape-everything, once, and it has its own tests because everything
# in ConvertTo-HDTReport goes through it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:escape = {
        param([object] $Value)

        InModuleScope Hephaestus -Parameters @{ Value = $Value } {
            param($Value)
            ConvertTo-HDTHtmlText -Value $Value
        }
    }
}

Describe 'ConvertTo-HDTHtmlText' {

    It 'escapes an ampersand' {
        & $script:escape 'Sales & Marketing' | Should -BeExactly 'Sales &amp; Marketing'
    }

    It 'escapes a less than' {
        & $script:escape 'a<b' | Should -BeExactly 'a&lt;b'
    }

    It 'escapes a greater than' {
        & $script:escape 'a>b' | Should -BeExactly 'a&gt;b'
    }

    It 'escapes a double quote' {
        & $script:escape 'say "hi"' | Should -BeExactly 'say &quot;hi&quot;'
    }

    It 'escapes a single quote' {
        & $script:escape "it's" | Should -BeExactly 'it&#39;s'
    }

    It 'escapes an ampersand once, not twice' {
        # The classic bug: escaping & after < and > turns &lt; into &amp;lt;.
        & $script:escape '&amp;' | Should -BeExactly '&amp;amp;'
        & $script:escape '<' | Should -BeExactly '&lt;'
    }

    It 'returns an empty string for null' {
        & $script:escape $null | Should -BeExactly ''
    }

    It 'leaves plain text alone' {
        & $script:escape 'Apply OS' | Should -BeExactly 'Apply OS'
    }

    It 'escapes a full command line' {
        & $script:escape 'cmd.exe /c echo "a<b" & echo done' |
            Should -BeExactly 'cmd.exe /c echo &quot;a&lt;b&quot; &amp; echo done'
    }

    It 'renders a non-string by converting it first' {
        & $script:escape 42 | Should -BeExactly '42'
    }
}
