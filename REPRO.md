# Branch: `repro/live_vue_mounted_race`

Reproduces a race in `live_vue`'s `async mounted()` lifecycle hook
where `this.vue` is set *after* awaiting the component import. A
LiveView patch arriving during that window calls `updated()` /
`reconnected()` / `destroyed()` against an undefined `this.vue` and
throws.

- Upstream: https://github.com/Valian/live_vue
- Fix PR (this branch's reference): _PR link goes here once filed_
- Bug surface: `deps/live_vue/assets/hooks.ts:13` — `async mounted()` sets
  `this.vue` on a line *after* `const component = await resolve(...)`

## Reproduce

```sh
git checkout repro/live_vue_mounted_race
mix setup
mix phx.server
```

Open `http://localhost:4000/race` with **DevTools → Console** open.

Expected output in the console:

```
TypeError: Cannot read properties of undefined (reading 'props')
    at _ViewHook.updated (.../live___vue.js:N:N)
    at _ViewHook.__updated (.../phoenix___live___view.js:N:N)
    at DOMPatch.trackAfter ...
    at DOMPatch.perform ...
    at _View.performPatch ...
```

The Vue island still renders ("tick: 1") because the bug is about
the lifecycle hook throwing, not rendering failing — but every
subsequent LiveView patch on the island throws too, eventually
breaking reactivity.

## What makes the race deterministic

Two collaborating triggers in this repo:

1. **`assets/vue/index.ts`** — wraps each `import.meta.glob(...)`
   factory in a `slow()` helper that adds 200 ms before the dynamic
   import resolves. This widens `mounted()`'s `await` window.
2. **`lib/phx_issue_repro_web/live/race_live.ex`** — schedules a
   prop update via `Process.send_after(self(), :tick, 0)` so a
   LiveView patch arrives *during* the slowed-down mount.

Without the slowdown, the race fires intermittently depending on
network and lazy-chunk load time. With it, the race fires every
load — which is what we want for a deterministic PR demo.

## Verify the fix

Point the `live_vue` dep at the fix branch in your local fork:

```elixir
# mix.exs
{:live_vue, path: "../live_vue"},   # path to your live_vue fork
                                    # checked out on fix branch
```

Then:

```sh
mix deps.clean live_vue --build
mix deps.get
mix phx.server
```

Re-open `/race`. The `TypeError` should be gone; the Vue island
still renders the tick prop. The 200 ms slowdown is still in
place — the bug just no longer fires because `this.vue` is now
initialised *before* the await, not after.

## Why a Phoenix repro and not just a hooks.test.ts test

The PR includes a `hooks.test.ts` regression test that catches the
same race with mocked promises. But a maintainer reading the PR
benefits from a *live-runtime* proof too — this branch is that:
clone, `mix setup`, see the actual `TypeError` in a real browser.
