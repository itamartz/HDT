# Get-HDTVariableMap is DESIGN 3.2's MDT-to-HDT translation table as data rather
# than as prose: "Get-HDTVariableMap prints this table at runtime, and a contract
# test asserts every documented MDT name has exactly one HDT counterpart, so the
# mapping cannot silently drift."
#
# This file covers the cmdlet's own behaviour - shape, filtering, help. The
# drift-proofing lives in tests/contract/VariableNamespace.Contract.Tests.ps1.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTVariableMap' {

    It 'returns one object per variable' {
        $map = @(Get-HDTVariableMap)

        $map.Count | Should -BeGreaterThan 30
        @($map | Select-Object -ExpandProperty HDTName | Sort-Object -Unique).Count | Should -Be $map.Count
    }

    It 'returns objects carrying HDTName, MdtName, Writable, Origin and Description' {
        $map = @(Get-HDTVariableMap)
        $property = @($map[0].PSObject.Properties.Name)

        foreach ($name in @('HDTName', 'MdtName', 'Writable', 'Origin', 'Description')) {
            $property | Should -Contain $name
        }
    }

    It 'filters by -Name' {
        $one = @(Get-HDTVariableMap -Name 'HDTModel')

        $one.Count | Should -Be 1
        $one[0].HDTName | Should -BeExactly 'HDTModel'
        $one[0].MdtName | Should -BeExactly 'Model'
    }

    It 'accepts a wildcard in -Name' {
        $flag = @(Get-HDTVariableMap -Name 'HDTIs*' | Select-Object -ExpandProperty HDTName | Sort-Object)

        $flag | Should -Be @('HDTIsDesktop', 'HDTIsLaptop', 'HDTIsServer', 'HDTIsUEFI', 'HDTIsVM')
    }

    It 'accepts more than one name' {
        $some = @(Get-HDTVariableMap -Name 'HDTMake', 'HDTModel' | Select-Object -ExpandProperty HDTName | Sort-Object)

        $some | Should -Be @('HDTMake', 'HDTModel')
    }

    It 'returns nothing for a name that is not mapped' {
        @(Get-HDTVariableMap -Name 'HDTNoSuchVariable').Count | Should -Be 0
    }

    It 'reports an engine variable as not writable' {
        $engine = @(Get-HDTVariableMap -Name '_HDTLogPath')

        $engine.Count | Should -Be 1
        $engine[0].Writable | Should -BeFalse
        $engine[0].MdtName | Should -BeExactly '_SMSTSLogPath'
    }

    It 'maps the six variables the imaging steps publish' {
        # DESIGN 3.2 and 9.1/9.2: a step that publishes a variable other steps
        # and conditions compose on has to say so here, or Get-HDTVariableMap is
        # a table of the variables somebody remembered.
        foreach ($name in @('HDTTargetDisk', 'HDTSystemVolume', 'HDTOSVolume',
                'HDTRecoveryVolume', 'HDTImageIndex', 'HDTUnattendPath')) {

            $row = @(Get-HDTVariableMap -Name $name)

            $row.Count | Should -Be 1 -Because "$name is published by a phase 04 step"
            $row[0].Writable | Should -BeTrue
            $row[0].Description | Should -Not -BeNullOrEmpty
        }
    }

    It 'gives the four with an MDT counterpart their MDT name' {
        (Get-HDTVariableMap -Name 'HDTTargetDisk').MdtName | Should -BeExactly 'OSDDiskIndex'
        (Get-HDTVariableMap -Name 'HDTSystemVolume').MdtName | Should -BeExactly 'BootVolume'
        (Get-HDTVariableMap -Name 'HDTOSVolume').MdtName | Should -BeExactly 'OSVolume'
        (Get-HDTVariableMap -Name 'HDTRecoveryVolume').MdtName | Should -BeExactly 'RecoveryVolume'
    }

    It 'carries the locale settings the Locale and Time page collects' {
        # MDT'S PANE ASKS FOUR THINGS and HDT named only one of them. A wizard
        # page that collects a variable the map does not know about is a
        # variable nothing can document, translate to MDT, or report on - and
        # DESIGN 11.2 lists this page as collecting "HDTTimeZone, locale"
        # without ever saying what "locale" is spelled.
        foreach ($pair in @(
                @{ HDT = 'HDTUILanguage'; Mdt = 'UILanguage' }
                @{ HDT = 'HDTUserLocale'; Mdt = 'UserLocale' }
                @{ HDT = 'HDTKeyboardLocale'; Mdt = 'KeyboardLocale' }
                @{ HDT = 'HDTTimeZone'; Mdt = 'TimeZoneName' })) {

            $row = @(Get-HDTVariableMap -Name $pair.HDT)

            $row.Count | Should -Be 1 -Because ("{0} is collected by the Locale and Time page" -f $pair.HDT)
            $row[0].MdtName | Should -BeExactly $pair.Mdt
            $row[0].Description | Should -Not -BeNullOrEmpty

            # HDTTimeZone IS THE ONE THAT IS BOTH. The engine seeds it from the
            # boot image's own time zone so an unattended deployment gets a
            # sensible one, and the page overrides it when somebody is there to
            # choose - which is why it is 'engine' where the other three are
            # 'authored'.
            @('authored', 'engine') | Should -Contain ([string] $row[0].Origin)
        }
    }

    It 'leaves the two with no MDT counterpart empty' {
        (Get-HDTVariableMap -Name 'HDTImageIndex').MdtName | Should -BeNullOrEmpty
        (Get-HDTVariableMap -Name 'HDTUnattendPath').MdtName | Should -BeNullOrEmpty
    }

    It 'names their origin as a step rather than a fact or an authored value' {
        foreach ($name in @('HDTTargetDisk', 'HDTSystemVolume', 'HDTOSVolume',
                'HDTRecoveryVolume', 'HDTImageIndex', 'HDTUnattendPath')) {

            (Get-HDTVariableMap -Name $name).Origin | Should -BeExactly 'step'
        }
    }

    It 'reports no MDT counterpart for an HDT-only variable' {
        $only = @(Get-HDTVariableMap -Name 'HDTTPMVersion')

        $only.Count | Should -Be 1
        $only[0].MdtName | Should -BeNullOrEmpty
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTVariableMap -ErrorAction Stop

        # The Name assertion is not decoration. Get-Help falls back to a fuzzy
        # search when no command matches exactly, so for a command that does not
        # exist yet it happily returns ANOTHER command's help and a synopsis
        # assertion passes against it. Observed while writing this plan.
        $help.Name | Should -BeExactly 'Get-HDTVariableMap'
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match 'Get-HDTVariableMap \['
    }

    It 'has at least one example in its help' {
        $help = Get-Help -Name Get-HDTVariableMap -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTVariableMap'
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }
}

