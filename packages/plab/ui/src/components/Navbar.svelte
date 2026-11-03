<script lang="ts">
  import type { Snippet } from 'svelte';
  import { live } from '../lib/events.svelte';
  import { link, router } from '../lib/router.svelte';

  let { children }: { children?: Snippet } = $props();
  const tabs = [
    ['video', '/', 'Tracker'],
    ['indexers', '/indexers', 'Indexers'],
    ['albums', '/albums', 'Albums'],
    ['games', '/games', 'Games'],
    ['jobs', '/jobs', 'Jobs'],
  ] as const;
</script>

<header class="navbar min-h-0 p-0 mb-2 flex-wrap items-baseline gap-x-4 gap-y-1">
  <h1 class="text-xl font-bold">plab</h1>
  <div role="tablist" class="tabs tabs-box tabs-sm">
    {#each tabs as [view, href, name] (view)}
      <a role="tab" class={['tab', router.route.view === view && 'tab-active']} {href} use:link>{name}</a>
    {/each}
  </div>
  <span
    class={['inline-block size-2 rounded-full self-center', live.connected ? 'bg-success' : 'bg-warning']}
    title={live.connected ? 'live' : 'reconnecting'}
  ></span>
  <span class="text-sm text-base-content/60">{@render children?.()}</span>
</header>
