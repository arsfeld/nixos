<script lang="ts">
  import { postTopic } from '../lib/api';
  import { topics } from '../lib/topics.svelte';
  import type { Section, Topic } from '../lib/types';

  let { topic, section }: { topic: Topic; section: Section } = $props();
  let loading = $state(false);
  let hover = $state(false);
  let error = $state('');

  const label = $derived.by(() => {
    if (loading) return topic.state === 'queued' ? 'Removing…' : 'Adding…';
    if (topic.state === 'added') return 'Added ✓';
    if (topic.state === 'queued') return hover ? 'Remove ✕' : 'Queued ⏳';
    return error ? 'Retry' : section === 'games' ? 'Add to Games' : 'Add to Vault';
  });

  async function toggle() {
    if (loading || topic.state === 'added') return;
    const unqueue = topic.state === 'queued';
    loading = true;
    error = '';
    try {
      const j = await postTopic(unqueue ? 'unqueue' : 'add', topic.id);
      if (unqueue) topics.setState(topic.id, '');
      else if (j.queued) {
        topics.setState(topic.id, 'queued');
        error = j.message ?? '';
      } else topics.setState(topic.id, 'added');
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
      hover = false;
    }
  }
</script>

<button
  class={['add btn btn-sm', topic.state === 'queued' ? 'btn-warning queued' : 'btn-primary']}
  disabled={loading || topic.state === 'added'}
  title={topic.state === 'queued' ? 'Click to remove from queue' : undefined}
  onmouseenter={() => (hover = topic.state === 'queued' && !loading)}
  onmouseleave={() => (hover = false)}
  onclick={toggle}>{label}</button
>
<span class="text-xs text-error">{error}</span>
