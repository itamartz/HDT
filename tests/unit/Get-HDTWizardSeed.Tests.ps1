# WHAT THE RULES ALREADY KNOW, IN THE BOXES, BEFORE THE TECHNICIAN TYPES.
#
# MDT PREFILLS ITS PANES FROM CustomSettings.ini AND HDT DID NOT. Every box on
# every page came up holding what the MARKUP said - HDTJoinWorkgroupBox carried
# Text="WORKGROUP" as a literal, and everything else came up empty - so a share
# whose rules.yaml answered a question still showed the technician a blank box
# to answer it again. Only the computer name was ever seeded, by its own command.
#
# AND THE REASON IT WAS NOT DONE SOONER IS REAL, NOT AN OVERSIGHT. Every value
# the wizard collects re-enters the engine as the Wizard SOURCE - the highest
# precedence in DESIGN 3.1 - so a box seeded from a rule and never touched would
# be collected as though the technician had typed it. The deployment would be
# right and the PROVENANCE WOULD LIE: the report would say a name was typed at
# the bench when a rule on the share produced it, which is exactly the question
# provenance exists to answer.
#
# SO SEEDING IS HALF THE FIX AND THE OTHER HALF IS IN THE HARVEST: a value
# identical to what was seeded is not collected at all, and the rule that
# produced it stands with its own provenance. Change it and it is yours.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:entry = {
        param([string] $Control, [string] $Variable, [hashtable] $Extra)

        $row = [pscustomobject] @{ Control = $Control; Variable = $Variable }
        if ($null -ne $Extra) {
            foreach ($key in @($Extra.Keys)) {
                $row | Add-Member -MemberType NoteProperty -Name $key -Value $Extra[$key]
            }
        }

        return $row
    }

    $script:page = {
        param([string] $Id, [object[]] $Collect)

        return [pscustomobject] @{ Id = $Id; Title = $Id; Collect = $Collect }
    }

    $script:bag = {
        param([hashtable] $Value)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $live[[string] $key] = $Value[$key] }
        }

        return $live
    }
}

Describe 'Get-HDTWizardSeed' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTWizardSeed' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'what it puts in a box' {

        It 'fills a box from the variable the page collects into' {
            $page = & $script:page 'A' @((& $script:entry 'HDTJoinWorkgroupBox' 'HDTJoinWorkgroup' $null))
            $seed = Get-HDTWizardSeed -Page @($page) -Variable (& $script:bag @{ HDTJoinWorkgroup = 'WORKGROUP' })

            [string] (@($seed)[0].Name) | Should -Be 'HDTJoinWorkgroupBox'
            [string] (@($seed)[0].Text) | Should -Be 'WORKGROUP'
        }

        It 'writes the property the page named, not always Text' {
            # A ComboBox answers SelectedValue and a PasswordBox has no Text at
            # all, so a seed that always wrote Text would throw on one and
            # silently miss the other.
            $page = & $script:page 'A' @(
                (& $script:entry 'HDTTimeZoneNameBox' 'HDTTimeZone' @{ Property = 'SelectedValue' }))

            $seed = Get-HDTWizardSeed -Page @($page) -Variable (& $script:bag @{ HDTTimeZone = 'GMT Standard Time' })

            [string] (@($seed)[0].Property) | Should -Be 'SelectedValue'
        }

        It 'defaults to Text when the page named no property' {
            $page = & $script:page 'A' @((& $script:entry 'HDTNameBox' 'HDTComputerName' $null))
            $seed = Get-HDTWizardSeed -Page @($page) -Variable (& $script:bag @{ HDTComputerName = 'HDT-01' })

            [string] (@($seed)[0].Property) | Should -Be 'Text'
        }

        It 'seeds across every page it is given, because the shell applies fields once' {
            $one = & $script:page 'A' @((& $script:entry 'HDTNameBox' 'HDTComputerName' $null))
            $two = & $script:page 'B' @((& $script:entry 'HDTJoinWorkgroupBox' 'HDTJoinWorkgroup' $null))

            $seed = Get-HDTWizardSeed -Page @($one, $two) `
                -Variable (& $script:bag @{ HDTComputerName = 'HDT-01'; HDTJoinWorkgroup = 'WORKGROUP' })

            @($seed | ForEach-Object { [string] $_.Name }) | Should -Be @('HDTNameBox', 'HDTJoinWorkgroupBox')
        }
    }

    Context 'what it leaves alone' {

        It 'seeds nothing for a variable the rules did not answer' {
            # AN EMPTY BOX IS THE HONEST ANSWER when nothing knows the value.
            $page = & $script:page 'A' @((& $script:entry 'HDTNameBox' 'HDTComputerName' $null))

            @(Get-HDTWizardSeed -Page @($page) -Variable (& $script:bag @{})).Count | Should -Be 0
        }

        It 'seeds nothing for a variable that resolved to empty' {
            $page = & $script:page 'A' @((& $script:entry 'HDTNameBox' 'HDTComputerName' $null))

            @(Get-HDTWizardSeed -Page @($page) -Variable (& $script:bag @{ HDTComputerName = '  ' })).Count |
                Should -Be 0
        }

        It 'leaves a list of ticks to the command that reads the catalog' {
            # select: many is the Applications page, and its rows come from
            # Get-HDTWizardApplication - which also decides which are already
            # ticked. A seed writing a joined string into that control would
            # fight it and lose.
            $page = & $script:page 'A' @(
                (& $script:entry 'HDTApplicationList' 'HDTApplications' @{ Select = 'many' }))

            @(Get-HDTWizardSeed -Page @($page) -Variable (& $script:bag @{ HDTApplications = '7Zip-24.09' })).Count |
                Should -Be 0
        }

        It 'seeds nothing for a page that collects nothing' {
            @(Get-HDTWizardSeed -Page @((& $script:page 'Summary' @())) -Variable (& $script:bag @{ HDTComputerName = 'X' })).Count |
                Should -Be 0
        }

        It 'survives a null page list and a null bag rather than throwing' {
            # The payload calls this before the wizard opens, on a share it may
            # have only just reached; neither absence is a reason to lose the
            # screen.
            @(Get-HDTWizardSeed -Page $null -Variable (& $script:bag @{})).Count | Should -Be 0
            @(Get-HDTWizardSeed -Page @() -Variable $null).Count | Should -Be 0
        }

        It 'names each control once when two variables come off one box' {
            # ComputerDetail's account box fills HDTDomainAdmin and, through the
            # split, HDTDomainAdminDomain. Two seeds for one control would have
            # the second overwrite the first, and which won would depend on the
            # order the page happened to declare them in.
            $page = & $script:page 'A' @(
                (& $script:entry 'HDTAccountBox' 'HDTDomainAdmin' $null),
                (& $script:entry 'HDTAccountBox' 'HDTDomainAdminDomain' $null))

            $seed = Get-HDTWizardSeed -Page @($page) -Variable (& $script:bag @{
                    HDTDomainAdmin = 'svc-hdt-join'; HDTDomainAdminDomain = 'CORP' })

            @($seed).Count | Should -Be 1
            [string] (@($seed)[0].Text) | Should -Be 'svc-hdt-join'
        }
    }
}
