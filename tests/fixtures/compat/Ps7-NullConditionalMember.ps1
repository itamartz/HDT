# Fixture: PowerShell 7-only null-conditional member access. Unparseable under 5.1.
# The braced form is required: $a?.Length parses as a variable named 'a?'.

${HDTValue} = 'text'
${HDTValue}?.Length
