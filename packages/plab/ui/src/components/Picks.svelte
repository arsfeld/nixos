<script lang="ts">
  import type { Resolved } from '../lib/assistant';
  import { FilterState } from '../lib/filters.svelte';
  import type { Conversation } from '../lib/types';
  import Card from './Card.svelte';
  import SceneCard from './SceneCard.svelte';

  let {
    c,
    items,
    ongallery,
    onstream,
  }: {
    c: Conversation;
    items: Resolved[];
    ongallery: (images: string[]) => void;
    onstream: (id: number) => void;
  } = $props();

  const fs = new FilterState(null);
</script>

<div class="grid gap-3 grid-cols-[repeat(auto-fill,minmax(18rem,1fr))]">
  {#each items as r, i (i)}
    {#if r.kind === 'topic'}
      <div class="flex flex-col gap-1">
        <span class="text-sm italic"><span class="badge badge-sm mr-1">{r.pick.action}</span>{r.pick.reason}</span>
        <Card topic={r.topic} section={r.topic.section} now={c.now} topicUrl={c.topicUrl} isNew={false} {fs} stream={true} {ongallery} {onstream} />
      </div>
    {:else}
      <SceneCard scene={r.scene} reason={r.pick.reason} />
    {/if}
  {/each}
</div>
