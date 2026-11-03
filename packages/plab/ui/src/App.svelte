<script lang="ts">
  import { onMount } from 'svelte';
  import { live } from './lib/events.svelte';
  import { jobs } from './lib/jobs.svelte';
  import { router } from './lib/router.svelte';
  import { topics } from './lib/topics.svelte';
  import JobsView from './components/JobsView.svelte';
  import ListView from './components/ListView.svelte';

  onMount(() => {
    live.on((ev) => {
      topics.apply(ev);
      jobs.apply(ev);
    });
    live.onReconnect(() => {
      topics.resync(router.route.view);
      if (router.route.view === 'jobs') void jobs.load();
    });
    live.start();
  });
</script>

<div class="p-4">
  {#if router.route.view === 'jobs'}
    <JobsView />
  {:else if router.route.view === 'search'}
    {#key router.route.q}<ListView kind="search" q={router.route.q} />{/key}
  {:else}
    {#key router.route.view}<ListView kind={router.route.view} />{/key}
  {/if}
</div>
