<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  presentation: {
    type: Object,
    default: () => ({}),
  },
});

const isOpen = ref(false);
const { t } = useI18n();

const approvedCalendlyUrl = computed(() => {
  const presentation = props.presentation;
  if (
    presentation?.presentation_mode !== 'calendar_embed' ||
    presentation?.provider !== 'calendly'
  ) {
    return '';
  }

  try {
    const parsed = new URL(presentation.approved_url);
    const hostname = parsed.hostname.toLowerCase().replace(/\.$/, '');
    const isCalendly =
      hostname === 'calendly.com' || hostname.endsWith('.calendly.com');
    if (
      parsed.protocol !== 'https:' ||
      (parsed.port && parsed.port !== '443') ||
      parsed.username ||
      parsed.password ||
      !isCalendly
    ) {
      return '';
    }

    return parsed.href;
  } catch {
    return '';
  }
});

const linkLabel = computed(() => {
  const label = props.presentation?.link_label;
  return typeof label === 'string' && label.trim()
    ? label.trim()
    : t('APPOINTMENT_CALENDAR.BOOK');
});
</script>

<template>
  <section
    v-if="approvedCalendlyUrl"
    class="w-full overflow-hidden border rounded-lg border-n-weak bg-n-background"
  >
    <button
      type="button"
      class="w-full px-3 py-2 text-sm font-medium text-left text-n-brand hover:bg-n-alpha-2 focus:outline-none focus-visible:ring-2 focus-visible:ring-n-brand"
      :aria-expanded="isOpen"
      @click="isOpen = !isOpen"
    >
      {{ isOpen ? t('APPOINTMENT_CALENDAR.CLOSE') : linkLabel }}
    </button>
    <iframe
      v-if="isOpen"
      class="w-full min-h-[38rem] border-0 border-t border-n-weak"
      :src="approvedCalendlyUrl"
      :title="t('APPOINTMENT_CALENDAR.FRAME_TITLE')"
      loading="lazy"
      referrerpolicy="strict-origin-when-cross-origin"
      sandbox="allow-forms allow-popups allow-popups-to-escape-sandbox allow-same-origin allow-scripts"
    />
  </section>
</template>
