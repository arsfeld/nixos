<script lang="ts">
  import { imgUrl } from '../lib/api';

  let images = $state<string[]>([]);
  let dlg = $state<HTMLDialogElement>();

  export function open(keys: string[]) {
    images = keys;
    dlg?.showModal();
  }
</script>

<dialog bind:this={dlg} class="modal" onclose={() => (images = [])}>
  <button type="button" class="modal-box w-11/12 max-w-5xl p-2 cursor-zoom-out" onclick={() => dlg?.close()}>
    {#each images as img (img)}<img class="block mx-auto mb-3 max-w-full" loading="lazy" src={imgUrl(img)} alt="" />{/each}
  </button>
  <form method="dialog" class="modal-backdrop"><button>close</button></form>
</dialog>
