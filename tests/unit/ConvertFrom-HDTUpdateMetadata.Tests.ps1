# Reading a Windows update package's own metadata, rather than its file name.
#
# THE FILE NAME IS NOT EVIDENCE, AND THESE TWO PACKAGES ARE THE PROOF. The
# Windows 11 24H2 cumulative update and the Windows Server 2025 cumulative
# update are BOTH called windows11.0-kb50941xx-x64_<sha>.msu. One of them is not
# for Windows 11 at all. A parser that read the name would file the server
# update under the client release and nothing downstream would ever notice.
#
# WHAT IS PARSED HERE IS A CompDB, and it is the real one: the fixtures beside
# this file were extracted on 2026-09-01 from the two .msu packages themselves
# (tests/fixtures/update/), not written by hand. A modern .msu is a WIM holding
# onepackage.AggregatedMetadata.cab, which holds one CompDB XML per package it
# carries - the cumulative update, and the servicing stack update bundled with
# it.
#
# THE HONEST LIMIT IS TESTED TOO, in 'what it refuses to claim' below: the
# Server package's @Product says "Desktop", exactly as the client's does. There
# is no product family in this file, so this command does not invent one.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/update'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:fixtureRoot -Filter '*.xml' -File)) {
        $script:fixture[$file.Name] = [System.IO.File]::ReadAllText($file.FullName)
    }

    # The two packages as they really arrive: a cumulative update plus the
    # servicing stack update bundled inside the same .msu.
    $script:client = [string[]] @($script:fixture['lcu-compdb-kb5094126.xml'], $script:fixture['ssu-compdb-kb5094135.xml'])
    $script:server = [string[]] @($script:fixture['lcu-compdb-kb5094125.xml'], $script:fixture['ssu-compdb-kb5094137.xml'])
    $script:standaloneSsu = [string[]] @($script:fixture['ssu-compdb-kb5094135.xml'])
}

