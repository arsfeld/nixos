<script lang="ts">
  import { watching } from '../lib/watchlist';
  import { watchlist } from '../lib/watchlist.svelte';

  let { scenes, small = false }: { scenes: string[]; small?: boolean } = $props();
  const on = $derived(watching(watchlist.ids, scenes));
  let busy = $state(false);
  let error = $state('');

  async function toggle() {
    if (busy) return;
    busy = true;
    error = '';
    try {
      await watchlist.toggle(scenes);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }
</script>

{#if scenes.length}
  <button
    type="button"
    class={['btn btn-ghost', small ? 'btn-xs' : 'btn-sm', error && 'text-error']}
    disabled={busy}
    title={error || (on ? 'Remove from the watchlist' : 'Add to the watchlist')}
    onclick={toggle}>{on ? '★ Watching' : '☆ Watch'}</button
  >
{/if}
