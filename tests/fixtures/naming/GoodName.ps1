# Fixture for Get-HDTSourceFunction and Test-HDTFunctionName. Every function
# here carries a valid Verb-HDTNoun name (DESIGN 15.1). Fixtures are excluded
# from Get-HDTSourceFile, so nothing here is scanned by the contract suites.
# Line numbers are asserted by tests/unit/Get-HDTSourceFunction.Tests.ps1 - do
# not reflow this file.

function Get-HDTThing {
    function Test-HDTNestedThing {
        Write-Output 'nested'
    }

    Test-HDTNestedThing
}

function ConvertTo-HDTReport {
    Write-Output 'report'
}

function New-HDTWorkspace {
    Write-Output 'workspace'
}
