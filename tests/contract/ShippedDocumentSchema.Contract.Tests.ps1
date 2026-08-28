# EVERY DOCUMENT THIS MODULE SHIPS, AGAINST THE SCHEMA THAT DESCRIBES IT.
#
# THE SHIPPED wizard.yaml FAILED ITS OWN SCHEMA AND NOTHING SAID SO. The
# AdminPassword page declares confirm: HDTAdminPasswordConfirmBox, validate is
# additionalProperties: false, and the schema had no confirm property - so the
# file this module copies onto every new share was invalid against the contract
# published beside it, and had been since the page shipped. The engine's own
# validator accepted it (Assert-HDTWizardDocument knows the key), so a technician
# saw nothing; a console or a CI job driving off the schema would have refused
# the share outright.
#
# IT IS DRIVEN OFF A GLOB, WHICH IS THE ONLY REASON IT WOULD HAVE CAUGHT THAT.
# A test naming wizard.yaml passes for wizard.yaml and fails nobody afterwards -
# CLAUDE.md rule 8. Schemas are enumerated out of schemas\, shipped documents
# out of the trees a new workspace is built from, and a schema named X describes
# a document named X. Add a schema and its shipped document is checked; add a
# document and the schema that names it starts checking it.
#
# TWO LEGS, AND THE 5.1 ONE IS THE GATE. Test-Json is the real validator and it
# does not exist on Windows PowerShell 5.1 - which is what the whole suite runs
# on - so every schema contract in this directory skips there, and that is
# exactly how the confirm drift survived. So this file carries a second,
# deliberately CONSERVATIVE walk that runs everywhere: it reports only what
# cannot be argued with - a key an additionalProperties: false object does not
# declare, a value outside an enum, a required key that is absent - and skips
# any subtree whose schema it cannot resolve flatly (oneOf, anyOf, allOf, not,
# patternProperties, a $ref it cannot follow). It is not a JSON Schema
# implementation and must not become one; it is the drift detector for the class
# of drift that has actually happened here twice.

$script:HDTRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("ShippedDocumentSchema: the Test-Json leg is SKIPPED on PowerShell {0} - it does not exist there. The conservative walk below runs on both." -f $PSVersionTable.PSVersion)
}

# THE TREES A NEW SHARE IS BUILT FROM, plus the samples an administrator copies.
# A sample that does not validate is worse than no sample.
$script:HDTDocumentRoot = @('src/Hephaestus/Templates', 'samples/workspace')

$script:HDTShippedDocument = @()
foreach ($relative in $script:HDTDocumentRoot) {
    $full = Join-Path -Path $script:HDTRepoRoot -ChildPath $relative
    if (-not (Test-Path -LiteralPath $full)) { continue }

    $script:HDTShippedDocument += @(Get-ChildItem -LiteralPath $full -Filter '*.yaml' -File -Recurse)
}

# A SCHEMA NAMED X DESCRIBES A DOCUMENT NAMED X. Nothing is written down here:
# schemas\wizard.schema.json takes wizard.yaml wherever one ships, and a schema
# with no shipped document of its own simply pairs with nothing.
$script:HDTSchemaPair = @(@(Get-ChildItem -LiteralPath (Join-Path -Path $script:HDTRepoRoot -ChildPath 'schemas') -Filter '*.schema.json' -File) |
        ForEach-Object {

        $schemaFile = $_
        $want = $schemaFile.Name -replace '\.schema\.json$', '.yaml'

        @($script:HDTShippedDocument | Where-Object { $_.Name -eq $want }) | ForEach-Object {
            @{
                Name         = ('{0} <- {1}' -f $schemaFile.Name, $_.FullName.Substring($script:HDTRepoRoot.Length + 1))
                SchemaPath   = $schemaFile.FullName
                DocumentPath = $_.FullName
            }
        }
    })

