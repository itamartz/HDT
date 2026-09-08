#Requires -Modules Pester

# BAIT. This file violates on purpose, and nothing runs it.
#
# tests/contract/RealMachineFootprint.Contract.Tests.ps1 points its scanner here
# to prove the scanner still bites: an assertion that passes for a repository
# with no test files at all is not a contract.
#
# What it does wrong is the defect that took the first CI run on GHRUNNER01 red:
# proving "this fake-driven run wrote nothing real" by asserting that HDT's own
# path on a deployed machine does not exist. It exists on every machine HDT has
# deployed, and the gate now runs on one.

Describe 'a suite that proves a negative the wrong way' {

    It 'wrote no file to the real disk' {
        Test-Path -LiteralPath 'C:\HDT\Logs\HDT.jsonl' | Should -BeFalse
    }

    It 'left the autologon keys alone' {
        Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' |
            Select-Object -ExpandProperty AutoLogonCount -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}
