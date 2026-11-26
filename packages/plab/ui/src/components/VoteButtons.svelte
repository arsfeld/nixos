<script lang="ts">
  import { voteAction, voteOf } from '../lib/votes';
  import { votes } from '../lib/votes.svelte';

  let { scenes, small = false }: { scenes: string[]; small?: boolean } = $props();
  const current = $derived(voteOf(votes.map, scenes));
  let busy = $state(false);
  let error = $state('');

  async function press(pressed: 1 | -1) {
    if (busy) return;
    busy = true;
    error = '';
    try {
      await votes.set(scenes, voteAction(current, pressed));
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  const cls = (v: 1 | -1) => [
    'btn btn-ghost px-1',
    small ? 'btn-xs' : 'btn-sm',
    current === v && (v === 1 ? 'text-success' : 'text-error'),
    current !== 0 && current !== v && 'opacity-50',
    error && 'text-error',
  ];
  const title = (v: 1 | -1, name: string) =>
    error || (current === v ? `${name}: press to clear` : name);
</script>

{#if scenes.length}
  <button type="button" class={cls(1)} disabled={busy} title={title(1, 'Liked')} aria-pressed={current === 1}
    onclick={() => press(1)}>👍</button
  >
  <button type="button" class={cls(-1)} disabled={busy} title={title(-1, 'Disliked')} aria-pressed={current === -1}
    onclick={() => press(-1)}>👎</button
  >
{/if}
