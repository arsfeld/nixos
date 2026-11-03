<script lang="ts">
  let { onreload }: { onreload: () => void } = $props();
</script>

<div class="toast toast-top toast-center z-30">
  <button type="button" class="btn btn-sm btn-accent shadow-lg" onclick={onreload}>New releases · reload</button>
</div>
