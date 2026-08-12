# Fixture: a PowerShell class alongside real functions.
#
# DESIGN 15.1 governs command names. A class member is not a command - it is a
# member of a service contract whose method names are fixed by that contract -
# so Get-HDTSourceFunction must report the functions here and nothing else.
#
# Line numbers are pinned by tests/unit/Get-HDTSourceFunction.Tests.ps1.
# Do not reflow this file.

class HDTFixtureService {

    [hashtable] $Store

    HDTFixtureService() {
        $this.Store = @{}
    }

    [bool] TestPath([string] $Path) {
        return $this.Store.ContainsKey($Path)
    }

    hidden [void] RecordSomething([string] $Name) {
        $this.Store[$Name] = $true
    }

    static [string] Describe() {
        return 'fixture'
    }
}

function New-HDTFixtureService {
    [CmdletBinding()]
    param()

    function Get-HDTFixtureNested {
        return 1
    }

    return [HDTFixtureService]::new()
}
