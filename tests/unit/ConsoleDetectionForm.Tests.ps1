# THE DETECTION RULE, AS A FORM RATHER THAN A BLOCK OF YAML.
#
# A rule is a type and two to four keys, and WHICH keys is decided by the type -
# msiProduct wants a product code, registry wants a key and optionally a value
# and its data. Typing that as YAML into a box means knowing the type's key list
# and the indentation, and getting either wrong is a document the validator
# refuses after the fact.
#
# SO THE TYPE IS CHOSEN AND THE BOXES FOLLOW FROM IT. This is the command that
# says which boxes those are, what is already in them, and whether what is in
# them is a rule that can be written.
#
# THE KEY LIST COMES FROM Get-HDTApplicationDetectKey, which the validator and
# the projector already read. A second list here would be a second place for the
# window and the engine to disagree about what a registry rule is.
#
# AND "NO RULE" IS ONE OF THE CHOICES. DESIGN 8 says an application with no
# detection installs every time, which is a decision somebody makes - not the
# absence of one - so it is on the list beside the four types.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function Get-HDTTestDetectionForm {
        [CmdletBinding()]
        [OutputType([object])]
        param([string] $Type, [object] $Detect)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ T = $Type; D = $Detect } {
            param($T, $D)

            $splat = @{}
            if (-not [string]::IsNullOrWhiteSpace($T)) { $splat['Type'] = $T }
            if ($null -ne $D) { $splat['Detect'] = $D }

            Get-HDTConsoleDetectionForm @splat
        }
    }
}

