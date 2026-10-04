# Pester tests

Pester 5 tests for the Windows installer. Run them with:

```powershell
Invoke-Pester -Path tests/pester -Output Detailed            # Spec, Property, Metamorphic
Invoke-Pester -Path tests/pester -TagFilter E2E               # Windows only: real install
```

Tags follow `docs/specs/windows-package.md`: `Spec`, `Property`, `Metamorphic`, `E2E`.
None of them touch port 4000, the real PATH or the real `~/.claude`.
