BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    Import-Module -Name $script:manifestPath -Force -ErrorAction Stop
}

Describe 'Test-HDTSchemaVersion' {

    It 'accepts a schemaVersion equal to the supported version' {
        InModuleScope -ModuleName Hephaestus {
            Test-HDTSchemaVersion -SchemaVersion 1 -Supported 1
        } | Should -BeTrue
    }

    It 'accepts an older schemaVersion' {
        InModuleScope -ModuleName Hephaestus {
            Test-HDTSchemaVersion -SchemaVersion 1 -Supported 2
        } | Should -BeTrue
    }

    It 'rejects a schemaVersion newer than supported' {
        InModuleScope -ModuleName Hephaestus {
            Test-HDTSchemaVersion -SchemaVersion 3 -Supported 2
        } | Should -BeFalse
    }

    It 'throws on a schemaVersion below 1' {
        {
            InModuleScope -ModuleName Hephaestus {
                Test-HDTSchemaVersion -SchemaVersion 0 -Supported 1
            }
        } | Should -Throw -ExpectedMessage '*schemaVersion*'
    }

    It 'declares SchemaVersion as a mandatory parameter' {
        InModuleScope -ModuleName Hephaestus {
            $command = Get-Command -Name Test-HDTSchemaVersion
            $attribute = $command.Parameters['SchemaVersion'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            @($attribute).Mandatory | Should -Contain $true
        }
    }

    It 'declares Supported as a mandatory parameter' {
        InModuleScope -ModuleName Hephaestus {
            $command = Get-Command -Name Test-HDTSchemaVersion
            $attribute = $command.Parameters['Supported'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            @($attribute).Mandatory | Should -Contain $true
        }
    }

    It 'returns a plain boolean, not a truthy object' {
        InModuleScope -ModuleName Hephaestus {
            $actual = Test-HDTSchemaVersion -SchemaVersion 1 -Supported 1
            $actual -is [bool]
        } | Should -BeTrue
    }
}