Describe 'HDTDeploymentType' {

    # MDT'S DeploymentType, WHICH ITS Client.xml GATES WHOLE GROUPS ON:
    # NEWCOMPUTER, REFRESH, REPLACE, UPGRADE. That is how one template serves
    # bare metal and an in-place refresh from the same file.
    #
    # HDT IMPLEMENTS ONE OF THEM. There is no State Capture, no USMT and no
    # replace path, so the variable has exactly one value today - and it exists
    # anyway, so a sequence can be written against it now and the groups that
    # arrive later need no rewrite of the ones already there.

    It 'is a variable the toolkit knows about' {
        Get-HDTVariableMap -Name 'HDTDeploymentType' | Should -Not -BeNullOrEmpty
    }

    It "carries MDT's own name for it, so the two can be read side by side" {
        (Get-HDTVariableMap -Name 'HDTDeploymentType').MdtName | Should -BeExactly 'DeploymentType'
    }

    It 'says what it is today rather than pretending to more' {
        (Get-HDTVariableMap -Name 'HDTDeploymentType').Description | Should -BeLike '*NEWCOMPUTER*'
    }
}

Describe "the wizard's own settings" {

    # MDT'S New Task Sequence WIZARD ASKS FOR THESE by name - Full Name,
    # Organization, Administrator Password - and writes them where the unattend
    # can read them. They are variables here for the same reason: an unattend
    # template substitutes %HDTAdminPassword% already.

    It '<HDTName> is known, and carries MDT''s name for it' -ForEach @(
        @{ HDTName = 'HDTFullName'; MdtName = 'FullName' }
        @{ HDTName = 'HDTOrgName'; MdtName = 'OrgName' }
        @{ HDTName = 'HDTAdminPassword'; MdtName = 'AdminPassword' }
    ) {
        $wanted = $MdtName

        $row = Get-HDTVariableMap -Name $HDTName

        $row | Should -Not -BeNullOrEmpty
        $row.MdtName | Should -BeExactly $wanted
    }

    It 'says the administrator password is readable in the file' {
        # IT IS NOT A SECRET AND THE DESCRIPTION SAYS SO. A value WinPE must use
        # with no human present cannot be protected by a key that also ships in
        # the boot image; the control is to treat the workspace and the media as
        # credentials.
        (Get-HDTVariableMap -Name 'HDTAdminPassword').Description | Should -BeLike '*log*'
    }

    # WHICH VARIABLES ARE SECRET IS DATA HERE, IN ONE PLACE, because three
    # separate writers already needed the answer and each invented its own.
    # The wizard summary renders "(set, not shown)", the console log matches a
    # word list, and Gather\provenance.json wrote the local administrator
    # password in clear on every machine HDT deployed until this column existed.
    It 'says of every variable whether it is a secret' {
        $property = @((Get-HDTVariableMap)[0].PSObject.Properties.Name)

        $property | Should -Contain 'IsSecret'
    }

    It 'marks at least one variable secret' {
        @(Get-HDTVariableMap | Where-Object { $_.IsSecret }).Count | Should -BeGreaterThan 0
    }

    # ASSERTED OVER THE SET, NOT OVER A LIST WRITTEN TWICE. A variable whose
    # NAME says it carries a password or a PIN and which is not marked secret is
    # the next provenance.json leak, so the shape of the name is what is
    # checked - which fails for the variable somebody adds tomorrow.
    It 'marks every variable whose name says it carries one' {
        $missed = @(Get-HDTVariableMap |
                Where-Object { $_.HDTName -match '(?i)password|pin$' -and -not $_.IsSecret })

        ($missed | ForEach-Object { $_.HDTName }) -join ', ' | Should -BeExactly ''
    }

    It 'does not mark a variable secret that plainly is not' -ForEach @(
        'HDTComputerName', 'HDTOrgName', 'HDTFullName', 'HDTJoinDomain') {

        # A column nothing distinguishes redacts the whole file and answers
        # nothing, which is the other way to get this wrong.
        (Get-HDTVariableMap -Name $PSItem).IsSecret | Should -BeFalse
    }
}
