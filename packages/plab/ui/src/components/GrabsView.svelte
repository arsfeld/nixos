<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchGrabLog } from '../lib/api';
  import { age, day } from '../lib/format';
  import { keyLabels, pickLabel } from '../lib/grablog';
  import type { GrabLog } from '../lib/types';
  import { statusScenes } from '../lib/watchlist';
  import Navbar from './Navbar.svelte';
  import StatusBadge from './StatusBadge.svelte';
  import WatchButton from './WatchButton.svelte';

  let grabs = $state<GrabLog[]>([]);
  let now = $state(0);
  let error = $state('');

  onMount(async () => {
    try {
      const r = await fetchGrabLog();
      grabs = r.grabs;
      now = r.now;
    } catch {
      error = 'plab not responding';
    }
  });

  // Within a day the age reads better than the date.
  const when = (t: number | null) => (t === null ? '' : now - t < 86400 ? age(t, now) : day(t));
</script>

<Navbar>{grabs.length} grab{grabs.length === 1 ? '' : 's'}</Navbar>
<p class="mb-4 text-sm text-base-content/70">
  The grab job takes one 1080p copy of every new scene, published in the last 30 days, from each followed studio.
</p>
{#if error}<div role="alert" class="alert alert-error mb-4">{error}</div>{/if}
<ul class="flex flex-col gap-2">
  {#each grabs as g, i (i)}
    <li class="rounded-box bg-base-200 p-3 text-sm">
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-semibold uppercase text-xs text-primary">{g.studio}</span>
        <span class="break-all">{g.title}</span>
        {#if g.status}<StatusBadge status={g.status} />{/if}
        <WatchButton scenes={statusScenes(g.status)} small />
        <span class="ml-auto text-xs text-base-content/60">{when(g.at)}</span>
      </div>
      <ul class="mt-1 flex flex-col text-xs text-base-content/70">
        <li>
          Followed studio <b>{g.studio}</b>{#if g.reason}, found searching “{g.reason.query}”{/if}
        </li>
        {#if g.keys.length}<li>New scene: {keyLabels(g.keys).join(' · ')}</li>{/if}
        {#if g.reason}
          <li>
            Picked {pickLabel(g.reason)}{#if g.reason.published}, published {g.reason.published.slice(0, 10)}{/if}
          </li>
        {:else}
          <li class="italic">Grabbed before plab recorded which copy won and why.</li>
        {/if}
      </ul>
    </li>
  {:else}
    {#if !error}<li class="text-base-content/60">No grabs yet.</li>{/if}
  {/each}
</ul>
