<script lang="ts">
  import { clock } from '../lib/clock.svelte';
  import { duration } from '../lib/format';
  import { jobWhen } from '../lib/jobtime';
  import type { Job } from '../lib/types';

  let { job }: { job: Job } = $props();
  const BADGE = { running: 'badge-success', watching: 'badge-neutral', idle: 'badge-neutral', restarting: 'badge-error' } as const;
  const LEVEL: Record<string, string> = { ERROR: 'text-error', WARN: 'text-warning' };
  const last = $derived(job.runs.find((r) => r.finished !== null));
  const result = (ok: boolean | null, error: string | null) =>
    ok ? 'ok' : error === 'interrupted' ? 'interrupted' : (error ?? 'failed');
</script>

<div class="card bg-base-200 shadow-sm">
  <div class="card-body p-4 gap-2">
    <div class="flex flex-wrap items-center gap-2">
      <h2 class="card-title text-base">{job.name}</h2>
      <span class={['badge badge-sm', BADGE[job.state]]}
        >{job.state}{#if job.state === 'watching' && job.pending} · {job.pending} pending{/if}</span
      >
      <span class="ml-auto text-xs text-base-content/60">{jobWhen(job, clock.now)}</span>
    </div>
    {#if job.step}
      <p class="text-sm break-words">
        {job.step.msg} <span class="text-xs text-base-content/50">{duration(Math.max(0, clock.now - job.step.at))} ago</span>
      </p>
    {/if}
    {#if job.progress}
      <div class="flex items-center gap-2">
        <progress class="progress progress-primary grow" value={job.progress[0]} max={job.progress[1]}></progress>
        <span class="text-xs">{job.progress[0]} / {job.progress[1]}</span>
      </div>
    {/if}
    {#if last}
      <p class="text-xs">
        last run {last.ok ? 'ok' : last.error === 'interrupted' ? 'interrupted' : 'failed'} · took {duration(
          (last.finished ?? last.started) - last.started,
        )}
      </p>
      {#if !last.ok && last.error && last.error !== 'interrupted'}
        <details>
          <summary class="text-xs text-error cursor-pointer">error</summary>
          <pre class="text-xs whitespace-pre-wrap break-words">{last.error}</pre>
        </details>
      {/if}
    {/if}
    <details class="collapse collapse-arrow bg-base-100">
      <summary class="collapse-title text-sm">Log</summary>
      <div class="collapse-content">
        <ul class="text-xs font-mono flex flex-col gap-1">
          {#each [...job.lines].reverse() as l, i (i)}<li class={LEVEL[l.level] ?? ''}>{l.msg}</li>{/each}
        </ul>
      </div>
    </details>
    <details class="collapse collapse-arrow bg-base-100">
      <summary class="collapse-title text-sm">History</summary>
      <div class="collapse-content overflow-x-auto">
        <table class="table table-xs">
          <thead><tr><th>started</th><th>took</th><th>result</th></tr></thead>
          <tbody>
            {#each job.runs as r, i (i)}
              <tr>
                <td>{new Date(r.started * 1000).toLocaleString()}</td>
                <td>{r.finished === null ? 'running' : duration(r.finished - r.started)}</td>
                <td class={r.ok ? 'text-success' : r.ok === false ? 'text-error' : ''}>{r.finished === null ? '…' : result(r.ok, r.error)}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    </details>
  </div>
</div>
