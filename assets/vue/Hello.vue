<script setup lang="ts">
// Minimal Vue island. Just renders the `tick` prop from the
// LiveView so we can prove that prop-update patches arrive after
// mount — that's the signal that fires `updated()` inside
// live_vue's hook and trips the race.
defineProps<{ tick: number }>()
</script>

<template>
  <div style="font:14px/1.6 ui-monospace,Menlo,Consolas,monospace; padding:16px; border:1px solid #ddd; border-radius:6px; max-width:560px;">
    <h2 style="margin:0 0 6px 0; font-size:16px;">Vue island</h2>
    <p style="margin:0;">tick: {{ tick }}</p>
  </div>
</template>
