# THE ONE LINE A Validate STEP CARRIES IN THE TREE AND THE LOG.
#
# A technician watching the progress display wants to know which bound a machine
# failed, so the description names the bounds: "Validate: 2048 MB memory, 60 GB
# disk, and one unambiguous target disk". It is the optional third of the step
# contract's triple.
#
# THE SUBJECT OF THIS FILE IS THAT THE DESCRIPTION IS GENERATED FROM THE TABLE
# AND NOT WRITTEN OUT AGAIN. Get-HDTValidateCheckDefinition is the one place a
# check is declared - the console's Validate page binds an ItemsControl over it
# and gets a new row for free - and until this file was written the description
# hand-enumerated four keys instead of walking it. It had drifted FIVE checks
# behind: minTpmVersion, diskNumber, imageVersion, imageSizeMB and
# allowOtherPartition were all declarable, all enforced by the step, and all
# invisible in the tree. refresh.yaml declares three of them, so the shipped
# Refresh sequence described itself as "Validate: 2048 MB memory, and one
# unambiguous target disk" - saying nothing about the downgrade refusal, the
# free-space refusal or the partition-match refusal that are the whole reason
# the step is in that template.
#
# SO THE TEST THAT MATTERS HERE IS WRITTEN AGAINST THE SET. A test naming one
# key passes for that key and fails nobody after it.

# THE TABLE UNDER TEST IS PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    # A Validate step carrying exactly the keys given, in the shape
    # Import-HDTSequenceDocument flattens one into. IDictionary rather than
    # hashtable so an [ordered] literal keeps the order it was written in -
    # the description renders by the table's Order, but a caller reading these
    # tests should see the keys in the order the template declares them.
    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($null -ne $Property) {
            foreach ($name in @($Property.Keys)) { $bag[[string] $name] = $Property[$name] }
        }

        return [pscustomobject] @{ Index = 1; Name = 'Validate'; Type = 'Validate'; Property = $bag }
    }

    # What a step that declares nothing describes itself as. Every test that
    # asks "was this check named?" asks whether the answer moved off this.
    $script:baseline = Get-HDTValidateStepDescription -Step (& $script:newStep $null)
}

Describe 'the description walks the definition table' {

    It 'names every check Get-HDTValidateCheckDefinition declares' {
        $silent = New-Object -TypeName System.Collections.ArrayList

        foreach ($definition in @(Get-HDTValidateCheckDefinition)) {

            # A value of the shape the Kind column says the window draws.
            $value = 4242
            if ([string] $definition.Kind -eq 'Switch') { $value = $true }
            if ([string] $definition.Kind -eq 'List') { $value = @('HDTMarkerVariable') }

            $step = & $script:newStep ([ordered] @{ ([string] $definition.Key) = $value })
            $described = Get-HDTValidateStepDescription -Step $step

            if ($described -eq $script:baseline) { [void] $silent.Add([string] $definition.Key) }
        }

        (@($silent) -join ', ') | Should -BeExactly '' -Because (
            'a check the table declares and the description ignores is invisible in the console tree and in the log, ' +
            'which is the half-feature CLAUDE.md rule 8 is about - the table is the set, so this is the test for it')
    }

    It 'gives every check a Noun the description can render' {
        $missing = @(Get-HDTValidateCheckDefinition |
                Where-Object { -not ($_.PSObject.Properties.Name -contains 'Noun') } |
                ForEach-Object { [string] $_.Key })

        (@($missing) -join ', ') | Should -BeExactly '' -Because (
            'Noun is the short word the tree line is built from; a row without one cannot be described')
    }
}

