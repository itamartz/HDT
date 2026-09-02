# Get-HDTDeploymentMethod answers MDT's DeploymentMethod, and it is a different
# question from HDTDeploymentType.
#
# MDT's ZTIGather.xml line 10 declares DeploymentMethod - "the method being used
# for the deployment" - and LiteTouch.wsf lines 267-324 defaults it to UNC and
# sets MEDIA when it finds Media.tag on a ready drive. HDT decides the same thing
# from the provider the boot image already carries, so there is nothing to sniff
# for and nothing that can disagree with the provider actually in use.
#
# TWO VALUES, AND THERE ARE ONLY TWO. MDT also lists OSD and SCCM because MDT
# integrates with MECM; rule 4 forbids that dependency, so those are deliberately
# absent and this file asserts their absence rather than leaving it to a reader.
#
# The set-driven assertion is the one that matters: Resolve-HDTDeployRoot answers
# a question about the SAME enum, so every provider it accepts must have an
# answer here. A provider added there tomorrow fails in this file, which is how
# the two are kept from drifting.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTDeploymentMethod' {

    Context 'the two values, and there are only two' {

        It 'is exported by Hephaestus' {
            $manifest = Import-PowerShellDataFile -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1')

            @($manifest.FunctionsToExport) | Should -Contain 'Get-HDTDeploymentMethod'
            Get-Command -Name 'Get-HDTDeploymentMethod' -Module 'Hephaestus' -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }

        It 'answers MEDIA for the Local provider, because the content is on the thing the machine booted from' {
            Get-HDTDeploymentMethod -Provider 'Local' | Should -BeExactly 'MEDIA'
        }

        It 'answers UNC for the Smb provider, because the content is on a share' {
            Get-HDTDeploymentMethod -Provider 'Smb' | Should -BeExactly 'UNC'
        }

        It 'answers one of exactly two values for every provider Resolve-HDTDeployRoot accepts' {
            # Against the SET, not against two literals. Both commands answer a
            # question about the same enum; a third provider added to
            # Resolve-HDTDeployRoot has to be answered here too, and this is
            # where it is noticed.
            $attribute = @((Get-Command -Name 'Resolve-HDTDeployRoot').Parameters['Provider'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })

            $attribute.Count | Should -Be 1
            @($attribute[0].ValidValues).Count | Should -BeGreaterThan 0

            foreach ($provider in @($attribute[0].ValidValues)) {
                $answer = Get-HDTDeploymentMethod -Provider $provider
                @('UNC', 'MEDIA') | Should -Contain $answer -Because ('Resolve-HDTDeployRoot accepts the provider {0}, so Get-HDTDeploymentMethod must answer it with UNC or MEDIA and nothing else' -f $provider)
            }
        }

        It 'refuses a provider name that is neither, rather than guessing UNC' {
            # The expected message is the ValidateSet one deliberately. A bare
            # -Throw here passes while the command does not exist at all, which
            # is a test that proves nothing until it is too late to notice.
            { Get-HDTDeploymentMethod -Provider 'Http' } |
                Should -Throw -ExpectedMessage '*does not belong to the set*'
        }

        It 'refuses OSD and SCCM outright - those are MECM''s and HDT does not integrate with it' {
            foreach ($mecm in @('OSD', 'SCCM')) {
                { Get-HDTDeploymentMethod -Provider $mecm } |
                    Should -Throw -ExpectedMessage '*does not belong to the set*'
            }
        }

        It 'reads the provider case-insensitively, as bootstrap.json is read everywhere else' {
            Get-HDTDeploymentMethod -Provider 'local' | Should -BeExactly 'MEDIA'
            Get-HDTDeploymentMethod -Provider 'SMB' | Should -BeExactly 'UNC'
        }
    }

    Context 'what it says about itself' {

        It 'has comment-based help naming both values and both MECM values it does not have' {
            $help = Get-Help -Name 'Get-HDTDeploymentMethod' -Full

            $help.Synopsis | Should -Not -BeNullOrEmpty
            $description = ($help.Description | Out-String)

            $description | Should -Match 'UNC'
            $description | Should -Match 'MEDIA'
            $description | Should -Match 'SCCM'
            $description | Should -Match 'HDTDeploymentType'
        }
    }
}