Describe 'ConvertFrom-HDTUpdateMetadata' {

    Context 'the Windows 11 24H2 cumulative update' {

        It 'reads <Field> as <Expected>' -ForEach @(
            @{ Field = 'Kb';                Expected = 'KB5094126' }
            @{ Field = 'Kind';              Expected = 'CumulativeUpdate' }
            # The CompDB says amd64; every other document in this workspace says
            # x64, and a catalog that used both would never match itself.
            @{ Field = 'Architecture';      Expected = 'x64' }
            @{ Field = 'TargetVersion';     Expected = '10.0.26100.8655' }
            @{ Field = 'BaselineVersion';   Expected = '10.0.26100.1742' }
            @{ Field = 'PackageId';         Expected = 'Package_for_RollupFix~~amd64~~26100.8655.1.20' }
            # ge_release for the general-availability branch. Recorded, never
            # matched on - see 'what it refuses to claim'.
            @{ Field = 'SourceBranch';      Expected = 'ge_release_svc_prod1' }
            @{ Field = 'CreatedUtc';        Expected = '2026-06-06T15:27:32.51819Z' }
            @{ Field = 'BundledSsuKb';      Expected = 'KB5094135' }
            @{ Field = 'BundledSsuVersion'; Expected = '10.0.26100.8648' }
        ) {
            InModuleScope Hephaestus -Parameters @{ Document = $script:client; Field = $Field; Expected = $Expected } {
                param($Document, $Field, $Expected)

                (ConvertFrom-HDTUpdateMetadata -Document $Document).$Field | Should -BeExactly $Expected
            }
        }

        It 'splits the target version into the build and revision that matching uses' {
            InModuleScope Hephaestus -Parameters @{ Document = $script:client } {
                param($Document)

                $result = ConvertFrom-HDTUpdateMetadata -Document $Document

                $result.Build | Should -Be 26100
                $result.Revision | Should -Be 8655
            }
        }
    }

    Context 'the Windows Server 2025 cumulative update' {

        It 'reads <Field> as <Expected>' -ForEach @(
            @{ Field = 'Kb';            Expected = 'KB5094125' }
            @{ Field = 'TargetVersion'; Expected = '10.0.26100.32995' }
            # The one field that differs from the client package. An undocumented
            # Microsoft build-branch token, so it is recorded and warned on, never
            # matched.
            @{ Field = 'SourceBranch';  Expected = 'lt_release_svc_prod1' }
            @{ Field = 'BundledSsuKb';  Expected = 'KB5094137' }
        ) {
            InModuleScope Hephaestus -Parameters @{ Document = $script:server; Field = $Field; Expected = $Expected } {
                param($Document, $Field, $Expected)

                (ConvertFrom-HDTUpdateMetadata -Document $Document).$Field | Should -BeExactly $Expected
            }
        }

        It 'reads a revision in a different band from the client package' {
            InModuleScope Hephaestus -Parameters @{ Document = $script:server } {
                param($Document)

                (ConvertFrom-HDTUpdateMetadata -Document $Document).Revision | Should -Be 32995
            }
        }
    }

    Context 'what it refuses to claim' {

        It 'reports the same major build for both packages' {
            # THE REASON THE ADMINISTRATOR'S LABEL IS LOAD-BEARING. Both are
            # 26100. A build check cannot tell a server update from a client one,
            # which is why Import-HDTWindowsUpdate makes the release a parameter
            # rather than deriving it.
            InModuleScope Hephaestus -Parameters @{ Client = $script:client; Server = $script:server } {
                param($Client, $Server)

                (ConvertFrom-HDTUpdateMetadata -Document $Client).Build |
                    Should -Be (ConvertFrom-HDTUpdateMetadata -Document $Server).Build
            }
        }

        It 'exposes no product family and no edition, because the package carries neither' {
            # The Server package's CompDB says Product="Desktop", exactly as the
            # client's does. Reading it and calling it a product family would be
            # inventing a fact.
            InModuleScope Hephaestus -Parameters @{ Document = $script:server } {
                param($Document)

                $name = @((ConvertFrom-HDTUpdateMetadata -Document $Document).PSObject.Properties.Name)

                $name | Should -Not -Contain 'ProductFamily'
                $name | Should -Not -Contain 'Edition'
            }
        }
    }

    Context 'a standalone servicing stack update' {

        It 'is reported as a ServicingStackUpdate when that is all the package holds' {
            InModuleScope Hephaestus -Parameters @{ Document = $script:standaloneSsu } {
                param($Document)

                $result = ConvertFrom-HDTUpdateMetadata -Document $Document

                $result.Kind | Should -BeExactly 'ServicingStackUpdate'
                $result.Kb | Should -BeExactly 'KB5094135'
            }
        }

        It 'reports no bundled servicing stack update of its own' {
            InModuleScope Hephaestus -Parameters @{ Document = $script:standaloneSsu } {
                param($Document)

                (ConvertFrom-HDTUpdateMetadata -Document $Document).BundledSsuKb | Should -BeNullOrEmpty
            }
        }
    }

    Context 'refusal' {

        It 'refuses a document set that holds no CompDB' {
            InModuleScope Hephaestus {
                { ConvertFrom-HDTUpdateMetadata -Document @('<hello />') } |
                    Should -Throw -ExpectedMessage '*no CompDB*'
            }
        }

        It 'skips a document that is not XML rather than refusing the whole set' {
            # A REAL PACKAGE FORCED THIS. The Windows 11 cumulative update's
            # aggregated metadata cab carries a JSON manifest of MSIX workload
            # entities beside the CompDB cabs; the Server package carries none.
            # Throwing on it made every client package import with no metadata
            # while the server package read perfectly.
            InModuleScope Hephaestus -Parameters @{ Document = $script:client } {
                param($Document)

                $json = '{ "Entities": [ { "EntityName": "WindowsWorkload.SessionManager" } ] }'

                (ConvertFrom-HDTUpdateMetadata -Document (@($json) + @($Document))).Kb |
                    Should -BeExactly 'KB5094126'
            }
        }

        It 'still refuses a set whose only document is not XML' {
            # Skipping noise must not become hiding a package that said nothing:
            # with the JSON gone there is no CompDB, and that is still a refusal.
            InModuleScope Hephaestus {
                { ConvertFrom-HDTUpdateMetadata -Document @('not xml') } |
                    Should -Throw -ExpectedMessage '*no CompDB*'
            }
        }

        It 'ignores a model CompDB, which describes the build and not the update' {
            # A Windows 11 .msu carries modelcompdb.xml alongside the two that
            # matter; its Type is Build, not BuildUpdate, and reading it as the
            # package would report the wrong KB.
            InModuleScope Hephaestus -Parameters @{ Document = $script:client } {
                param($Document)

                $model = '<?xml version="1.0" encoding="utf-8"?><CompDB Revision="1" SchemaVersion="1.2" ' +
                    'Product="Desktop" OSVersion="10.0.26100.8655" BuildArch="amd64" ' +
                    'Name="Build~amd64~ModelCompDB~~" ReleaseType="Production" Type="Build" ' +
                    'xmlns="http://schemas.microsoft.com/embedded/2004/10/ImageUpdate"><Features /></CompDB>'

                $result = ConvertFrom-HDTUpdateMetadata -Document (@($model) + @($Document))

                $result.Kb | Should -BeExactly 'KB5094126'
            }
        }
    }
}
