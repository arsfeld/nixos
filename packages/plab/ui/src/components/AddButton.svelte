<script lang="ts">
  import { postTopic } from '../lib/api';
  import { topics } from '../lib/topics.svelte';
  import type { Section, TopicState } from '../lib/types';

  // owned: plab has this scene through another release, so there is nothing to add.
  let {
    id,
    addState,
    section,
    owned = false,
    small = false,
  }: { id: number; addState: TopicState; section: Section; owned?: boolean; small?: boolean } = $props();
  const have = $derived(owned && addState === '');
  let loading = $state(false);
  let hover = $state(false);
  let error = $state('');

  const label = $derived.by(() => {
    if (loading) return addState === 'queued' ? 'Removing…' : 'Adding…';
    if (addState === 'added') return 'Added ✓';
    if (have) return 'Have it ✓';
    if (addState === 'queued') return hover ? 'Remove ✕' : 'Queued ⏳';
    return error ? 'Retry' : section === 'games' ? 'Add to Games' : 'Add to Vault';
  });

  async function toggle() {
    if (loading || addState === 'added' || have) return;
    const unqueue = addState === 'queued';
    loading = true;
    error = '';
    try {
      const j = await postTopic(unqueue ? 'unqueue' : 'add', id);
      if (unqueue) topics.setState(id, '');
      else if (j.queued) {
        topics.setState(id, 'queued');
        error = j.message ?? '';
      } else topics.setState(id, 'added');
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
      hover = false;
    }
  }
</script>

<button
  class={['add btn', small ? 'btn-xs' : 'btn-sm', addState === 'queued' ? 'btn-warning queued' : 'btn-primary']}
  disabled={loading || addState === 'added' || have}
  title={addState === 'queued' ? 'Click to remove from queue' : undefined}
  onmouseenter={() => (hover = addState === 'queued' && !loading)}
  onmouseleave={() => (hover = false)}
  onclick={toggle}>{label}</button
>
<span class="text-xs text-error">{error}</span>
