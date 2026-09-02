# Change Notes

One file per user-visible change, added by the pull request that lands it.
`bun scripts/changes.ts check` validates them; `bun run ship` folds them into
the channel changelogs. Format and rules: RELEASING.md, "Change Notes".

```markdown
---
desktop: Choose Claude Fable 5.1 from the model picker
ios: same-as desktop
browser: Pick Claude Fable 5.1 in the model menu
---
```

Name the file after the change (`model-picker-fable.md`). Keys are `desktop`,
`ios`, `browser`; `same-as <app>` reuses another app's wording; `shipped:` is
written by the release tooling. This README is not a note.
