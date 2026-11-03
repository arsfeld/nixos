<script lang="ts">
  import { onDestroy } from 'svelte';
  import { HttpError, streamCall } from '../lib/api';
  import { streamProgress } from '../lib/stream';
  import type { Stats, StreamFile } from '../lib/types';

  interface Info {
    files: StreamFile[];
    selected: number;
    external: string | null;
  }
  interface Poll {
    stats?: Stats;
    starting?: { step: string; since: number };
  }

  let dlg = $state<HTMLDialogElement>();
  let video = $state<HTMLVideoElement>();
  let id = $state<number | null>(null);
  let files = $state<StreamFile[]>([]);
  let selected = $state<number | null>(null);
  let src = $state('');
  let external = $state('');
  let progress = $state('');
  let error = $state('');
  let copied = $state(false);
  // Not shown, only read by the timers.
  let started = 0;
  let posted = false;
  let step = 'Starting';
  let starting = false;
  let pollTimer: ReturnType<typeof setInterval> | undefined;
  let clockTimer: ReturnType<typeof setInterval> | undefined;

  const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

  function stopTimers() {
    clearInterval(pollTimer);
    clearInterval(clockTimer);
  }

  // The start line while the engine is not up yet: "<step>… <n>s".
  function tick() {
    if (id === null || !starting) return;
    progress = `${step}… ${Math.floor((Date.now() - started) / 1000)}s`;
  }

  function apply(t: number, j: Info) {
    id = t;
    files = j.files ?? [];
    selected = j.selected;
    src = `/api/stream/${t}/${j.selected}`;
    external = j.external ?? '';
    error = '';
  }

  export async function open(t: number) {
    id = t;
    files = [];
    selected = null;
    src = '';
    external = '';
    progress = 'Starting… 0s';
    error = '';
    copied = false;
    started = Date.now();
    posted = false;
    step = 'Starting';
    starting = true;
    dlg?.showModal();
    // Poll at once: the POST can take minutes, and the poll says what it is doing. The
    // poll is also the stream's keep-alive (each counts as a read for the reaper).
    stopTimers();
    pollTimer = setInterval(poll, 2000);
    clockTimer = setInterval(tick, 1000);
    void poll();
    try {
      const j = await streamCall<Info>(`${t}`, 'POST');
      if (id !== t) return; // closed, or reopened on another topic, meanwhile
      posted = true;
      apply(t, j);
      void poll();
    } catch (e) {
      if (id !== t) return;
      stopTimers();
      starting = false;
      progress = '';
      error = message(e);
    }
  }

  async function select(index: number) {
    const t = id;
    if (t === null) return;
    try {
      const j = await streamCall<Info>(`${t}/select/${index}`, 'POST');
      if (id === t) apply(t, j);
    } catch (e) {
      if (id === t) error = message(e);
    }
  }

  async function poll() {
    const t = id;
    if (t === null) return;
    // A 404 before the POST resolved only means the start has not registered yet.
    const wasPosted = posted;
    try {
      const j = await streamCall<Poll>(`${t}`);
      if (id !== t) return;
      if (j.starting) {
        starting = true;
        step = j.starting.step;
        tick();
        return;
      }
      starting = false;
      if (!j.stats) return;
      progress = streamProgress(j.stats, files, selected, Date.now() - started);
      if (j.stats.error) error = j.stats.error;
    } catch (e) {
      if (id !== t) return;
      const status = e instanceof HttpError ? e.status : 0;
      if (status === 410 || (status === 404 && wasPosted)) {
        stopTimers();
        starting = false;
        src = '';
        error = message(e) + ' — press Stream again';
      } else if (status === 502) {
        starting = false;
        progress = message(e);
      }
    }
  }

  // Closing does not stop the stream: a VLC playback keeps it alive until the reaper.
  function onclose() {
    stopTimers();
    video?.pause();
    src = '';
    id = null;
  }

  async function stop() {
    const t = id;
    dlg?.close();
    if (t !== null) {
      try {
        await fetch(`/api/stream/${t}`, { method: 'DELETE' });
      } catch {
        /* the reaper takes it */
      }
    }
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(external);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      window.prompt('Stream URL', external);
    }
  }

  onDestroy(stopTimers);
</script>

<dialog bind:this={dlg} class="modal" {onclose}>
  <div class="modal-box w-11/12 max-w-5xl p-3">
    {#if error}<p class="text-error text-sm">{error}</p>{/if}
    {#if src}
      <!-- svelte-ignore a11y_media_has_caption -->
      <video bind:this={video} class="w-full max-h-[70vh] bg-black" controls autoplay {src}></video>
    {/if}
    <div class="flex flex-wrap items-center gap-2 mt-2">
      {#if files.length > 1}
        <select class="select select-sm max-w-xs" value={selected} onchange={(e) => select(+e.currentTarget.value)}>
          {#each files as f (f.index)}<option value={f.index}>{f.name}</option>{/each}
        </select>
      {/if}
      <span class="text-sm text-base-content/70">{progress}</span>
      <span class="grow"></span>
      {#if external}
        <button type="button" class="btn btn-sm" onclick={copy}>{copied ? 'Copied ✓' : 'Copy URL for VLC'}</button>
      {/if}
      <button type="button" class="btn btn-sm btn-error" onclick={stop}>Stop</button>
    </div>
  </div>
  <form method="dialog" class="modal-backdrop"><button>close</button></form>
</dialog>
