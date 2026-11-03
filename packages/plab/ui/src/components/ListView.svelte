<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { isVisible, offered, prune, toHash } from '../lib/filters';
  import { filters } from '../lib/filters.svelte';
  import { age, isFresh } from '../lib/format';
  import { link } from '../lib/router.svelte';
  import { topics } from '../lib/topics.svelte';
  import type { Section } from '../lib/types';
  import Card from './Card.svelte';
  import FilterBar from './FilterBar.svelte';
  import Gallery from './Gallery.svelte';
  import GrabsStrip from './GrabsStrip.svelte';
  import Navbar from './Navbar.svelte';
  import NewReleasesPill from './NewReleasesPill.svelte';
  import Player from './Player.svelte';

  let { kind, q = '' }: { kind: Section | 'search'; q?: string } = $props();
  // kind is fixed for this instance: App keys ListView by view and query.
  const fs = untrack(() => filters[kind]);
  const section: Section = untrack(() => (kind === 'search' ? 'video' : kind));
  // Video and Indexers cards stream; Albums are links only.
  const streams = section === 'video' || section === 'indexers';
  let gallery = $state<ReturnType<typeof Gallery>>();
  let player = $state<ReturnType<typeof Player>>();

  fs.activate();
  onMount(() => {
    if (kind === 'search') void topics.search(q);
    else topics.ensure(kind);
  });

  const list = $derived(topics.lists[kind]);
  const newIds = $derived(kind === 'search' ? undefined : topics.newIds[kind]);
  const isNew = (id: number) => !!newIds?.has(String(id));
  const shown = $derived(
    list ? list.topics.filter((t) => isVisible(fs.st, t, isFresh(t.added, list.now), isNew(t.id))) : [],
  );
  const curated = $derived(list ? list.topics.filter((t) => t.filters.length).length : 0);

  // A saved value no longer offered would hide every card.
  $effect(() => {
    if (!list) return;
    const p = prune(fs.st, offered(list));
    if (p !== fs.st) fs.st = p;
  });
  $effect(() => {
    toHash(fs.st);
    untrack(() => fs.save());
  });
</script>

<Navbar>
  {#if list}
    {#if kind === 'search'}
      <a class="link link-hover" href="/" use:link>← weekly list</a> ·
      {#if list.error}<span class="text-error">{list.error}</span>{:else}
        {list.topics.length} result{list.topics.length === 1 ? '' : 's'} for “{list.query}” · all time
      {/if}
    {:else}
      {list.topics.length} releases · {kind === 'video' ? 'last 7 days' : 'last 32 days'} · updated {age(list.updated, list.now)}
      {#if curated}· {curated} curated{/if}
      {#if list.pending}· {list.pending} queued{/if}
      {#if newIds?.size}· {newIds.size} new{/if}
    {/if}
  {/if}
</Navbar>

{#if topics.errors[kind]}<div role="alert" class="alert alert-error mb-4">{topics.errors[kind]}</div>{/if}
{#if kind !== 'search' && topics.stale[section]}<NewReleasesPill onreload={() => topics.load(section)} />{/if}

{#if list}
  <FilterBar {kind} {list} {fs} shown={shown.length} />
  {#if kind === 'video'}<GrabsStrip />{/if}
  <div class="grid gap-4 grid-cols-[repeat(auto-fill,minmax(min(280px,100%),1fr))]">
    {#each shown as t (t.id)}
      <Card
        topic={t}
        {section}
        now={list.now}
        topicUrl={list.topicUrl}
        isNew={isNew(t.id)}
        {fs}
        stream={streams}
        ongallery={(images) => gallery?.open(images)}
        onstream={(id) => player?.open(id)}
      />
    {/each}
  </div>
{:else if !topics.errors[kind]}
  <span class="loading loading-dots"></span>
{/if}

<Gallery bind:this={gallery} />
{#if streams}<Player bind:this={player} />{/if}
