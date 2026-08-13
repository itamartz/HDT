# A PowerShell step script - a USER extension point, not an HDT command.
#
# DESIGN 15.1's Verb-HDTNoun rule governs HDT's own commands. A script in a
# customer's workspace is theirs to name, so this one deliberately carries no HDT
# prefix, and samples/ sits outside Get-HDTSourceFile precisely so the naming
# contract does not claim it.
#
# The contract a PowerShell step script honours:
#
#   * it takes one parameter, the current variable scope, as an IDictionary;
#   * anything it writes to the standard streams - Write-Host included - is
#     captured into the step's own log (DESIGN 4.4.4), because real fleets carry
#     years of Write-Host scripts and rewriting them is not an option;
#   * what it emits becomes the step result's Data.
#
# The engine never runs this file directly: it calls it through an IScriptInvoker,
# which is what lets the step be tested without executing anything.

param([System.Collections.IDictionary] $Variable)

Write-Host ('applying corporate baseline to {0}' -f $Variable['HDTComputerName'])
