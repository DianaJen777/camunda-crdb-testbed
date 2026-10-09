# RUNLOG

Append-only audit trail. Every command that matters gets an entry.
Never edit or delete prior entries — if something was wrong, append a correction.

This is the proof behind every number in `results/`. If a finding is ever
challenged by Camunda or internally, this is what substantiates it.

## Format

```
## <ISO-8601 UTC timestamp> — <phase> — <what you did>
Command: <exact command, copy-pasteable>
Exit code: <n>
Outcome: <what actually happened, including verbatim errors>
Artefacts: <paths written>
```

---
