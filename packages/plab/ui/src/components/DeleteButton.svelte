<script lang="ts">
  import { deleted } from '../lib/deleted.svelte';

  let { scenes, small = false }: { scenes: string[]; small?: boolean } = $props();
  const gone = $derived(deleted.has(scenes));
  let armed = $state(false);
  let busy = $state(false);
  let error = $state('');
  let disarm: ReturnType<typeof setTimeout> | undefined;

  // The first press arms it; a second within a few seconds deletes.
  async function press() {
    if (busy || gone) return;
    if (!armed) {
      armed = true;
      error = '';
      clearTimeout(disarm);
      disarm = setTimeout(() => (armed = false), 4000);
      return;
    }
    clearTimeout(disarm);
    armed = false;
    busy = true;
    try {
      await deleted.delete(scenes);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  const what = $derived(scenes.length > 1 ? `these ${scenes.length} scenes` : 'this scene');
</script>

{#if scenes.length && !gone}
  <button
    type="button"
    class={['btn px-1', small ? 'btn-xs' : 'btn-sm', armed ? 'btn-error' : 'btn-ghost', error && 'text-error']}
    disabled={busy}
    title={error || (armed ? `Press again to delete ${what} and the files from Stash` : `Delete ${what} from Stash`)}
    onclick={press}>{armed ? 'Delete?' : '🗑'}</button
  >
{/if}
