# sources/

Drop your application source repositories into this folder. They appear in
the UI's "+ New project" dropdown automatically.

```
sources/
├── README.md            ← (this file, ignored)
├── hiriskpro/           ← your cloned repo
├── another-app/         ← any number of repos
└── ...
```

The framework reads from here read-only — it never modifies your code.
Project state (state.yaml, generated IaC, deploy outputs) lives in the
sibling `projects/` folder, separate from your source.
