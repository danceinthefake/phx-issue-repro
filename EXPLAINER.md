# The `live_vue` mounted-race bug, explained

A long-form walkthrough of the bug this branch reproduces, for
people who know Phoenix LiveView well but haven't gone deep into
Vue or live_vue internals. If you just want to *see* the bug, see
`REPRO.md`. If you want to know *why* it happens, read on.

---

## The 30-second version

`live_vue`'s `mounted()` JS hook is `async`. It awaits the Vue
component module to load before storing per-island state on
`this.vue`. If Phoenix LiveView sends an update during that
await window, the hook's `updated()` callback fires and reads
`this.vue.props` — but `this.vue` is still `undefined`, so it
throws and the patch is silently dropped. The fix is one block
of code moved above the `await`.

## Cast of characters

You already know Phoenix LiveView. The unfamiliar pieces:

### Vue "island"

A small piece of Vue rendered inside an otherwise-LiveView page.
In your HEEx template it looks like:

```heex
<.vue tick={@tick} v-component="Hello" />
```

That `<.vue ...>` macro is provided by `live_vue`. It expands to
a `<div>` with attributes that tell the browser *"hydrate a Vue
component named `Hello` here, with these props."*

### `live_vue`

The glue between Phoenix LiveView and Vue. It does three jobs:

1. **Render Vue server-side** so the page's first HTML already
   contains the Vue island markup (good for first paint, SEO,
   no FOUC).
2. **Wire LiveView's prop-diff stream to Vue's reactive props**
   so when you `assign(socket, :tick, @tick + 1)` in Elixir, the
   `tick` prop in the Vue component updates without a full
   re-render.
3. **Host a Phoenix LiveView JS Hook** that does the actual
   wiring on the client.

That last one is where the bug lives.

### Phoenix LiveView JS Hooks (refresher)

LiveView lets you attach JavaScript "hooks" to DOM elements. A
hook is an object with named callbacks for points in the
element's lifecycle:

```javascript
const VueHook = {
  mounted() { /* element just got inserted in DOM */ },
  updated() { /* LiveView server sent a patch affecting this element */ },
  reconnected() { /* the websocket reconnected */ },
  destroyed() { /* element about to leave the DOM */ },
}
```

`live_vue` registers a `VueHook` like this for every `<div>` it
renders for an island. **The same hook object's callbacks fire
across the whole lifecycle of one island, sharing `this`.**

That `this` is per-island and is where each callback expects to
find state set up by `mounted()`. Specifically, every callback
after `mounted()` reads `this.vue`.

## What `this.vue` is, and why it matters

Inside `live_vue`'s hook, `this.vue` is set to an object with
three fields:

```typescript
this.vue = {
  props: reactive({ tick: 0 }),   // a Vue 3 reactive object
  slots: reactive({}),             // a Vue 3 reactive object for slots
  app: null,                       // the Vue app instance, filled in later
}
```

Two things to notice:

- **`props` is a Vue 3 *reactive object*.** Mutating it (e.g.
  `props.tick = 1`) is what triggers Vue to re-render the
  component. Setting it once and mutating thereafter is the
  whole "reactivity" trick.
- **`app` is `null` until the Vue app has actually been
  constructed.** It only gets a real value after the component
  module finishes loading.

`updated()` (the LiveView callback that runs when the server
sends a patch) does roughly this:

```typescript
updated() {
  // Take the prop-diff that just arrived and apply it to the
  // reactive props object. Vue's reactivity engine sees the
  // mutation and re-renders the component.
  applyPatch(this.vue.props, getDiff(this.el, "data-props-diff"))
}
```

That's the line that throws when `this.vue` is `undefined`:

```
TypeError: Cannot read properties of undefined (reading 'props')
    at _ViewHook.updated (.../live___vue.js:N:N)
```

So the question is: **how can `updated()` ever run before
`mounted()` has finished setting `this.vue`?**

The answer is `async mounted()` + lazy imports.

## What "lazy globs" are (the Vite piece)

Vite (the build tool live_vue uses) has a feature called
`import.meta.glob`. It scans the filesystem for matching files
and gives you back an object you can iterate. There are two
flavours:

```typescript
// Eager — every file is bundled into the entry chunk.
// Resolver returns the components synchronously.
import.meta.glob("./**/*.vue", { eager: true })
// → { "./Hello.vue": <module>, "./World.vue": <module>, ... }

// Lazy — each file becomes its own dynamic-import chunk.
// Resolver returns *factories* you call to load on demand.
import.meta.glob("./**/*.vue")  // implicitly { eager: false }
// → { "./Hello.vue": () => import("./Hello.vue"), ... }
```

The lazy form is what you use to **code-split** — large
components only load when needed, the initial bundle stays
small. Vite's own docs recommend this for any app with
non-trivial component count, and `live_vue` was designed to
support it (the resolver's type signature allows
`Promise<Component>` values).

When `live_vue`'s `mounted()` calls `resolve(componentName)`
with eager globs, the resolver returns the component
synchronously — the `await` is awaiting a non-promise, which
resolves on the next microtask (effectively zero delay). When
the consumer switches to lazy globs, the resolver returns a
real `Promise` that may take **tens to hundreds of
milliseconds** to resolve (network for the chunk, parse, eval).

That delay is the race window.

## The race, frame by frame

Here's a single chamber mount, step by step. **T0** is the
moment `mounted()` first runs.

