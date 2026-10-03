# Lint settings for windows/*.ps1. CI fails on any error or warning that is
# not excluded here.
#
# The excluded rules all fire on code that came from the PC launcher as-is.
# That file gets re-synced from the PC, so renaming its functions or rewriting
# its catch blocks here would turn every re-sync into a merge fight.
#   PSAvoidUsingWriteHost      interactive console scripts; Write-Host is the UI
#   PSUseApprovedVerbs         Clip-Line, Ensure-LiteLLMProxy, Apply-InferHubSeat
#   PSUseSingularNouns         Get-ProjectDirs, Get-ProjectEntries
#   PSAvoidUsingEmptyCatchBlock  best-effort console probes and health polls
#   PSReviewUnusedParameter    Sync-ModelPicker keeps -MainId for its callers
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        'PSAvoidUsingEmptyCatchBlock',
        'PSReviewUnusedParameter'
    )
}
