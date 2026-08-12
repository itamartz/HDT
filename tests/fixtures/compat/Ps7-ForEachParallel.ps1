# Fixture: ForEach-Object -Parallel. Parses under 5.1, fails at run time there,
# so it has to be caught by AST inspection rather than by the parser.

1..2 | ForEach-Object -Parallel { $_ }
