<script lang="ts">
  import { fetchImages, imgUrl, thumbUrl } from '../lib/api';
  import type { FilterState } from '../lib/filters.svelte';
  import { age, day, filesLabel, freshShort, isFresh, size } from '../lib/format';
  import type { Section, Topic } from '../lib/types';
  import AddButton from './AddButton.svelte';
  import StatusBadge from './StatusBadge.svelte';
  import TagPill from './TagPill.svelte';

  let {
    topic,
    section,
    now,
    topicUrl,
    isNew,
    fs,
    stream,
    ongallery,
    onstream,
  }: {
    topic: Topic;
    section: Section;
    now: number;
    topicUrl: string;
    isNew: boolean;
    fs: FilterState;
    stream: boolean;
    ongallery: (images: string[]) => void;
    onstream: (id: number) => void;
  } = $props();

  const PRODUCTION = { amateur: 'badge-success', artistic: 'badge-info', industrial: 'badge-neutral' } as const;
  const album = $derived(topic.kind === 'album');
  const fresh = $derived(isFresh(topic.added, now));
  let thumbFailed = $state(false);

  async function openTopicGallery() {
    try {
      const j = await fetchImages(topic.id);
      if (j.images.length) ongallery(j.images);
    } catch {
      /* the card keeps its thumbnail */
    }
  }
</script>

<div class={['card bg-base-200 shadow-sm overflow-hidden', isNew && 'is-new ring-2 ring-(--color-accent)']}>
  <figure class="relative aspect-[16/10] bg-black">
    {#if isNew}<span class="badge badge-accent badge-lg font-bold absolute top-2 left-2 z-[1]">NEW</span>{/if}
    {#if fresh && !album}
      <span class="badge badge-warning font-bold absolute top-2 right-2 z-[1]">{freshShort(topic.added, now)}</span>
    {/if}
    {#if topic.production}
      <span class={['badge font-bold absolute bottom-2 right-2 z-[1]', PRODUCTION[topic.production]]}>{topic.production}</span>
    {/if}
    {#if topic.images === null && !thumbFailed}
      <button type="button" class="block w-full h-full cursor-zoom-in" onclick={openTopicGallery}>
        <img class="w-full h-full object-cover" loading="lazy" src={thumbUrl(topic.id)} alt="" onerror={() => (thumbFailed = true)} />
      </button>
    {:else if topic.images?.length}
      <button type="button" class="block w-full h-full cursor-zoom-in" onclick={() => ongallery(topic.images ?? [])}>
        <img class="w-full h-full object-cover" loading="lazy" src={imgUrl(topic.images[0])} alt="" />
      </button>
    {:else}
      <div class="w-full h-full"></div>
    {/if}
  </figure>
  <div class="card-body p-3 gap-2">
    {#if topic.studio || topic.quality || topic.source}
      <div class="flex flex-wrap items-center gap-2 text-xs">
        {#if topic.studio}<span class="font-semibold uppercase tracking-wide text-primary">{topic.studio}</span>{/if}
        {#if topic.quality}<span class="badge badge-xs badge-outline">{topic.quality}</span>{/if}
        {#if topic.source}<span class="badge badge-xs badge-secondary">{topic.source}</span>{/if}
      </div>
    {/if}
    {#if topic.link || !topic.source}
      <a
        class="link link-hover font-semibold break-words"
        href={topic.link ?? topicUrl + topic.id}
        target="_blank"
        rel="noreferrer"
        title={topic.title}>{topic.name}</a
      >
    {:else}
      <span class="font-semibold break-words" title={topic.title}>{topic.name}</span>
    {/if}
    {#if topic.tags.length}
      <div class="flex flex-wrap gap-1">
        {#each topic.tags as tag (tag)}<TagPill {tag} {fs} />{/each}
      </div>
    {/if}
    <div class="text-xs text-base-content/60">
      {#if album}
        {filesLabel(topic.files ?? 0)} · first seen {day(topic.added)}
      {:else}
        {size(topic.size)} · ▲ {topic.seeders} ▼ {topic.leechers} ·
        {#if fresh}<span class="text-warning font-bold">uploaded {age(topic.added, now)}</span>{:else}{day(topic.added)}{/if}
      {/if}
    </div>
    <div class="card-actions mt-auto items-center">
      {#if album}
        {#if topic.link}
          <a class="btn btn-sm btn-primary" href={topic.link} target="_blank" rel="noreferrer">Open ↗</a>
        {/if}
      {:else}
        <AddButton {topic} {section} />
        {#if stream}
          <button type="button" class="btn btn-sm btn-ghost" onclick={() => onstream(topic.id)}>Stream ▶</button>
        {/if}
        {#if topic.status}<StatusBadge status={topic.status} />{/if}
      {/if}
    </div>
  </div>
</div>
