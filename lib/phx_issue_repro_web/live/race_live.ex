defmodule PhxIssueReproWeb.RaceLive do
  @moduledoc """
  Repros the live_vue `async mounted()` race.

  How it triggers:

    1. `mount/3` schedules a `:tick` message to itself with zero
       delay — Phoenix sends it on the very next mailbox round.
    2. `handle_info(:tick, _)` flips a prop on the Vue island.
       That flip is wired to LiveView via the `<.vue tick={@tick}>`
       binding below, so LiveView pushes a DOM patch to the
       client.
    3. On the client, the patch triggers the Vue island's
       LiveView hook `updated()` callback — and it fires while
       live_vue's `async mounted()` is still inside its 200 ms
       `await resolve(...)` (the slow-glob in assets/vue/index.ts).
    4. `this.vue` is undefined at this point in upstream live_vue
       1.2.1, so `applyPatch(this.vue.props, ...)` throws.

  The whole point of the repro is to land that `updated()` call
  inside the mount's await window. send_after with `0` delay is
  reliable on a cold load — the LiveView is mounted, then the
  scheduler delivers `:tick`, then the patch goes out, while the
  browser is still downloading the lazy Vue chunk.
  """
  use PhxIssueReproWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, 0)
    end

    {:ok, assign(socket, :tick, 0)}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, update(socket, :tick, &(&1 + 1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main style="font:14px/1.6 ui-monospace,Menlo,Consolas,monospace; max-width:760px; margin:48px auto; padding:0 24px;">
        <h1 style="font-size:24px; margin:0 0 8px 0;">live_vue mounted-race repro</h1>
        <p style="color:#666; margin:0 0 24px 0;">
          Open DevTools → Console. The page should log a
          <code>TypeError: Cannot read properties of undefined (reading 'props')</code>
          from <code>_ViewHook.updated</code> in <code>live_vue/assets/hooks.ts</code>.
          The Vue island below renders normally despite the error —
          the bug is about the lifecycle hook throwing, not about
          rendering failing.
        </p>
        <.vue tick={@tick} v-component="Hello" />
      </main>
    </Layouts.app>
    """
  end
end
