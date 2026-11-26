<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchGrabLog } from '../lib/api';
  import { studios } from '../lib/grablog';
  import type { GrabLogReply } from '../lib/types';
  import GrabPoster from './GrabPoster.svelte';
  import Navbar from './Navbar.svelte';

  let data = $state<GrabLogReply | null>(null);
  let error = $state('');
  let studio = $state('');

  onMount(async () => {
    try {
      data = await fetchGrabLog();
    } catch {
      error = 'plab not responding';
    }
  });

  const grabs = $derived(data?.grabs ?? []);
  const shown = $derived(studio ? grabs.filter((g) => g.studio === studio) : grabs);
</script>

<Navbar>{grabs.length} grab{grabs.length === 1 ? '' : 's'}</Navbar>
<div class="mb-4 flex flex-wrap items-center gap-3">
  <p class="text-sm text-base-content/70">
    The grab job takes one 1080p copy of every new scene, published in the last 30 days, from each followed studio.
  </p>
  {#if grabs.length}
    <select class="select select-sm w-auto ml-auto" bind:value={studio} aria-label="Studio">
      <option value="">All studios</option>
      {#each studios(grabs) as [name, n] (name)}<option value={name}>{name} ({n})</option>{/each}
    </select>
  {/if}
</div>
{#if error}<div role="alert" class="alert alert-error mb-4">{error}</div>{/if}
{#if data?.error}<div role="alert" class="alert alert-warning mb-4">No posters: {data.error}</div>{/if}
{#if !data && !error}
  <span class="loading loading-dots loading-md"></span>
{:else if data && !grabs.length}
  <p class="text-base-content/60">No grabs yet.</p>
{:else}
  <div class="grid gap-3 grid-cols-[repeat(auto-fill,minmax(min(18rem,100%),1fr))]">
    {#each shown as g, i (`${g.studio}\u0000${g.title}\u0000${g.at ?? i}`)}
      <GrabPoster grab={g} now={data?.now ?? 0} />
    {/each}
  </div>
{/if}
