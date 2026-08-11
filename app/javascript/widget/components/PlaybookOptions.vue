<script setup>
defineProps({
  options: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['select']);
</script>

<template>
  <div
    v-if="options.length"
    class="flex flex-wrap gap-2"
    aria-label="Playbook options"
  >
    <button
      v-for="option in options"
      :key="`${option.label}-${option.value}`"
      type="button"
      class="px-3 py-2 text-sm text-left border rounded-lg border-n-strong text-n-slate-12 bg-n-solid-1 hover:bg-n-alpha-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
      @click="emit('select', option)"
    >
      {{ option.label }}
    </button>
  </div>
</template>
