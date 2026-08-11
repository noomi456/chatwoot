<script setup>
defineProps({
  starters: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['select']);
</script>

<template>
  <section class="px-5 pt-4" :aria-label="$t('CONVERSATION_STARTERS_TITLE')">
    <p class="mb-2 text-sm font-medium text-n-slate-11">
      {{ $t('CONVERSATION_STARTERS_TITLE') }}
    </p>
    <div class="flex flex-wrap gap-2">
      <button
        v-for="(starter, index) in starters"
        :key="`${index}:${starter.label}:${starter.prompt}`"
        type="button"
        class="px-3 py-2 text-sm text-left transition-colors border rounded-full border-n-strong text-n-slate-12 bg-n-solid-1 hover:bg-n-alpha-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
        @click="emit('select', starter.prompt)"
      >
        {{ starter.label }}
      </button>
    </div>
  </section>
</template>
