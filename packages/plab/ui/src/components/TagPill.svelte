<script lang="ts">
  import type { FilterState } from '../lib/filters.svelte';

  let { tag, fs }: { tag: string; fs: FilterState } = $props();
</script>

<button
  type="button"
  class={['badge badge-sm badge-outline cursor-pointer', fs.st.tags.includes(tag) && 'badge-primary']}
  onclick={() => fs.toggleTag(tag)}>{tag}</button
>
