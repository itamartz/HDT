# The Tattoo step stamps the deployed machine with what built it.
#
# MDT'S ZTITatoo, AND IT EXISTS FOR THE REASON MDT'S DOES: six months after a
# deployment somebody is standing at the machine asking which task sequence made
# it, from which share, and when. The log is on a share, in a folder named after
# a computer that may since have been renamed; the registry is on the machine
# they are already looking at.
#
# THE ENGINE ALREADY EXPECTED THIS STEP. New-HDTExecutionContext refreshes
# HDTDeploymentEnd before every step and its comment says why: "a tattoo is the
# last step, so what it reads IS the end". Get-HDTVariableMap carries
# HDTTaskSequenceName and HDTTaskSequenceVersion with Origin = 'engine', which
# is the lookup PSDTattoo.ps1 has to go back to the share for.
#
# IT WRITES THROUGH IRegistryService (rule 5). Everything below runs against the
# hand-written fake, so the assertions are about which values a machine ends up
# carrying rather than about a registry somebody has to go and inspect.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:defaultPath = 'HKLM:\SOFTWARE\Hephaestus\Deployment'

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{ Index = 12; Name = $Name; Type = 'Tattoo'; Property = $bag }
    }

    # What the machine ended up carrying: value name to value, off the fake.
    $script:written = {
        param($Registry, [string] $Path)

        $wanted = $Path
        if ([string]::IsNullOrWhiteSpace($wanted)) { $wanted = $script:defaultPath }

        $map = @{}

        foreach ($operation in @($Registry.Operations | Where-Object { $_.Operation -eq 'SetValue' })) {
            if ([string] $operation.Arguments[0] -ne $wanted) { continue }
            $map[[string] $operation.Arguments[1]] = $operation.Arguments[2]
        }

        return $map
    }

    # A REGISTRY THAT REFUSES, hand-written like every other fake here. It
    # records what it was asked for so the assertions can be about the attempt,
    # which is the only thing there is to assert when the write never lands.
    $script:newRefusingRegistry = {
        param([string] $Message)

        $refusing = [pscustomobject] @{ Operations = (New-Object -TypeName System.Collections.ArrayList) }
        $refusing | Add-Member -MemberType NoteProperty -Name Refusal -Value $Message

        $refusing | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
            return [string[]] @('NewKey', 'SetValue')
        }

        $refusing | Add-Member -MemberType ScriptMethod -Name NewKey -Value {
            param([string] $Path)

            [void] $this.Operations.Add([pscustomobject] @{ Operation = 'NewKey'; Arguments = @($Path) })

            throw [System.UnauthorizedAccessException]::new($this.Refusal)
        }

        $refusing | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
            param([string] $Path, [string] $Name, [object] $Value, [string] $Type)

            [void] $this.Operations.Add([pscustomobject] @{
                    Operation = 'SetValue'; Arguments = @($Path, $Name, $Value, $Type)
                })

            throw [System.UnauthorizedAccessException]::new($this.Refusal)
        }

        return $refusing
    }

    $script:jsonlRecord = {
        param($FileSystem)

        $text = ''
        if ($FileSystem.File.ContainsKey('C:\HDT\Logs\HDT.jsonl')) {
            $text = [string] $FileSystem.File['C:\HDT\Logs\HDT.jsonl']
        }

        return @(@($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
                ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'Invoke-HDTTattooStep' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 21, 20, 41, 7, [System.DateTimeKind]::Utc))
        $script:registry = New-HDTFakeRegistryService
        $script:catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
            -Registry $script:registry
        $script:log = New-HDTLogContext -RunId 'run-20260821-194757' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock

        # A real resolved set off the lab run: DEMO-05 on the SMB share.
        $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:variable['HDTComputerName'] = 'PC-FIXTURE-0001'
        $script:variable['HDTDeployRoot'] = '\\192.168.2.42\HDTShare'
        $script:variable['HDTTaskSequenceID'] = 'DEMO-05'
        $script:variable['HDTTaskSequenceName'] = 'Standard Client'
        $script:variable['HDTTaskSequenceVersion'] = '1.4'
        $script:variable['HDTDeploymentType'] = 'NEWCOMPUTER'
        $script:variable['HDTDeploymentStart'] = '2026-08-21T19:47:57Z'
        $script:variable['HDTDeploymentEnd'] = '2026-08-21T20:41:07Z'
        $script:variable['HDTMake'] = 'Microsoft Corporation'
        $script:variable['HDTModel'] = 'Virtual Machine'
        $script:variable['HDTSerialNumber'] = 'FIXTURE-SERIAL-0001'

        $script:context = New-HDTExecutionContext -RunId 'run-20260821-194757' -Phase FullOS `
            -WorkspaceRoot '\\192.168.2.42\HDTShare' -Variable $script:variable -Service $script:catalog -Log $script:log
    }

    Context 'the key' {

        It 'writes under HKLM:\SOFTWARE\Hephaestus\Deployment by default' {
            # NOT HKLM:\SOFTWARE\Microsoft\Deployment 4, which is where MDT's
            # tattoo lands. Rule 4: HDT does not write into another product's
            # key, and a machine carrying both must be readable as both.
            $result = Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:context

            [string] $result.Status | Should -BeExactly 'Completed'
            $script:registry.TestPath($script:defaultPath) | Should -BeTrue
        }

        It 'creates the key before it writes into it' {
            # New-ItemProperty fails on a key that does not exist.
            Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:context | Out-Null

            $operation = @($script:registry.Operations | Where-Object { $_.Operation -in @('NewKey', 'SetValue') })

            [string] $operation[0].Operation | Should -BeExactly 'NewKey'
        }

        It 'takes a path from the step' {
            $step = & $script:newStep 'Tattoo' ([ordered] @{ path = 'HKLM:\SOFTWARE\Contoso\Build' })

            Invoke-HDTTattooStep -Step $step -Context $script:context | Out-Null

            $script:registry.TestPath('HKLM:\SOFTWARE\Contoso\Build') | Should -BeTrue
            $script:registry.TestPath($script:defaultPath) | Should -BeFalse
        }

        It 'expands variable tokens in the path' {
            $step = & $script:newStep 'Tattoo' ([ordered] @{ path = 'HKLM:\SOFTWARE\Contoso\%HDTTaskSequenceID%' })

            Invoke-HDTTattooStep -Step $step -Context $script:context | Out-Null

            $script:registry.TestPath('HKLM:\SOFTWARE\Contoso\DEMO-05') | Should -BeTrue
        }
    }

    Context 'what it stamps' {

        BeforeEach {
            Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:context | Out-Null
            $script:value = & $script:written $script:registry $script:defaultPath
        }

        It 'writes the computer name and the share it came from' {
            [string] $script:value['ComputerName'] | Should -BeExactly 'PC-FIXTURE-0001'
            [string] $script:value['DeployRoot'] | Should -BeExactly '\\192.168.2.42\HDTShare'
        }

        It 'writes the task sequence that built it' {
            # THE THREE PSDTattoo HAD TO GO BACK TO THE SHARE FOR. HDT resolves
            # name and version into the variable set when the sequence is
            # imported, so the step reads them like everything else.
            [string] $script:value['TaskSequenceID'] | Should -BeExactly 'DEMO-05'
            [string] $script:value['TaskSequenceName'] | Should -BeExactly 'Standard Client'
            [string] $script:value['TaskSequenceVersion'] | Should -BeExactly '1.4'
        }

        It 'writes the deployment type' {
            [string] $script:value['DeploymentType'] | Should -BeExactly 'NEWCOMPUTER'
        }

        It 'writes both ends of the deployment' {
            [string] $script:value['DeploymentStart'] | Should -BeExactly '2026-08-21T19:47:57Z'
            [string] $script:value['DeploymentEnd'] | Should -BeExactly '2026-08-21T20:41:07Z'
        }

        It 'writes how long it took' {
            # The subtraction New-HDTExecutionContext's comment describes:
            # 19:47:57 to 20:41:07 is 53 minutes and 10 seconds.
            [string] $script:value['DeploymentDuration'] | Should -BeExactly '00:53:10'
        }

        It 'writes the run id, so the log is findable' {
            [string] $script:value['RunId'] | Should -BeExactly 'run-20260821-194757'
        }

        It 'writes the hardware it landed on' {
            [string] $script:value['Make'] | Should -BeExactly 'Microsoft Corporation'
            [string] $script:value['Model'] | Should -BeExactly 'Virtual Machine'
            [string] $script:value['SerialNumber'] | Should -BeExactly 'FIXTURE-SERIAL-0001'
        }

        It 'writes the engine version that did it' {
            [string] $script:value['EngineVersion'] | Should -Not -BeNullOrEmpty
        }

        It 'writes every value as a string' {
            # A tattoo is read by people and by inventory tools that expect
            # REG_SZ. MDT's is strings and so is PSD's.
            $type = @($script:registry.Operations |
                    Where-Object { $_.Operation -eq 'SetValue' } |
                    ForEach-Object { [string] $_.Arguments[3] } |
                    Select-Object -Unique)

            $type | Should -Be @('String')
        }
    }

    Context 'a value that never resolved' {

        It 'writes it empty rather than leaving it out' {
            # A KEY MISSING A VALUE READS AS "THE TATTOO DID NOT RUN". An empty
            # TaskSequenceVersion is a fact about the sequence; an absent one is
            # a question about the step.
            $script:variable.Remove('HDTTaskSequenceVersion')

            Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:context | Out-Null

            $value = & $script:written $script:registry $script:defaultPath

            $value.ContainsKey('TaskSequenceVersion') | Should -BeTrue
            [string] $value['TaskSequenceVersion'] | Should -BeExactly ''
        }

        It 'says which ones were empty' {
            $script:variable.Remove('HDTTaskSequenceVersion')
            $script:variable.Remove('HDTModel')

            Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:context | Out-Null

            $warning = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.level -eq 'Warning' -and $_.component -eq 'Tattoo' })

            @($warning).Count | Should -BeGreaterOrEqual 1
            [string] $warning[0].message | Should -BeLike '*TaskSequenceVersion*'
            [string] $warning[0].message | Should -BeLike '*Model*'
        }

        It 'leaves the duration empty when it cannot subtract' {
            $script:variable['HDTDeploymentStart'] = ''

            Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:context | Out-Null

            [string] (& $script:written $script:registry $script:defaultPath)['DeploymentDuration'] |
                Should -BeExactly ''
        }
    }

    Context 'values the sequence adds' {

        It 'writes the extras it is given' {
            $step = & $script:newStep 'Tattoo' ([ordered] @{
                    values = [ordered] @{ Site = 'HQ'; Rack = 'B12' }
                })

            Invoke-HDTTattooStep -Step $step -Context $script:context | Out-Null

            $value = & $script:written $script:registry $script:defaultPath

            [string] $value['Site'] | Should -BeExactly 'HQ'
            [string] $value['Rack'] | Should -BeExactly 'B12'
        }

        It 'expands variable tokens in them' {
            $step = & $script:newStep 'Tattoo' ([ordered] @{
                    values = [ordered] @{ BuiltBy = 'HDT on %HDTComputerName%' }
                })

            Invoke-HDTTattooStep -Step $step -Context $script:context | Out-Null

            [string] (& $script:written $script:registry $script:defaultPath)['BuiltBy'] |
                Should -BeExactly 'HDT on PC-FIXTURE-0001'
        }

        It 'lets an extra override a standard value, and says so' {
            # The site knows better than the engine sometimes - but silently
            # replacing TaskSequenceName would make the tattoo lie about which
            # sequence ran, so the substitution is a line in the log.
            $step = & $script:newStep 'Tattoo' ([ordered] @{
                    values = [ordered] @{ TaskSequenceName = 'Standard Client (rebuilt)' }
                })

            Invoke-HDTTattooStep -Step $step -Context $script:context | Out-Null

            [string] (& $script:written $script:registry $script:defaultPath)['TaskSequenceName'] |
                Should -BeExactly 'Standard Client (rebuilt)'

            $warning = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.level -eq 'Warning' -and $_.message -like '*TaskSequenceName*' })

            @($warning).Count | Should -BeGreaterOrEqual 1
        }
    }

    Context 'when the registry will not have it' {

        BeforeEach {
            $script:refusing = & $script:newRefusingRegistry 'Requested registry access is not allowed.'

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Registry $script:refusing
            $script:refusedContext = New-HDTExecutionContext -RunId 'run-20260821-194757' -Phase FullOS `
                -WorkspaceRoot 'C:\HDT' -Variable $script:variable -Service $catalog -Log $script:log
        }

        It 'is a failed step rather than a throw' {
            # The loop decides what a failed step means. A machine that is
            # otherwise deployed must not be ended by a stamp it could not write.
            $result = Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:refusedContext

            [string] $result.Status | Should -BeExactly 'Failed'
            [string] $result.Message | Should -BeLike '*not allowed*'
        }

        It 'names the key it could not write in the message' {
            $result = Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:refusedContext

            [string] $result.Message | Should -BeLike '*HKLM:\SOFTWARE\Hephaestus\Deployment*'
        }

        It 'records the failure as a step.fail on the run log' {
            Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:refusedContext | Out-Null

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.event -eq 'step.fail' -and $_.component -eq 'Tattoo' })

            @($record).Count | Should -Be 1
        }
    }

    Context 'what it reports' {

        It 'names the key and the count it wrote' {
            $result = Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:context

            [string] $result.Message | Should -BeLike '*HKLM:\SOFTWARE\Hephaestus\Deployment*'
            [string] $result.Message | Should -Match '\d+'
        }

        It 'puts every value it wrote on one log record' {
            # So the tattoo is readable from the deployment log without going to
            # the machine - which is the case a technician has when the machine
            # is already back on somebody's desk.
            Invoke-HDTTattooStep -Step (& $script:newStep 'Tattoo' $null) -Context $script:context | Out-Null

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { $_.component -eq 'Tattoo' -and $null -ne $_.data -and
                        $null -ne $_.data.PSObject.Properties['value'] })

            @($record).Count | Should -BeGreaterOrEqual 1
            [string] $record[0].data.value.TaskSequenceID | Should -BeExactly 'DEMO-05'
        }
    }
}

