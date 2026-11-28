<script lang="ts">
  import { fetchPlays, fetchVoted } from '../lib/api';
  import { Latest } from '../lib/latest';
  import type { PlayedScene, VotedReply } from '../lib/types';
  import { byVote, playedFor } from '../lib/votes';
  import { votes } from '../lib/votes.svelte';
  import Navbar from './Navbar.svelte';
  import SceneCard from './SceneCard.svelte';

  let data = $state<VotedReply | null>(null);
  let error = $state<string | null>(null);
  let tab = $state<'played' | 'liked' | 'disliked'>('played');
  // Stash's last plays, to vote on; loaded once, since votes change only their thumbs.
  let plays = $state<PlayedScene[] | null>(null);
  let playsError = $state<string | null>(null);
  fetchPlays().then(
    (s) => (plays = s),
    (e) => (playsError = e instanceof Error ? e.message : String(e)),
  );
  const latest = new Latest<'load'>();

  async function load() {
    const token = latest.next('load');
    try {
      const r = await fetchVoted();
      if (latest.current('load', token)) {
        data = r;
        error = r.error;
      }
    } catch (e) {
      if (latest.current('load', token)) error = e instanceof Error ? e.message : String(e);
    }
  }

  // Every change to the votes (this page, another tab, a reconnect) reloads, so a scene voted
  // elsewhere appears; one changed here moves at once through byVote, before the reload answers.
  $effect(() => {
    void votes.map;
    void load();
  });

  const groups = $derived(byVote(data?.scenes ?? [], votes.map));
  const shown = $derived(tab === 'disliked' ? groups.disliked : groups.liked);
  const playedLine = (s: PlayedScene) =>
    ['played', playedFor(s.playedSecs), s.lastPlayedAt !== null ? day(s.lastPlayedAt) : null].filter(Boolean).join(' · ');
  const day = (t: number) => new Date(t * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
</script>

<Navbar />
<section class="flex flex-col gap-4">
  <div role="tablist" class="tabs tabs-border">
    <button role="tab" class={['tab', tab === 'played' && 'tab-active']} onclick={() => (tab = 'played')}>Recently played</button>
    <button role="tab" class={['tab', tab === 'liked' && 'tab-active']} onclick={() => (tab = 'liked')}>👍 Liked ({groups.liked.length})</button>
    <button role="tab" class={['tab', tab === 'disliked' && 'tab-active']} onclick={() => (tab = 'disliked')}>👎 Disliked ({groups.disliked.length})</button>
  </div>
  {#if tab === 'played'}
    {#if playsError}
      <div role="alert" class="alert alert-error">{playsError}</div>
    {:else if !plays}
      <span class="loading loading-dots loading-md"></span>
    {:else if !plays.length}
      <p class="text-base-content/60">Stash has no plays yet.</p>
    {:else}
      <div class="grid gap-3 grid-cols-[repeat(auto-fill,minmax(18rem,1fr))]">
        {#each plays as s (s.id)}
          <SceneCard scene={s} reason={playedLine(s)} />
        {/each}
      </div>
    {/if}
  {:else if error}
    <div role="alert" class="alert alert-error">{error}</div>
  {:else if !data}
    <span class="loading loading-dots loading-md"></span>
  {:else if !shown.length}
    <p class="text-base-content/60">{tab === 'liked' ? 'Nothing liked yet.' : 'Nothing disliked yet.'} Vote from Recently played, or with the thumbs on any card for a scene that's in Stash.</p>
  {:else}
    <div class="grid gap-3 grid-cols-[repeat(auto-fill,minmax(18rem,1fr))]">
      {#each shown as s (s.id)}
        <SceneCard scene={s} reason={`${s.vote === 1 ? 'liked' : 'disliked'} ${day(s.votedAt)}`} />
      {/each}
    </div>
  {/if}
</section>
