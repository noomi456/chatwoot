<script setup>
defineProps({
  questions: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['select']);
</script>

<template>
  <div
    v-if="questions.length"
    class="flex flex-wrap gap-2"
    :aria-label="$t('SUGGESTED_QUESTIONS')"
  >
    <button
      v-for="question in questions.slice(0, 2)"
      :key="question"
      type="button"
      class="px-3 py-2 text-sm text-left transition-colors border rounded-full border-n-strong text-n-slate-12 bg-n-solid-1 hover:bg-n-alpha-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
      @click="emit('select', question)"
    >
      {{ question }}
    </button>
  </div>
</template>
