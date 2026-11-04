<script lang="ts">
  import { onMount } from 'svelte';
  import { lastFailed, resolvePick } from '../lib/assistant';
  import { assistant } from '../lib/assistant.svelte';
  import { link, router } from '../lib/router.svelte';
  import Gallery from './Gallery.svelte';
  import Navbar from './Navbar.svelte';
  import Picks from './Picks.svelte';
  import Player from './Player.svelte';

  let draft = $state('');
  let gallery = $state<ReturnType<typeof Gallery>>();
  let player = $state<ReturnType<typeof Player>>();

  onMount(() => void assistant.load());
  $effect(() => {
    if (router.route.view === 'assistant') void assistant.open(router.route.id);
  });

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    const t = draft.trim();
    if (!t || assistant.busy) return;
    draft = '';
    // A failed send gives the text back, unless something new has been typed since.
    if (!(await assistant.send(t)) && !draft) draft = t;
  }
</script>

<Navbar />
<div class="grid md:grid-cols-[16rem_1fr] gap-4">
  <aside class="flex flex-col gap-2">
    <a class="btn btn-sm" href="/assistant" use:link>New chat</a>
    <ul class="menu menu-sm bg-base-200 rounded-box w-full">
      {#each assistant.list as c (c.id)}
        <li class="flex-row">
          <a class={['flex-1 truncate', assistant.current?.id === c.id && 'menu-active']} href={`/assistant/${c.id}`} use:link>{c.title}</a>
          <button class="btn btn-ghost btn-xs" aria-label="Delete" onclick={() => assistant.remove(c.id)}>✕</button>
        </li>
      {/each}
    </ul>
  </aside>

  <section class="flex flex-col gap-4 min-w-0">
    {#if assistant.error}<div role="alert" class="alert alert-error">{assistant.error}</div>{/if}
    {#if assistant.current}
      {@const c = assistant.current}
      {#if c.degraded.includes('stash')}
        <div role="alert" class="alert alert-warning text-sm">Stash could not be reached: no watch picks, and the profile has only streams.</div>
      {/if}
      {#if c.scenesUnavailable}
        <div role="alert" class="alert alert-warning text-sm">Stash is not answering; watch picks are hidden.</div>
      {/if}
      {#each c.turns as turn (turn.seq)}
        {@const retry = turn.seq === c.turns.at(-1)?.seq && lastFailed(c)}
        {#if turn.role === 'user'}
          <div class="chat chat-end"><div class="chat-bubble">{turn.text}</div></div>
          {#if retry && !assistant.busy}
            <div class="flex items-center gap-2 text-sm">
              <span>No reply yet.</span>
              <button class="btn btn-sm" onclick={() => assistant.retry()}>Retry</button>
            </div>
          {/if}
        {:else if turn.error}
          <div role="alert" class="alert alert-error">
            <span>{turn.error}</span>
            {#if retry}
              <button class="btn btn-sm" disabled={assistant.busy} onclick={() => assistant.retry()}>Retry</button>
            {/if}
          </div>
        {:else}
          <div class="chat chat-start"><div class="chat-bubble chat-bubble-neutral whitespace-pre-wrap">{turn.text}</div></div>
          {#if turn.picks.length}
            {@const items = turn.picks.map((p) => resolvePick(c, p)).filter((r) => r !== null)}
            {#if items.length}
              <Picks {c} {items} ongallery={(images) => gallery?.open(images)} onstream={(id) => player?.open(id)} />
            {/if}
          {/if}
        {/if}
      {/each}
    {:else}
      <p class="text-base-content/60">Ask something below; today's picks are on For you.</p>
    {/if}

    {#if assistant.busy}<div class="flex items-center gap-2 text-sm"><span class="loading loading-dots loading-sm"></span>Thinking…</div>{/if}

    <form class="join w-full" onsubmit={submit}>
      <input class="input join-item w-full" placeholder="Ask the assistant…" aria-label="Message" bind:value={draft} disabled={assistant.busy} maxlength="4000" />
      <button class="btn btn-primary join-item" disabled={assistant.busy || !draft.trim()}>Send</button>
    </form>
  </section>
</div>

<Gallery bind:this={gallery} />
<Player bind:this={player} />
