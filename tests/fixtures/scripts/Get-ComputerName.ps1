# A *user* extension script, deliberately without the HDT command prefix.
#
# DESIGN 15.1 governs HDT's own commands, and tests/fixtures/** is outside
# Get-HDTSourceFile, so this file is neither name-checked nor linted. It is the
# same shape samples/workspace/Scripts/Get-ComputerName.ps1 takes in plan 02-03,
# which is the contract every setFrom: script follows: it receives the resolved
# variables as -Variable and emits one object whose properties become variables.
param([System.Collections.IDictionary] $Variable)

[pscustomobject] @{ HDTComputerName = ('PC-' + $Variable['HDTSerialNumber']) }
