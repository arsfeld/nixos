<script lang="ts">
  import { onMount } from 'svelte';
  import { live } from './lib/events.svelte';
  import { daily } from './lib/daily.svelte';
  import { assistant } from './lib/assistant.svelte';
  import { jobs } from './lib/jobs.svelte';
  import { router } from './lib/router.svelte';
  import { topics } from './lib/topics.svelte';
  import AssistantView from './components/AssistantView.svelte';
  import DailyView from './components/DailyView.svelte';
  import JobsView from './components/JobsView.svelte';
  import ListView from './components/ListView.svelte';

  onMount(() => {
    live.on((ev) => {
      topics.apply(ev);
      jobs.apply(ev);
      assistant.apply(ev);
      // A finished generation matters only on For you, which loads again on mount anyway.
      if (ev.type !== 'assistantDaily' || router.route.view === 'daily') daily.apply(ev);
    });
    live.onReconnect(() => {
      topics.resync(router.route.view);
      if (router.route.view === 'jobs') void jobs.load();
      if (router.route.view === 'daily') void daily.load();
    });
    live.start();
  });
</script>

<div class="p-4">
  {#if router.route.view === 'jobs'}
    <JobsView />
  {:else if router.route.view === 'assistant'}
    <AssistantView />
  {:else if router.route.view === 'daily'}
    <DailyView />
  {:else if router.route.view === 'search'}
    {#key router.route.q}<ListView kind="search" q={router.route.q} />{/key}
  {:else}
    {#key router.route.view}<ListView kind={router.route.view} />{/key}
  {/if}
</div>
