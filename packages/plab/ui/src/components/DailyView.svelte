<script lang="ts">
  import { onMount } from 'svelte';
  import { dailyAnswer, groupPicks, show } from '../lib/daily';
  import { daily } from '../lib/daily.svelte';
  import { link } from '../lib/router.svelte';
  import Gallery from './Gallery.svelte';
  import Navbar from './Navbar.svelte';
  import Picks from './Picks.svelte';
  import Player from './Player.svelte';

  let gallery = $state<ReturnType<typeof Gallery>>();
  let player = $state<ReturnType<typeof Player>>();
  let expanded = $state(false);

  onMount(() => void daily.load());

  const d = $derived(daily.data);
  const c = $derived(d?.conversation ?? null);
  const answer = $derived(c ? dailyAnswer(c) : null);
  const groups = $derived(c && answer ? groupPicks(c, answer) : { watch: [], get: [] });
  const ongallery = (images: string[]) => gallery?.open(images);
  const onstream = (id: number) => player?.open(id);
</script>

<Navbar />
<section class="flex flex-col gap-4">
  <div class="flex flex-wrap items-center gap-2">
    <h2 class="text-lg font-semibold">{d?.generatedOn ? `Picks for ${d.generatedOn}` : 'Picks'}</h2>
    {#if d?.refreshing}
      <span class="flex items-center gap-1 text-sm text-base-content/60"><span class="loading loading-dots loading-sm"></span>refreshing…</span>
    {/if}
    <span class="flex-1"></span>
    {#if c}<a class="btn btn-sm" href={`/assistant/${c.id}`} use:link>Ask about these</a>{/if}
    <button class="btn btn-primary btn-sm" disabled={daily.busy || d?.refreshing} onclick={() => daily.refresh()}>Refresh</button>
  </div>

  {#if daily.error}<div role="alert" class="alert alert-error">{daily.error}</div>{/if}
  {#if d?.error}
    <div role="alert" class="alert alert-error">
      <span>{d.error}</span>
      <button class="btn btn-sm" disabled={daily.busy || d.refreshing} onclick={() => daily.refresh()}>Retry</button>
    </div>
  {/if}

  {#if show(d) === 'loading'}
    <span class="loading loading-dots loading-md"></span>
  {:else if show(d) === 'first'}
    <div class="flex items-center gap-2 text-base-content/60"><span class="loading loading-dots loading-sm"></span>Picking for today…</div>
  {:else if c}
    {#if c.degraded.includes('stash')}
      <div role="alert" class="alert alert-warning text-sm">Stash could not be reached: no watch picks, and the profile has only streams.</div>
    {/if}
    {#if c.scenesUnavailable}
      <div role="alert" class="alert alert-warning text-sm">Stash is not answering; watch picks are hidden.</div>
    {/if}
    {#if answer?.text}
      <button class={['text-left whitespace-pre-wrap text-base-content/80', !expanded && 'line-clamp-3']} onclick={() => (expanded = !expanded)}>{answer.text}</button>
    {/if}
    {#if groups.watch.length}
      <h3 class="font-semibold">Watch</h3>
      <Picks {c} items={groups.watch} {ongallery} {onstream} />
    {/if}
    {#if groups.get.length}
      <h3 class="font-semibold">Stream / download</h3>
      <Picks {c} items={groups.get} {ongallery} {onstream} />
    {/if}
  {/if}
</section>

<Gallery bind:this={gallery} />
<Player bind:this={player} />
