@{
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning')
    # PSReviewUnusedParameter IS OFF BECAUSE IT CANNOT BE ANSWERED HERE, not
    # because its 30 hits were inconvenient. Every one of them is a parameter a
    # SIGNATURE imposes and the body does not need:
    #
    #   [RoutedEventHandler] { param($raiser, $lost) }   WPF passes both
    #   ShowEditor($Xaml, $Title, ..., $Size)            a stand-in must match
    #                                                    the real method's arity
    #                                                    or it is not a stand-in
    #   $wireRuleTab = { param(..., $IsBootstrap) }      one call site serving
    #                                                    rules.yaml AND
    #                                                    bootstrap-rules.yaml
    #
    # AND THERE IS NOWHERE TO PUT THE SUPPRESSION. Verified against
    # PSScriptAnalyzer 1.25.0, all four placements:
    #
    #   above the function                        no effect
    #   in the function's param block, named      no effect
    #   in the function's param block, empty      works - own parameters only
    #   in a SCRIPTBLOCK's param block            no effect, named or empty
    #
    # The one form that does reach a scriptblock is a script-level
    # [SuppressMessage] over a top-level param(), and that is unavailable to
    # anything under src\: Hephaestus.bundle.ps1 is 377 sources concatenated,
    # param() must be a script's first statement, and mid-bundle it is
    # "Unexpected attribute" - a module that will not parse.
    #
    # So the choice was this line or 25 `$null = $raiser` statements written to
    # quiet a linter. Those would make the console harder to read AND still not
    # catch a genuinely unused parameter, because the rule cannot see into a
    # scriptblock either way.
    ExcludeRules        = @('PSReviewUnusedParameter')

    Rules               = @{
        # Second, independent layer of the PowerShell 5.1 constraint: this flags
        # PS7-only syntax such as ?? as an Error. The AST contract test in plan
        # 01-02 is the first layer.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
