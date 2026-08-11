<script setup>
import { computed } from 'vue';

const props = defineProps({
  presentation: {
    type: Object,
    default: () => ({}),
  },
});

const microsite = computed(() => {
  const title = props.presentation?.title?.trim();
  const expiresAt = Date.parse(props.presentation?.expires_at);
  if (!title || !Number.isFinite(expiresAt) || expiresAt <= Date.now())
    return null;

  try {
    const parsed = new URL(props.presentation.url);
    if (!['http:', 'https:'].includes(parsed.protocol)) return null;

    return {
      title,
      url: parsed.href,
      sectionTypes: Array(props.presentation.section_types).slice(0, 3),
    };
  } catch {
    return null;
  }
});
</script>

<template>
  <a
    v-if="microsite"
    :href="microsite.url"
    target="_blank"
    rel="noopener noreferrer"
    class="block w-full p-3 border rounded-lg border-n-weak bg-n-background hover:border-n-strong"
  >
    <span class="block text-xs font-medium uppercase text-n-brand">
      {{ $t('PERSONALIZED_PAGE') }}
    </span>
    <span class="block mt-1 text-sm font-semibold text-n-slate-12">
      {{ microsite.title }}
    </span>
    <span
      v-if="microsite.sectionTypes.length"
      class="block mt-1 text-xs text-n-slate-10"
    >
      {{ microsite.sectionTypes.join(' · ') }}
    </span>
  </a>
</template>
