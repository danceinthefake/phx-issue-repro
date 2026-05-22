import { h, type Component } from "vue"
import { createLiveVue, findComponent, type LiveHook, type ComponentMap } from "live_vue"

declare module "vue" {
  interface ComponentCustomProperties {
    $live: LiveHook
  }
}

// Bug trigger #1 — lazy globs so the resolver returns
// `Promise<Component>` instead of an eagerly-loaded module. This
// alone is enough to expose the race in some apps; the slow()
// wrapper below just widens the await window so it fires on every
// load instead of randomly on slow connections.
//
// Bug trigger #2 — `slow()` adds 200 ms before the dynamic import
// resolves. live_vue's `mounted()` awaits this before setting
// `this.vue`; during the 200 ms wait, LiveView's `updated()` patch
// (kicked off by RaceLive's send_after(:tick, 0) — see
// lib/phx_issue_repro_web/live/race_live.ex) dereferences
// `this.vue.props` against `undefined` and throws.
function slow<T>(factory: () => Promise<T>): () => Promise<T> {
  return () => new Promise((r) => setTimeout(r, 200)).then(factory)
}

function slowGlob(
  glob: Record<string, () => Promise<unknown>>,
): Record<string, () => Promise<unknown>> {
  return Object.fromEntries(Object.entries(glob).map(([k, v]) => [k, slow(v)]))
}

export default createLiveVue({
  resolve: (name) => {
    const components = {
      ...slowGlob(import.meta.glob("./**/*.vue")),
    } as ComponentMap

    return findComponent(components as ComponentMap, name)
  },
  setup: ({ createApp, component, props, slots, plugin, el }) => {
    const app = createApp({ render: () => h(component as Component, props, slots) })
    app.use(plugin)
    app.mount(el)
    return app
  },
})
