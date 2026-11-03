<script lang="ts">
  import { STATUS_COLOR, statusText } from '../lib/status';
  import type { Status } from '../lib/types';

  let { status }: { status: Status } = $props();
  const cls = $derived(['badge badge-sm max-w-full truncate', STATUS_COLOR[status.kind]]);
  const link = $derived('link' in status ? status.link : null);
</script>

{#if link}
  <a class={cls} href={link} target="_blank" rel="noreferrer" title="Open in Stash">{statusText(status)}</a>
{:else}
  <span class={cls} title={status.kind === 'failed' ? status.detail : undefined}>{statusText(status)}</span>
{/if}
