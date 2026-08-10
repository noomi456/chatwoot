<script>
export default {
  name: 'AgentCitations',
  props: {
    citations: {
      type: Array,
      default: () => [],
    },
  },
  computed: {
    safeCitations() {
      return this.citations.filter(citation => {
        if (!citation?.title?.trim() || !citation?.url) return false;

        try {
          return ['http:', 'https:'].includes(new URL(citation.url).protocol);
        } catch {
          return false;
        }
      });
    },
  },
};
</script>

<template>
  <ul
    v-if="safeCitations.length"
    aria-label="Sources"
    class="flex flex-wrap gap-1.5 mt-2"
  >
    <li
      v-for="citation in safeCitations"
      :key="`${citation.url}-${citation.title}`"
    >
      <a
        :href="citation.url"
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex max-w-64 items-center rounded-md border border-n-weak px-2 py-1 text-xs text-n-slate-11 hover:text-n-slate-12 hover:border-n-strong"
      >
        <span class="truncate">{{ citation.title }}</span>
      </a>
    </li>
  </ul>
</template>
