<script lang="ts">
  import { age, day } from '../lib/format';
  import { keyLabels, pickLabel, runtime } from '../lib/grablog';
  import type { GrabLog } from '../lib/types';
  import { statusScenes } from '../lib/watchlist';
  import StatusBadge from './StatusBadge.svelte';
  import DeleteButton from './DeleteButton.svelte';
  import VoteButtons from './VoteButtons.svelte';
  import WatchButton from './WatchButton.svelte';

  let { grab, now }: { grab: GrabLog; now: number } = $props();

  // The poster is the first scene the release became; a pack shows how many more.
  const scene = $derived(grab.scenes[0] ?? null);
  let failed = $state(false);
  let playing = $state(false);
  const when = $derived(grab.at === null ? '' : now - grab.at < 86400 ? age(grab.at, now) : day(grab.at));
  // With a poster, only a status the poster does not already tell (downloading, failed…).
  const showStatus = $derived(
    grab.status && !(scene && ['added', 'inStash', 'identified'].includes(grab.status.kind)),
  );
  const watchScenes = $derived(grab.scenes.length ? grab.scenes.map((s) => s.id) : statusScenes(grab.status));
</script>

<article class="card bg-base-200 shadow-sm overflow-hidden h-full">
  <a
    class="relative block aspect-video bg-black"
    href={scene?.link ?? undefined}
    target="_blank"
    rel="noopener"
    onmouseenter={() => (playing = true)}
    onmouseleave={() => (playing = false)}
    onfocus={() => (playing = true)}
    onblur={() => (playing = false)}
  >
    {#if scene?.screenshot && !failed}
      <img class="absolute inset-0 w-full h-full object-cover" loading="lazy" src={scene.screenshot} alt="" onerror={() => (failed = true)} />
    {:else}
      <div class="absolute inset-0 grid place-items-center bg-gradient-to-br from-base-300 to-base-100 p-4">
        <span class="text-center text-lg font-bold uppercase tracking-wide text-base-content/40 break-words">{grab.studio}</span>
      </div>
    {/if}
    {#if playing && scene?.preview}
      <video class="absolute inset-0 w-full h-full object-cover" src={scene.preview} muted loop autoplay playsinline></video>
    {/if}
    {#if showStatus && grab.status}<span class="absolute top-2 left-2 max-w-[70%]"><StatusBadge status={grab.status} /></span>{/if}
    {#if grab.scenes.length > 1}
      <span class="badge badge-sm badge-neutral absolute top-2 right-2">+{grab.scenes.length - 1} scenes</span>
    {/if}
    {#if scene?.duration}
      <span class="badge badge-sm badge-neutral absolute bottom-2 right-2 font-mono">{runtime(scene.duration)}</span>
    {/if}
  </a>
  <div class="card-body p-3 gap-1 text-sm flex-1">
    <h3 class="font-semibold leading-tight line-clamp-2" title={grab.title}>
      {#if scene?.link}<a class="link link-hover" href={scene.link} target="_blank" rel="noopener">{scene.title}</a>
      {:else}<span class="break-all">{grab.title}</span>{/if}
    </h3>
    <p class="text-xs text-base-content/70">
      <span class="font-semibold uppercase text-primary">{scene?.studio ?? grab.studio}</span>
      {#if scene?.date}· {scene.date}{/if}
    </p>
    {#if scene?.performers.length}<p class="text-xs text-base-content/70">{scene.performers.join(', ')}</p>{/if}

    <div class="mt-auto rounded bg-base-300/60 px-2 py-1 text-xs text-base-content/70">
      <p>
        <span class="font-semibold">Why:</span> followed studio <b>{grab.studio}</b>{#if grab.reason}, found searching
          “{grab.reason.query}”{/if}
      </p>
      {#if grab.keys.length}<p>New scene: {keyLabels(grab.keys).join(' · ')}</p>{/if}
      {#if grab.reason}
        <p>
          Picked {pickLabel(grab.reason)}{#if grab.reason.published}, published {grab.reason.published.slice(0, 10)}{/if}
        </p>
      {:else}
        <p class="italic">Grabbed before plab recorded which copy won.</p>
      {/if}
    </div>

    <div class="mt-1 flex min-h-6 items-center gap-2 text-xs text-base-content/60">
      {#if scene}<span class="truncate" title={grab.title}>{grab.title}</span>{/if}
      <span class="ml-auto shrink-0">{when}</span>
      <WatchButton scenes={watchScenes} small />
      <VoteButtons scenes={watchScenes} small />
      <DeleteButton scenes={watchScenes} small />
    </div>
  </div>
</article>
