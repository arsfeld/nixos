<script lang="ts">
  import { onMount } from 'svelte';
  import { jobs } from '../lib/jobs.svelte';
  import JobCard from './JobCard.svelte';
  import Navbar from './Navbar.svelte';

  onMount(() => {
    void jobs.load();
  });
</script>

<Navbar>{jobs.list.length} job{jobs.list.length === 1 ? '' : 's'}</Navbar>
{#if jobs.error}<div role="alert" class="alert alert-error mb-4">{jobs.error}</div>{/if}
<div class="grid gap-4 grid-cols-[repeat(auto-fill,minmax(min(360px,100%),1fr))]">
  {#each jobs.list as job (job.name)}<JobCard {job} />{/each}
</div>
