<script lang="ts">
  import type { SceneCardData } from '../lib/types';
  import { deleted } from '../lib/deleted.svelte';
  import DeleteButton from './DeleteButton.svelte';
  import VoteButtons from './VoteButtons.svelte';
  import WatchButton from './WatchButton.svelte';

  let { scene, reason }: { scene: SceneCardData; reason?: string } = $props();
  let failed = $state(false);
</script>

{#if !deleted.has([scene.id])}
<div class="card bg-base-200 shadow-sm overflow-hidden">
  <figure class="relative aspect-[16/10] bg-black">
    {#if scene.screenshot && !failed}
      <img class="w-full h-full object-cover" loading="lazy" src={scene.screenshot} alt="" onerror={() => (failed = true)} />
    {/if}
    <span class="badge badge-primary font-bold absolute top-2 left-2">watch</span>
  </figure>
  <div class="card-body p-3 gap-1">
    <h3 class="font-semibold leading-tight">{scene.title}</h3>
    {#if scene.studio}<p class="text-sm text-base-content/70">{scene.studio}</p>{/if}
    {#if scene.performers.length}<p class="text-sm text-base-content/70">{scene.performers.join(', ')}</p>{/if}
    {#if reason}<p class="text-sm italic">{reason}</p>{/if}
    <div class="card-actions justify-end">
      <WatchButton scenes={[scene.id]} />
      <VoteButtons scenes={[scene.id]} />
      <DeleteButton scenes={[scene.id]} />
      {#if scene.link}
        <a class="btn btn-sm btn-primary" href={scene.link} target="_blank" rel="noopener">Open in Stash</a>
      {/if}
    </div>
  </div>
</div>
{/if}
