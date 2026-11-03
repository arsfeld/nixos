<script lang="ts">
  import { untrack } from 'svelte';
  import { mostCommon, valueOf, type Select, type Toggle } from '../lib/filters';
  import type { FilterState } from '../lib/filters.svelte';
  import { router } from '../lib/router.svelte';
  import type { List } from '../lib/types';

  let { kind, list, fs, shown }: { kind: 'video' | 'games' | 'search'; list: List; fs: FilterState; shown: number } =
    $props();

  const games = $derived(kind === 'games');
  const search = $derived(kind === 'search');
  // A search is all time, and its results are not new or classified by production.
  const toggles = $derived<[Toggle, string][]>(
    search
      ? [['h24', 'Last 24h'], ['hide', 'Hide added']]
      : [['h24', 'Last 24h'], ['new', 'New'], ['hide', 'Hide added']],
  );
  const selects = $derived.by(() => {
    const keys: [Exclude<Select, 'f'>, string][] = [
      ...(search ? [] : [['prod', 'Production'] as [Exclude<Select, 'f'>, string]]),
      ['cat', 'Category'],
      ['studio', 'Studio'],
      ['q', 'Quality'],
    ];
    const out: { key: Select; name: string; options: [string, number][] }[] = keys.map(([key, name]) => ({
      key,
      name,
      options: mostCommon(list.topics.map((t) => valueOf(t, key))),
    }));
    // The curated filters, in file order; at most one is active.
    if (list.curatedFilters.length)
      out.splice(1, 0, {
        key: 'f',
        name: 'Curated',
        options: list.curatedFilters.map((n) => [n, list.topics.filter((t) => t.filters.includes(n)).length]),
      });
    return out;
  });
  const tagCounts = $derived(mostCommon(list.topics.flatMap((t) => t.tags)));
  const known = $derived(new Set(tagCounts.map(([t]) => t)));
  const allTags = $derived([...known].sort());

  let typed = $state('');
  let q = $state(untrack(() => (search ? (list.query ?? '') : '')));

  function addTyped() {
    const t = typed.trim().toLowerCase();
    typed = '';
    fs.addTag(t);
  }

  // Picking a datalist suggestion adds it at once.
  function onTagInput() {
    const v = typed.trim().toLowerCase();
    if (known.has(v)) {
      typed = '';
      fs.addTag(v);
    }
  }

  function submit(e: SubmitEvent) {
    e.preventDefault();
    const v = q.trim();
    if (v) router.go('/search?q=' + encodeURIComponent(v));
  }
</script>

<div class="sm:sticky top-0 z-10 bg-base-100 py-2 mb-4 border-b border-base-300 flex flex-wrap items-center gap-2">
  {#if !games}
    <form class="join" role="search" onsubmit={submit}>
      <input class="input input-sm join-item w-48" type="search" bind:value={q} placeholder="Search the tracker" required />
      <button class="btn btn-sm join-item">Search</button>
    </form>
  {/if}
  <div class="join">
    {#each toggles as [k, name] (k)}
      <button type="button" class={['btn btn-sm join-item', fs.st[k] && 'btn-primary']} onclick={() => fs.toggle(k)}>{name}</button>
    {/each}
  </div>
  {#if !games}
    {#each selects as s (s.key)}
      <label class="select select-sm w-auto max-w-full">
        <span class="label">{s.name}</span>
        <select aria-label={s.name} bind:value={fs.st[s.key]}>
          <option value="">All</option>
          {#each s.options as [v, n] (v)}<option value={v}>{v} ({n})</option>{/each}
        </select>
      </label>
    {/each}
    <details class="dropdown">
      <summary class="btn btn-sm">
        Tags{#if fs.st.tags.length}<span class="badge badge-sm badge-primary">{fs.st.tags.length}</span>{/if}
      </summary>
      <div class="dropdown-content z-20 mt-1 w-80 max-w-[90vw] rounded-box bg-base-200 p-3 shadow-lg flex flex-col gap-2">
        <input
          class="input input-sm w-full"
          list="taglist"
          placeholder="type a tag"
          autocomplete="off"
          bind:value={typed}
          oninput={onTagInput}
          onkeydown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              addTyped();
            }
          }}
        />
        <datalist id="taglist">
          {#each allTags as t (t)}<option value={t}></option>{/each}
        </datalist>
        <div class="flex flex-wrap gap-1 max-h-48 overflow-y-auto">
          {#each tagCounts.slice(0, 20) as [t, n] (t)}
            <button type="button" class={['btn btn-xs', fs.st.tags.includes(t) && 'btn-primary']} onclick={() => fs.toggleTag(t)}
              >{t}<span class="badge badge-xs">{n}</span></button
            >
          {/each}
        </div>
      </div>
    </details>
  {/if}
  <span class="flex flex-wrap gap-1">
    {#each fs.st.tags as t (t)}
      <button type="button" class="badge badge-primary cursor-pointer" onclick={() => fs.toggleTag(t)}>{t} ×</button>
    {/each}
  </span>
  <button type="button" class="btn btn-ghost btn-sm" onclick={() => fs.clear()}>Clear</button>
  <span class="ml-auto text-sm text-base-content/60">Showing {shown} of {list.topics.length}</span>
</div>
