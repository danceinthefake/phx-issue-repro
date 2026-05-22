# phx-issue-repro

A reusable Phoenix scaffold for reproducing upstream library bugs.
Each bug lives on its own branch.

## How it works

`main` is the bare Phoenix + LiveView scaffold (no Ecto, no Mailer,
no Tailwind, no Gettext). Each bug report has a dedicated
`repro/<slug>` branch that:

- Adds whatever deps the bug needs (`mix.exs` + `package.json`)
- Includes the minimum code that triggers the bug
- Carries its own branch-level `README.md` describing the symptom,
  the reproduction steps, and the link to the upstream issue / PR

Keeping `main` minimal means new repros start from a clean slate
instead of inheriting dead deps from older bugs.

## Run a repro

```sh
git checkout repro/<slug>
mix setup
mix phx.server
# open http://localhost:4000 and follow the branch README
```

## Add a new repro

```sh
git checkout -b repro/<short-slug> main
# add the deps you need, the minimal code that triggers the bug,
# and a branch-level README.md explaining how to reproduce.
git commit -am "repro: <bug summary>"
git push -u origin repro/<short-slug>
```

## Available branches

| Branch | Bug | Upstream |
|---|---|---|
| `repro/live_vue_mounted_race` | live_vue's `async mounted()` sets `this.vue` after awaiting the component import; a LiveView patch during that window throws against undefined `this.vue` | _PR link goes here once filed_ |
