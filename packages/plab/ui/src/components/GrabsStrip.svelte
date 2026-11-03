<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchGrabs } from '../lib/api';
  import { age } from '../lib/format';
  import type { Grab } from '../lib/types';
  import StatusBadge from './StatusBadge.svelte';

  let grabs = $state<Grab[]>([]);
  let now = $state(0);

  onMount(async () => {
    try {
      const r = await fetchGrabs();
      grabs = r.grabs;
      now = r.now;
    } catch {
      /* no strip */
    }
  });
</script>

{#if grabs.length}
  <details class="mb-4 rounded-box bg-base-200 p-3">
    <summary class="cursor-pointer font-semibold">Recent grabs ({grabs.length})</summary>
    <ul class="mt-2 flex flex-col gap-1">
      {#each grabs as g, i (i)}
        <li class="flex flex-wrap items-center gap-2 text-sm">
          <span class="font-semibold uppercase text-xs text-primary">{g.studio ?? ''}</span>
          <span class="break-all">{g.title}</span>
          <StatusBadge status={g.status} />
          <span class="text-xs text-base-content/60">{g.addedAt === null ? '' : age(g.addedAt, now)}</span>
        </li>
      {/each}
    </ul>
  </details>
{/if}