Describe 'how each Kind renders' {

    It 'puts the unit between the value and the noun for a Number that has one' {
        $step = & $script:newStep ([ordered] @{ minRamMB = 2048 })

        Get-HDTValidateStepDescription -Step $step | Should -BeLike '*2048 MB memory*'
    }

    It 'puts the value after the noun for a Number with no unit' {
        $step = & $script:newStep ([ordered] @{ minTpmVersion = '2.0' })

        Get-HDTValidateStepDescription -Step $step | Should -BeLike '*TPM 2.0*'
    }

    It 'names a Switch that is on' {
        $step = & $script:newStep ([ordered] @{ requireUefi = $true })

        Get-HDTValidateStepDescription -Step $step | Should -BeLike '*UEFI firmware*'
    }

    # UNTICKED MEANS "DO NOT CHECK THIS", which is the same rule the console's
    # Validate page follows for an absent key - and the old description got it
    # wrong, naming UEFI for 'requireUefi: false' because it only asked whether
    # the key was present.
    It 'does not name a Switch that is off' {
        $step = & $script:newStep ([ordered] @{ requireUefi = $false })

        Get-HDTValidateStepDescription -Step $step | Should -BeExactly $script:baseline
    }

    It 'names each entry of a List' {
        $step = & $script:newStep ([ordered] @{ requireVariable = @('HDTComputerName', 'HDTTimeZoneName') })

        $described = Get-HDTValidateStepDescription -Step $step

        $described | Should -BeLike '*HDTComputerName*'
        $described | Should -BeLike '*HDTTimeZoneName*'
    }

    # A description is built from the AUTHORED step, before any variable is
    # resolved, so a token renders as itself. That is honest: the tree is
    # showing what the document says, and refresh.yaml really does declare
    # imageVersion as '%HDTOSImageVersion%'.
    It 'renders an unexpanded token as itself' {
        $step = & $script:newStep ([ordered] @{ imageVersion = '%HDTOSImageVersion%' })

        Get-HDTValidateStepDescription -Step $step | Should -BeLike '*Windows %HDTOSImageVersion%*'
    }

    It 'orders the parts by the table Order and not by the document' {
        $step = & $script:newStep ([ordered] @{ requireUefi = $true; minRamMB = 2048 })

        # minRamMB is Order 1, requireUefi is Order 3.
        Get-HDTValidateStepDescription -Step $step | Should -BeLike '*2048 MB memory, UEFI firmware*'
    }
}

# THE THREE SHIPPED TEMPLATES, DESCRIBED. These are the Validate steps a share
# is actually seeded with, so they are the lines an administrator sees in the
# tree on day one - and they are the examples in the function's own help.
Describe 'the shipped templates describe themselves' {

    It 'describes client.yaml' {
        $step = & $script:newStep ([ordered] @{ minRamMB = 2048; minDiskGB = 60 })

        Get-HDTValidateStepDescription -Step $step |
            Should -BeExactly 'Validate: 2048 MB memory, 60 GB disk, and one unambiguous target disk'
    }

    It 'describes reference.yaml' {
        $step = & $script:newStep ([ordered] @{ minRamMB = 2048; minDiskGB = 80 })

        Get-HDTValidateStepDescription -Step $step |
            Should -BeExactly 'Validate: 2048 MB memory, 80 GB disk, and one unambiguous target disk'
    }

    # THE ONE THAT WAS BROKEN. Three of these four keys were invisible before
    # the description walked the table, and allowOtherPartition: false is
    # correctly silent - the Refresh refuses another volume by default, so the
    # tick box being clear is the ordinary case and not worth a word.
    It 'describes refresh.yaml' {
        $step = & $script:newStep ([ordered] @{
                minRamMB            = 2048
                imageVersion        = '%HDTOSImageVersion%'
                imageSizeMB         = '%HDTOSImageSizeMB%'
                allowOtherPartition = $false
            })

        Get-HDTValidateStepDescription -Step $step |
            Should -BeExactly ('Validate: 2048 MB memory, Windows %HDTOSImageVersion%, ' +
                '%HDTOSImageSizeMB% MB image, and one unambiguous target disk')
    }

    It 'says so when a Refresh was told another volume is deliberate' {
        $step = & $script:newStep ([ordered] @{ minRamMB = 2048; allowOtherPartition = $true })

        Get-HDTValidateStepDescription -Step $step | Should -BeLike '*any volume*'
    }
}

Describe 'a step that declares nothing' {

    It 'still describes the check it always makes' {
        $script:baseline | Should -BeExactly 'Validate: one unambiguous target disk'
    }
}

}
