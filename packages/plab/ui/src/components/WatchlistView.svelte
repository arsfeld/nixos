<script lang="ts">
  import { fetchWatchlist } from '../lib/api';
  import { age } from '../lib/format';
  import { Latest } from '../lib/latest';
  import type { WatchlistReply } from '../lib/types';
  import { watchlist } from '../lib/watchlist.svelte';
  import Navbar from './Navbar.svelte';
  import SceneCard from './SceneCard.svelte';

  let data = $state<WatchlistReply | null>(null);
  let error = $state<string | null>(null);
  const latest = new Latest<'load'>();

  async function load() {
    const token = latest.next('load');
    try {
      const r = await fetchWatchlist();
      if (latest.current('load', token)) {
        data = r;
        error = r.error;
      }
    } catch (e) {
      if (latest.current('load', token)) error = e instanceof Error ? e.message : String(e);
    }
  }

  // Every change to the queued set (this page, another tab, a reconnect) reloads; a scene
  // unqueued here leaves at once through the filter below, before the reload answers.
  $effect(() => {
    void watchlist.ids;
    void load();
  });

  const scenes = $derived((data?.scenes ?? []).filter((s) => watchlist.ids.has(s.id)));
</script>

<Navbar />
<section class="flex flex-col gap-4">
  <h2 class="text-lg font-semibold">Watchlist ({scenes.length})</h2>
  {#if error}<div role="alert" class="alert alert-error">{error}</div>{/if}
  {#if !data && !error}
    <span class="loading loading-dots loading-md"></span>
  {:else if data && !scenes.length && !error}
    <p class="text-base-content/60">Nothing queued. ☆ Watch appears on any card for a scene that's in Stash.</p>
  {:else}
    <div class="grid gap-3 grid-cols-[repeat(auto-fill,minmax(18rem,1fr))]">
      {#each scenes as s (s.id)}
        <SceneCard scene={s} reason={`added ${age(s.addedAt, data?.now ?? 0)}`} />
      {/each}
    </div>
  {/if}
</section>