Describe 'Get-HDTConsoleDetectionForm' {

    Context 'the types on offer' {

        BeforeAll {
            $script:empty = Get-HDTTestDetectionForm
        }

        It 'offers the four the engine can run, and no rule at all' {
            @($script:empty.Choice | ForEach-Object { [string] $_.Type }) |
                Should -Be @('', 'msiProduct', 'file', 'registry', 'script')
        }

        It 'says what each one means, rather than showing the key' {
            # 'msiProduct' is what the document says; 'An MSI product code' is
            # what somebody choosing between four of them reads.
            @($script:empty.Choice | Where-Object { [string] $_.Type -eq 'msiProduct' })[0].Display |
                Should -BeLike '*MSI*'

            @($script:empty.Choice | Where-Object { [string] $_.Type -eq '' })[0].Display |
                Should -BeLike '*every time*'
        }

        It 'starts on no rule when the application has none' {
            [string] $script:empty.Type | Should -BeExactly ''
            @($script:empty.Field) | Should -BeNullOrEmpty
        }

        It 'is a complete answer, because no rule is a real answer' {
            [bool] $script:empty.Complete | Should -BeTrue
            [string] $script:empty.Message | Should -BeExactly ''
        }
    }

    Context 'the boxes a type asks for' {

        It 'asks msiProduct for the product code, and nothing else' {
            $form = Get-HDTTestDetectionForm -Type 'msiProduct'

            @($form.Field | ForEach-Object { [string] $_.Key }) | Should -Be @('productCode')
            [bool] @($form.Field)[0].Required | Should -BeTrue
        }

        It 'asks registry for the key, the value and the data' {
            $form = Get-HDTTestDetectionForm -Type 'registry'

            @($form.Field | ForEach-Object { [string] $_.Key }) | Should -Be @('key', 'value', 'data')
        }

        It 'marks the required one apart from the optional ones' {
            $form = Get-HDTTestDetectionForm -Type 'registry'

            [bool] @($form.Field | Where-Object { [string] $_.Key -eq 'key' })[0].Required | Should -BeTrue
            [bool] @($form.Field | Where-Object { [string] $_.Key -eq 'value' })[0].Required | Should -BeFalse
        }

        It 'labels each box in words, not in document keys' {
            $form = Get-HDTTestDetectionForm -Type 'file'

            @($form.Field | Where-Object { [string] $_.Key -eq 'path' })[0].Label |
                Should -Not -BeExactly 'path'
        }

        It 'says what to put in it' {
            $form = Get-HDTTestDetectionForm -Type 'msiProduct'

            [string] @($form.Field)[0].Hint | Should -Not -BeNullOrEmpty
        }
    }

    Context 'a rule that is already there' {

        BeforeAll {
            $script:existing = Get-HDTTestDetectionForm -Detect ([ordered] @{
                    type        = 'msiProduct'
                    productCode = '{23170F69-40C1-2702-2409-000001000000}'
                })
        }

        It 'starts on the type the document declares' {
            [string] $script:existing.Type | Should -BeExactly 'msiProduct'
        }

        It 'fills the boxes in from it' {
            [string] @($script:existing.Field)[0].Value | Should -BeExactly '{23170F69-40C1-2702-2409-000001000000}'
        }

        It 'keeps a value when the type is asked for again' {
            $again = Get-HDTTestDetectionForm -Type 'msiProduct' -Detect ([ordered] @{
                    type = 'msiProduct'; productCode = '{ABC}'
                })

            [string] @($again.Field)[0].Value | Should -BeExactly '{ABC}'
        }

        It 'empties the boxes when the type is changed to another one' {
            # A PRODUCT CODE IS NOT A REGISTRY KEY. Carrying the old value into
            # the new type's box would write a rule that parses and detects
            # nothing.
            $changed = Get-HDTTestDetectionForm -Type 'registry' -Detect ([ordered] @{
                    type = 'msiProduct'; productCode = '{ABC}'
                })

            @($changed.Field | ForEach-Object { [string] $_.Value }) | Should -Be @('', '', '')
        }
    }

    Context 'whether it can be written' {

        It 'refuses a type whose required box is empty, naming the box' {
            $form = Get-HDTTestDetectionForm -Type 'registry' -Detect ([ordered] @{ type = 'registry' })

            [bool] $form.Complete | Should -BeFalse
            [string] $form.Message | Should -Not -BeNullOrEmpty
        }

        It 'accepts one whose required box is filled' {
            $form = Get-HDTTestDetectionForm -Detect ([ordered] @{
                    type = 'registry'; key = 'HKLM:\SOFTWARE\Contoso'
                })

            [bool] $form.Complete | Should -BeTrue
            [string] $form.Message | Should -BeExactly ''
        }

        It 'does not mind an optional box being empty' {
            $form = Get-HDTTestDetectionForm -Detect ([ordered] @{
                    type = 'file'; path = 'C:\Program Files\7-Zip\7z.exe'
                })

            [bool] $form.Complete | Should -BeTrue
        }
    }

    Context 'what the document gets' {

        It 'is the type and the boxes that were filled in' {
            $form = Get-HDTTestDetectionForm -Detect ([ordered] @{
                    type = 'file'; path = 'C:\Program Files\7-Zip\7z.exe'; version = '24.09'
                })

            [string] $form.Rule['type'] | Should -BeExactly 'file'
            [string] $form.Rule['path'] | Should -BeExactly 'C:\Program Files\7-Zip\7z.exe'
            [string] $form.Rule['version'] | Should -BeExactly '24.09'
        }

        It 'leaves an empty optional box out of the document entirely' {
            # An empty key is not the same as an absent one: the validator
            # accepts the absence and the engine treats a blank as a value.
            $form = Get-HDTTestDetectionForm -Detect ([ordered] @{
                    type = 'file'; path = 'C:\7z.exe'; version = ''
                })

            $form.Rule.Contains('version') | Should -BeFalse
        }

        It 'is a line somebody could type, in the footer' {
            # DESIGN 12's "learn the automation surface by clicking around". A
            # command that would not run teaches nothing, so the rule is written
            # the way it would be typed rather than quoted as a blob.
            $form = Get-HDTTestDetectionForm -Detect ([ordered] @{
                    type = 'msiProduct'; productCode = '{23170F69}'
                })

            [string] $form.CommandText | Should -BeExactly "@{ type = 'msiProduct'; productCode = '{23170F69}' }"
        }

        It 'writes no rule as the empty hashtable, which is what removes the key' {
            [string] (Get-HDTTestDetectionForm).CommandText | Should -BeExactly '@{ }'
        }

        It 'is nothing at all for no rule, which is what clears the key' {
            $form = Get-HDTTestDetectionForm

            $form.Rule | Should -BeNullOrEmpty
        }
    }
}
