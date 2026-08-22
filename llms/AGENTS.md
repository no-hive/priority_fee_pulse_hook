## Commit messages

When generating a commit message for this repo, follow Conventional
Commits and output only the message text (no explanation, no markdown
fences):

```
<type>(<scope>)!: <description>
```

- `type`: one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`,
  `test`, `build`, `ci`, `chore`, `revert`.
- `scope`: optional, lowercase, the affected area (e.g. `auth`,
  `contracts`). Omit rather than guess if unclear.
- `description`: imperative mood, no trailing period, ≤ 72 characters.
- Add `!` before the colon (and/or a `BREAKING CHANGE:` footer) for
  breaking changes.
- One logical change per commit.

Example: `feat(auth): add OAuth login support`

Full human-readable guide: the "Contribute" page in the docs.