| Time | Event |
|---|---|
| **T+0 ms** | LiveView inserts the `<div data-name="Hello">` into the DOM and calls `mounted()` on `VueHook`. |
| **T+0 ms** | `mounted()` starts running synchronously: reads `componentName = "Hello"` from the element. |
| **T+0 ms** | `mounted()` hits `const component = await resolve("Hello")`. With lazy globs, `resolve()` returns `() => import("./Hello.vue")`'s result — a Promise that needs ~50 ms to fetch the chunk, parse, and resolve. **`mounted()` suspends.** |
| **T+0 ms** | Synchronously, **LiveView finishes its initial render and processes the very first prop-diff stream from the server.** That diff includes a "tick: 0 → tick: 1" delta because RaceLive sent itself `:tick` via `Process.send_after(self(), :tick, 0)` and the server consolidated the patch into the initial push. |
| **T+0 ms** | LiveView walks all hooks on patched elements and calls `updated()` on each. **`VueHook.updated()` runs.** It tries `applyPatch(this.vue.props, …)`. **`this.vue` is `undefined`.** TypeError thrown. Patch dropped. |
| **T+50 ms** | The lazy import resolves. `mounted()` resumes after its await. Sets `this.vue = { props, slots, app: null }`. Builds the Vue app. Mounts it. Component renders. |
| **T+50 ms** | The component renders with `props.tick === 0` (the *initial* value baked into the server-rendered HTML), not `1` (the patched value that got dropped). |
| **T+51 ms** | Vue logs: `[Vue warn] Hydration text content mismatch — server rendered: tick: 0, client expected: tick: 1`. |

You see the end state in the screenshots in `REPRO.md`: the
component renders, but the value is stale by exactly the
dropped patch. To the user, it looks like the LiveView push
"didn't go through". The error is in the JS console — easy to
miss in production.

The bug happens **on every island whose await window overlaps
any LiveView patch**. With slow connections, mobile, or many
fast server-side pushes, the window keeps opening.

## The fix in plain English

The original `mounted()`:

```typescript
async mounted() {
  const componentName = el.getAttribute("data-name")
  const component = await resolve(componentName)   // ← await first
  // ... rest of setup ...
  this.vue = { props, slots, app: null }            // ← state set last
}
```

The fix is exactly: **move the `this.vue = …` line up above
the `await`.**

```typescript
async mounted() {
  const componentName = el.getAttribute("data-name")
  this.vue = { props, slots, app: null }            // ← state set first
  // ... mid-setup that doesn't need `component` ...
  const component = await resolve(componentName)   // ← await later
  // ... build Vue app, set this.vue.app = app ...
}
```

`this.vue.app` is `null` for the brief window while the await
hangs, but that's *fine* — `updated()` only reads `this.vue.props`
(safe), and `destroyed()` already checks `if (instance) { … }`
before unmounting. Lifecycle handlers tolerate the partial
state gracefully; before the fix they crashed because `this.vue`
itself was `undefined`.

The fix is **one block reorder**. No new state, no new logic, no
API changes.

## Why `defineAsyncComponent` works as a consumer workaround

In `mixchamb` (the project this bug was found in) the workaround
is in `assets/vue/index.ts`:

```typescript
function lazy(glob) {
  return Object.fromEntries(
    Object.entries(glob).map(([k, v]) =>
      [k, defineAsyncComponent(v)]   // ← Vue's official async-component wrapper
    )
  )
}

createLiveVue({
  resolve: (name) => findComponent(
    { ...lazy(import.meta.glob("./**/*.vue")) },
    name
  ),
})
```

`defineAsyncComponent(factory)` returns a **synchronous Vue
component handle**. Vue keeps the factory and internally calls
it lazily during render, but the *handle itself* is available
immediately. So `live_vue`'s `await resolve(…)` resolves on the
next microtask, not after a network round-trip. The race window
collapses to ~zero.

This works, but it's a per-consumer workaround:

- Every project using lazy globs has to add this wrapper.
- The wrapper has to be discovered (most people hit the bug and
  give up on lazy globs rather than find the fix).
- It's brittle — anyone refactoring `index.ts` might accidentally
  drop the wrapper.

The fix in this PR closes the race *inside* `live_vue` so no
consumer has to think about it.

## What to take away if you write LiveView Hooks

This pattern bites any LiveView hook that does
`async mounted()`. The general lesson:

- **Lifecycle callbacks share `this`.** Anything `updated()` /
  `reconnected()` / `destroyed()` reads off `this`, **`mounted()`
  must set before its first `await`.**
- `await` in `mounted()` is fine; just put it after the
  synchronous state init.
- For "filled-in-later" values like a Vue app instance, use a
  `null` placeholder and have downstream callbacks tolerate the
  null. That's what this fix does with `app: null`.

If you maintain a hook of your own and want to test whether it's
vulnerable: mock a slow resolver, fire `updated()` before
`mounted()` finishes, and watch for crashes. The regression
test in `assets/hooks.test.ts` from this PR is a template you
can copy.

## Further reading

- Phoenix LiveView Hooks docs: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#module-client-hooks
- Vue 3 reactivity: https://vuejs.org/guide/extras/reactivity-in-depth.html
- `defineAsyncComponent`: https://vuejs.org/api/general.html#defineasynccomponent
- Vite glob import: https://vite.dev/guide/features.html#glob-import
- `live_vue` resolver types: `deps/live_vue/assets/types.ts` — note
  `ComponentMap` already permits `Promise<Component>` values, which
  is what tipped me off that the race was an oversight rather than
  a documented constraint.