Describe 'Get-HDTTattooStepDescription' {

    It 'names the key the step will stamp' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['path'] = 'HKLM:\SOFTWARE\Contoso\Build'
        $step = [pscustomobject] @{ Index = 12; Name = 'Tattoo'; Type = 'Tattoo'; Property = $bag }

        Get-HDTTattooStepDescription -Step $step | Should -BeExactly 'Tattoo: HKLM:\SOFTWARE\Contoso\Build'
    }

    It 'names the default key when the step named none' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $step = [pscustomobject] @{ Index = 12; Name = 'Tattoo'; Type = 'Tattoo'; Property = $bag }

        Get-HDTTattooStepDescription -Step $step | Should -BeExactly 'Tattoo: HKLM:\SOFTWARE\Hephaestus\Deployment'
    }
}

Describe 'Get-HDTTattooStepTemplate' {

    It 'writes a step that runs with nothing filled in' {
        # THE WHOLE POINT OF THE TYPE IS THAT IT NEEDS NO ARGUMENTS. Everything
        # it stamps is already resolved, so a template that demanded a path
        # would be asking for the one thing nobody wants to change.
        $line = @(Get-HDTTattooStepTemplate)

        $line[0] | Should -BeExactly '- name: Tattoo'
        $line | Should -Contain '  type: Tattoo'
    }

    It 'takes the name it is offered under' {
        @(Get-HDTTattooStepTemplate -Name 'Stamp the machine')[0] | Should -BeExactly '- name: Stamp the machine'
    }
}