Describe 'shipped documents against the schemas that describe them' {

    BeforeAll {
        Import-Module -Name powershell-yaml -ErrorAction Stop

        function Resolve-HDTSchemaNode {
            <#
                A schema node with any local $ref followed. A ref this cannot
                follow returns nothing, and the caller skips that subtree -
                see the header: silence is the safe answer here, a wrong
                complaint is not.
            #>
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter(Position = 0)]
                [AllowNull()]
                [object] $Schema,

                [Parameter(Position = 1)]
                [AllowNull()]
                [object] $Root
            )

            $guard = 0

            while ($null -ne $Schema -and $Schema -is [psobject] -and
                $null -ne $Schema.PSObject.Properties['$ref'] -and $guard -lt 8) {

                $guard++
                $ref = [string] $Schema.'$ref'
                if (-not $ref.StartsWith('#/')) { return $null }

                $node = $Root
                foreach ($token in $ref.Substring(2).Split('/')) {
                    if ($null -eq $node -or $null -eq $node.PSObject.Properties[$token]) { return $null }
                    $node = $node.$token
                }

                $Schema = $node
            }

            return $Schema
        }

        function Get-HDTSchemaViolation {
            <#
                What a document says that its schema flatly forbids. See the
                header for what this deliberately does not check.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param(
                [Parameter(Position = 0)]
                [AllowNull()]
                [object] $Node,

                [Parameter(Position = 1)]
                [AllowNull()]
                [object] $Schema,

                [Parameter(Position = 2)]
                [AllowNull()]
                [object] $Root,

                [Parameter(Position = 3)]
                [string] $Path
            )

            $violation = New-Object -TypeName System.Collections.ArrayList

            $Schema = Resolve-HDTSchemaNode -Schema $Schema -Root $Root
            if ($null -eq $Schema) { return @() }

            # A SUBTREE THIS CANNOT JUDGE FLATLY IS NOT JUDGED. oneOf and its
            # relatives mean "some branch of this applies", and picking the
            # wrong branch would invent a failure in a file nobody broke.
            foreach ($vague in @('oneOf', 'anyOf', 'allOf', 'not', 'patternProperties')) {
                if ($null -ne $Schema.PSObject.Properties[$vague]) { return @() }
            }

            if ($Node -is [System.Collections.IDictionary]) {

                $declared = @()
                if ($null -ne $Schema.PSObject.Properties['properties']) {
                    $declared = @($Schema.properties.PSObject.Properties | ForEach-Object { $_.Name })
                }

                $closed = $false
                if ($null -ne $Schema.PSObject.Properties['additionalProperties']) {
                    $closed = ($Schema.additionalProperties -is [bool]) -and (-not $Schema.additionalProperties)
                }

                if ($null -ne $Schema.PSObject.Properties['required']) {
                    foreach ($need in @($Schema.required)) {
                        if (-not $Node.Contains([string] $need)) {
                            [void] $violation.Add(('{0}: required key ''{1}'' is missing' -f $Path, $need))
                        }
                    }
                }

                foreach ($key in @($Node.Keys)) {
                    $name = [string] $key

                    if ($closed -and $declared -notcontains $name) {
                        [void] $violation.Add(('{0}.{1}: the schema declares no such key' -f $Path, $name))
                        continue
                    }

                    if ($declared -notcontains $name) { continue }

                    foreach ($found in @(Get-HDTSchemaViolation -Node $Node[$key] -Schema $Schema.properties.$name `
                                -Root $Root -Path ('{0}.{1}' -f $Path, $name))) {

                        [void] $violation.Add($found)
                    }
                }

                return [string[]] @($violation)
            }

            if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {

                if ($null -eq $Schema.PSObject.Properties['items']) { return [string[]] @($violation) }

                $index = 0
                foreach ($item in $Node) {
                    foreach ($found in @(Get-HDTSchemaViolation -Node $item -Schema $Schema.items `
                                -Root $Root -Path ('{0}[{1}]' -f $Path, $index))) {

                        [void] $violation.Add($found)
                    }

                    $index++
                }

                return [string[]] @($violation)
            }

            # CASE-SENSITIVE, BECAUSE A JSON SCHEMA PATTERN IS. PowerShell's
            # -match is not, and every pattern in these schemas is a name
            # shape - ^HDT..., which 'hdtFoo' must not satisfy here when the
            # engine will refuse it there.
            if ($Node -is [string] -and $null -ne $Schema.PSObject.Properties['pattern']) {

                if ([string] $Node -cnotmatch [string] $Schema.pattern) {
                    [void] $violation.Add(('{0}: ''{1}'' does not match {2}' -f $Path, $Node, $Schema.pattern))
                }
            }

            if ($Node -is [string] -and $null -ne $Schema.PSObject.Properties['minLength']) {

                if (([string] $Node).Length -lt [int] $Schema.minLength) {
                    [void] $violation.Add(('{0}: ''{1}'' is shorter than the {2} characters the schema requires' -f
                            $Path, $Node, $Schema.minLength))
                }
            }

            # ORDINAL, BECAUSE AN ENUM IS A LIST OF LITERALS. PowerShell's own
            # -contains would accept 'computername' for 'ComputerName' and the
            # engine would then refuse it.
            if ($Node -is [string] -and $null -ne $Schema.PSObject.Properties['enum']) {

                $allowed = @($Schema.enum | ForEach-Object { [string] $_ })

                if (@($allowed | Where-Object { [string]::Equals($_, [string] $Node, [System.StringComparison]::Ordinal) }).Count -eq 0) {
                    [void] $violation.Add(('{0}: ''{1}'' is not one of {2}' -f $Path, $Node, ($allowed -join ', ')))
                }
            }

            return [string[]] @($violation)
        }

        function Get-HDTDocumentJson {
            <#
                A YAML document as the JSON Test-Json is handed. An empty
                document parses to $null, which ConvertTo-Json emits nothing at
                all for and Test-Json refuses to bind; the honest JSON for it is
                the literal null.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param(
                [Parameter(Mandatory = $true, Position = 0)]
                [string] $Path
            )

            $document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($Path)) -Ordered

            if ($null -eq $document) { return 'null' }

            return ($document | ConvertTo-Json -Depth 30)
        }
    }

    # THE COUNTS ARE CARRIED IN AS TEST DATA, AND THAT IS NOT A STYLE CHOICE.
    # A $script: variable assigned while Pester is DISCOVERING tests is $null by
    # the time one RUNS, and @($null).Count is 1 - so a guard written the
    # obvious way passes without ever seeing the list it claims to be guarding.
    # This file's own "pairs at least one" did exactly that until it was caught.
    # Anything computed at discovery reaches an It through -ForEach or not at
    # all.
    Context 'the pairing itself' {

        # A DISCOVERY RULE THAT PAIRS NOTHING PASSES EVERY TEST BELOW. This is
        # the guard on the glob, not on the documents.
        It 'pairs at least one shipped document with its schema' -ForEach @(@{
                PairCount = @($script:HDTSchemaPair).Count
            }) {

            $PairCount | Should -BeGreaterThan 0
        }

        It 'covers the wizard definition this module seeds onto every new share' -ForEach @(@{
                WizardPairCount = @($script:HDTSchemaPair | Where-Object {
                        $_.SchemaPath -like '*wizard.schema.json' -and
                        $_.DocumentPath -like '*src\Hephaestus\Templates\Wizard\wizard.yaml'
                    }).Count
            }) {

            $WizardPairCount | Should -Be 1 -Because 'Templates\Wizard\wizard.yaml is the one place of truth and must be held to the schema'
        }
    }

    Context 'what the schema flatly forbids' {

        It 'finds nothing the schema forbids in <Name>' -ForEach $script:HDTSchemaPair {

            $schema = [System.IO.File]::ReadAllText($SchemaPath) | ConvertFrom-Json
            $document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($DocumentPath)) -Ordered

            $found = @(Get-HDTSchemaViolation -Node $document -Schema $schema -Root $schema `
                    -Path (Split-Path -Leaf $DocumentPath))

            ($found -join '; ') | Should -BeExactly ''
        }
    }

    Context 'the real validator, on the leg that has one' -Skip:$script:HDTSchemaSkip {

        It 'validates <Name>' -ForEach $script:HDTSchemaPair {

            $schema = [System.IO.File]::ReadAllText($SchemaPath)
            $json = Get-HDTDocumentJson -Path $DocumentPath

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }
    }
}
