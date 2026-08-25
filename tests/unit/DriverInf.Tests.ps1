# Reading one .inf as a driver.
#
# THE FIXTURE IS CAPTURED, NOT INVENTED. tests\fixtures\drivers\net-excerpt.inf
# came off C:\Windows\INF on the lab host, and every shape in it is one a real
# file has: a lowercase [version], %tokens% resolved from [Strings], a DriverVer
# that is a date AND a version, a DOUBLE comma before the hardware id, ';;'
# comments on the end of model lines, decorated section names, and two
# manufacturers in one file. An .inf that was written to suit the parser would
# prove nothing about the ones on a vendor's download page.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:infText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\drivers\net-excerpt.inf'))

    $script:read = {
        param([string] $Text, [string] $Name = 'net-excerpt.inf')

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($T, $N)
            ConvertFrom-HDTDriverInf -Text $T -InfName $N
        } $Text $Name
    }

    $script:driver = & $script:read $script:infText
}

Describe 'ConvertFrom-HDTDriverInf' {

    Context 'the header' {

        # THE SECTION NAME IS SOMETIMES LOWERCASE - netrtwlane.inf ships
        # '[version]' - so a case-sensitive parser reads nothing at all.
        It 'reads a lowercase [version] section' {
            $script:driver.Class | Should -BeExactly 'Net'
        }

        It 'carries the class guid' {
            $script:driver.ClassGuid | Should -BeExactly '{4d36e972-e325-11ce-bfc1-08002be10318}'
        }

        # UNRESOLVED, THE CONSOLE WOULD SHOW AN ADMINISTRATOR A PERCENT SIGN.
        It 'resolves the provider token through [Strings]' {
            $script:driver.Provider | Should -BeExactly 'Microsoft'
        }

        # DATE FIRST, THEN VERSION. Reading it the other way round puts a date in
        # a version column.
        It 'splits DriverVer into a date and a version' {
            $script:driver.Date | Should -BeExactly '08/03/2015'
            $script:driver.Version | Should -BeExactly '12.19.1.32'
        }

        It 'carries the catalog file name' {
            $script:driver.CatalogFile | Should -BeExactly 'net1ic64.cat'
        }

        It 'carries the file name it was told' {
            $script:driver.InfName | Should -BeExactly 'net-excerpt.inf'
        }
    }

    Context 'the devices it claims' {

        # THE POINT OF THE WHOLE PARSER.
        It 'finds the ids past the double comma' {
            $script:driver.HardwareId | Should -Contain 'PCI\VEN_8086&DEV_10DE'
        }

        It 'finds a SUBSYS id, which is the specific one a match ranks higher' {
            $script:driver.HardwareId | Should -Contain 'PCI\VEN_8086&DEV_10DE&SUBSYS_10DE8086'
        }

        # A LINE CAN CARRY MORE THAN ONE.
        It 'finds both ids on a line that lists two' {
            $script:driver.HardwareId | Should -Contain 'PCI\VEN_8086&DEV_1502'
            $script:driver.HardwareId | Should -Contain 'PCI\VEN_8086&DEV_1503'
        }

        # [Manufacturer] NAMES DECORATED SECTIONS - the models are in
        # [Intel.NTamd64.10.0.1], not [Intel].
        It 'reads a decorated model section' {
            @($script:driver.HardwareId | Where-Object { $_ -like 'PCI\VEN_8086*' }).Count |
                Should -BeGreaterThan 0
        }

        # A FILE CAN DECLARE MORE THAN ONE MANUFACTURER, and a parser that
        # stopped at the first would silently lose every Realtek device.
        It 'reads every manufacturer, not just the first' {
            $script:driver.HardwareId | Should -Contain 'PCI\VEN_10EC&DEV_B822&SUBSYS_B82210EC'
        }

        # A ';;' COMMENT SITS ON THE END OF A MODEL LINE, and an id with a
        # comment glued to it matches no machine.
        It 'strips a trailing comment off an id' {
            $script:driver.HardwareId | Should -Contain 'PCI\VEN_10EC&DEV_B822&SUBSYS_B12510EC'
            @($script:driver.HardwareId | Where-Object { $_ -like '*Dragon*' }) | Should -BeNullOrEmpty
        }

        # THE SAME ID APPEARS TWICE IN PLENTY OF REAL FILES.
        It 'lists each id once' {
            @($script:driver.HardwareId).Count |
                Should -Be @($script:driver.HardwareId | Sort-Object -Unique).Count
        }

        It 'counts the model lines it read' {
            $script:driver.ModelCount | Should -Be 6
        }

        # [ControlFlags] SITS BETWEEN THE SECTIONS and is not a model section;
        # reading it would put 'ExcludeFromSelect' in the id list.
        It 'reads no ids out of a section [Manufacturer] never named' {
            @($script:driver.HardwareId | Where-Object { $_ -like '*ExcludeFromSelect*' }) |
                Should -BeNullOrEmpty
            $script:driver.HardwareId | Should -Not -Contain '*'
        }
    }

    Context 'a file that is not a driver' {

        It 'answers empty for an empty file rather than throwing' {
            (& $script:read '' 'nothing.inf').HardwareId | Should -BeNullOrEmpty
        }

        # A DRIVER WITH NO [Manufacturer] IS AN INCLUDE FILE - netvwifibus.inf
        # is one - and it claims no devices of its own.
        It 'answers no ids for an include-only inf' {
            $text = @('[Version]', 'Class = Net', 'Provider = %MSFT%', '[Strings]', 'MSFT = "Microsoft"') -join "`r`n"

            $one = & $script:read $text 'include.inf'

            $one.Class | Should -BeExactly 'Net'
            $one.HardwareId | Should -BeNullOrEmpty
            $one.ModelCount | Should -Be 0
        }

        It 'leaves an unresolvable token alone rather than emptying it' {
            $text = @('[Version]', 'Provider = %NOSUCH%') -join "`r`n"

            (& $script:read $text 'x.inf').Provider | Should -BeExactly '%NOSUCH%'
        }
    }
}
