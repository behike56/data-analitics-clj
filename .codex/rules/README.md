# Codex common execpolicy rules

This directory is the distribution source for common Codex `.rules` files.
After distribution, place these files under the project-local `.codex/rules/`
directory.

```text
.codex_common/rules/*.rules  ->  <project>/.codex/rules/*.rules
```

Codex loads every `.rules` file under `rules/` for each active config layer at
startup. If multiple rules match the same command, the strictest decision wins:

```text
forbidden > prompt > allow
```

## Design policy

- Keep `allow` narrow.
- Prefer `prompt` for commands that can mutate repository state, access
  network-backed private data, or execute project-selected code.
- Do not allow broad file readers such as `cat`, `find`, `sed`, or `python`.
- Keep stronger `forbidden` rules in `.codex_secure/rules/`, not here.

## Files

- `default.rules`: minimal low-risk allow rules.
- `repository-inspection.rules`: broader Git inspection commands that should
  remain visible to the user.
- `repository-mutations.rules`: Git commands that change working tree, refs, or
  remote state.
- `github.rules`: GitHub CLI commands.
- `verification.rules`: test and lint commands that execute project code.

## Verification

Use `codex execpolicy check` with all files you plan to distribute:

```bash
codex execpolicy check --pretty \
  --rules .codex_common/rules/default.rules \
  --rules .codex_common/rules/repository-inspection.rules \
  --rules .codex_common/rules/repository-mutations.rules \
  --rules .codex_common/rules/github.rules \
  --rules .codex_common/rules/verification.rules \
  -- git status
```

Restart Codex after adding or changing `.rules` files.
