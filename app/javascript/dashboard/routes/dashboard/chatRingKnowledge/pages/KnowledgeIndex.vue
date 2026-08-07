<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import ChatRingKnowledgeAPI from 'dashboard/api/chatRingKnowledge';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';

const { t } = useI18n();
const store = useStore();
const inboxes = useMapGetter('inboxes/getInboxes');

const selectedInboxId = ref('');
const activeInput = ref('webpages');
const websiteUrl = ref('');
const selectedFile = ref(null);
const fileInput = ref(null);
const fileSources = ref([]);
const versions = ref([]);
const websiteVersion = ref(null);
const previewMaterial = ref(null);
const isLoading = ref(false);
const isSubmitting = ref(false);
let pollTimer;
let loadRequestId = 0;

const inboxOptions = computed(() =>
  inboxes.value.map(inbox => ({ value: inbox.id, label: inbox.name }))
);
const sourceTabs = computed(() => [
  {
    key: 'webpages',
    label: t('CHATRING_KNOWLEDGE.WEBPAGES'),
    icon: 'i-lucide-globe-2',
  },
  {
    key: 'files',
    label: t('CHATRING_KNOWLEDGE.FILES'),
    icon: 'i-lucide-folder-up',
  },
]);
const authorityOptions = computed(() => [
  {
    value: 'product_documentation',
    label: t('CHATRING_KNOWLEDGE.AUTHORITY.PRODUCT'),
  },
  {
    value: 'structured_commercial',
    label: t('CHATRING_KNOWLEDGE.AUTHORITY.COMMERCIAL'),
  },
  { value: 'marketing', label: t('CHATRING_KNOWLEDGE.AUTHORITY.MARKETING') },
  {
    value: 'approved_legal_policy',
    label: t('CHATRING_KNOWLEDGE.AUTHORITY.LEGAL'),
  },
  {
    value: 'approved_compliance',
    label: t('CHATRING_KNOWLEDGE.AUTHORITY.COMPLIANCE'),
  },
]);

const activeFileSources = computed(() =>
  fileSources.value.filter(source => source.status !== 'disabled')
);
const readyFiles = computed(() =>
  activeFileSources.value.filter(source => source.status === 'ready')
);
const websiteDocuments = computed(() => websiteVersion.value?.documents || []);
const hasActiveWork = computed(
  () =>
    activeFileSources.value.some(source =>
      ['uploaded', 'parsing'].includes(source.status)
    ) ||
    versions.value.some(
      version =>
        ['pending', 'crawling', 'ingesting'].includes(version.status) ||
        (version.status === 'ready' && version.publish_on_ready)
    )
);
const canUpdateKnowledge = computed(
  () =>
    Boolean(websiteDocuments.value.length || readyFiles.value.length) &&
    !hasActiveWork.value
);
const materials = computed(() => [
  ...websiteDocuments.value.map(document => ({
    ...document,
    material_key: `website-${document.id}`,
    material_type: 'website',
    display_name: document.title,
    display_reference: document.public_url,
    status:
      document.provider_status === 'ready' ? 'ready' : document.provider_status,
    last_processed_at: document.updated_at,
  })),
  ...activeFileSources.value.map(source => ({
    ...source,
    material_key: `file-${source.id}`,
    material_type: 'file',
    display_name: source.filename,
    display_reference: null,
    character_count: source.markdown?.length || source.character_count || 0,
    last_processed_at: source.parsed_at || source.updated_at,
  })),
]);

const apiError = error =>
  error?.response?.data?.error ||
  error?.message ||
  t('CHATRING_KNOWLEDGE.ERROR');
const formatNumber = value => new Intl.NumberFormat().format(value || 0);
const formatDate = value => (value ? new Date(value).toLocaleString() : '—');

const loadWebsiteVersion = async (loadedVersions, requestId, inboxId) => {
  const selected = loadedVersions.find(
    version =>
      version.root_url &&
      ['ready', 'published', 'retired'].includes(version.status)
  );
  if (!selected) {
    websiteVersion.value = null;
    return;
  }

  const response = await ChatRingKnowledgeAPI.version(inboxId, selected.id);
  if (requestId === loadRequestId && inboxId === selectedInboxId.value) {
    websiteVersion.value = response.data;
    websiteUrl.value ||= response.data.root_url || '';
  }
};

const loadKnowledge = async ({ quiet = false } = {}) => {
  if (!selectedInboxId.value) return;
  const inboxId = selectedInboxId.value;
  loadRequestId += 1;
  const requestId = loadRequestId;
  if (!quiet) isLoading.value = true;
  try {
    const [sourceResponse, versionResponse] = await Promise.all([
      ChatRingKnowledgeAPI.fileSources(inboxId),
      ChatRingKnowledgeAPI.versions(inboxId),
    ]);
    if (requestId !== loadRequestId || inboxId !== selectedInboxId.value)
      return;

    fileSources.value = sourceResponse.data;
    versions.value = versionResponse.data.versions;
    await loadWebsiteVersion(versions.value, requestId, inboxId);
  } catch (error) {
    if (requestId === loadRequestId && !quiet) useAlert(apiError(error));
  } finally {
    if (requestId === loadRequestId) isLoading.value = false;
  }
};

const submitWebsite = async () => {
  if (!websiteUrl.value.trim()) return;
  isSubmitting.value = true;
  try {
    await ChatRingKnowledgeAPI.website(
      selectedInboxId.value,
      websiteUrl.value.trim()
    );
    useAlert(t('CHATRING_KNOWLEDGE.WEBSITE_QUEUED'));
    await loadKnowledge({ quiet: true });
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isSubmitting.value = false;
  }
};

const chooseFile = event => {
  const [file] = event.target.files;
  selectedFile.value = file || null;
};

const uploadFile = async () => {
  if (!selectedFile.value) return;
  if (selectedFile.value.size > 50 * 1024 * 1024) {
    useAlert(t('CHATRING_KNOWLEDGE.FILE_TOO_LARGE'));
    return;
  }
  isSubmitting.value = true;
  try {
    const response = await ChatRingKnowledgeAPI.uploadFile(
      selectedInboxId.value,
      selectedFile.value,
      'product_documentation'
    );
    selectedFile.value = null;
    if (fileInput.value) fileInput.value.value = '';
    useAlert(
      response.data.reused
        ? t('CHATRING_KNOWLEDGE.FILE_REUSED')
        : t('CHATRING_KNOWLEDGE.FILE_QUEUED')
    );
    await loadKnowledge({ quiet: true });
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isSubmitting.value = false;
  }
};

const updateKnowledge = async () => {
  if (!canUpdateKnowledge.value) return;
  isSubmitting.value = true;
  try {
    await ChatRingKnowledgeAPI.buildVersion(
      selectedInboxId.value,
      websiteVersion.value?.id
    );
    useAlert(t('CHATRING_KNOWLEDGE.UPDATE_QUEUED'));
    await loadKnowledge({ quiet: true });
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isSubmitting.value = false;
  }
};

const retryMaterial = async material => {
  if (material.material_type === 'website') {
    websiteUrl.value = websiteVersion.value?.root_url || material.public_url;
    await submitWebsite();
    return;
  }
  if (['failed', 'parse_indeterminate'].includes(material.status)) {
    try {
      await ChatRingKnowledgeAPI.retryFile(selectedInboxId.value, material.id);
      useAlert(t('CHATRING_KNOWLEDGE.FILE_QUEUED'));
      await loadKnowledge({ quiet: true });
    } catch (error) {
      useAlert(apiError(error));
    }
    return;
  }
  await updateKnowledge();
};

const deleteMaterial = async material => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('CHATRING_KNOWLEDGE.DELETE_CONFIRM'))) return;
  try {
    if (material.material_type === 'website') {
      await ChatRingKnowledgeAPI.deleteWebsiteMaterial(
        selectedInboxId.value,
        websiteVersion.value.id,
        material.id
      );
    } else {
      await ChatRingKnowledgeAPI.disableFile(
        selectedInboxId.value,
        material.id
      );
    }
    previewMaterial.value = null;
    useAlert(t('CHATRING_KNOWLEDGE.DELETE_QUEUED'));
    await loadKnowledge({ quiet: true });
  } catch (error) {
    useAlert(apiError(error));
  }
};

const preview = async material => {
  if (previewMaterial.value?.material_key === material.material_key) {
    previewMaterial.value = null;
    return;
  }
  try {
    if (material.material_type === 'file') {
      const response = await ChatRingKnowledgeAPI.fileSource(
        selectedInboxId.value,
        material.id
      );
      previewMaterial.value = { ...material, ...response.data };
    } else {
      previewMaterial.value = material;
    }
  } catch (error) {
    useAlert(apiError(error));
  }
};

const updateAuthority = async value => {
  if (!previewMaterial.value || previewMaterial.value.material_type !== 'file')
    return;
  try {
    await ChatRingKnowledgeAPI.updateFile(
      selectedInboxId.value,
      previewMaterial.value.id,
      value
    );
    previewMaterial.value.authority_class = value;
    useAlert(t('CHATRING_KNOWLEDGE.AUTHORITY_UPDATED'));
    await loadKnowledge({ quiet: true });
  } catch (error) {
    useAlert(apiError(error));
  }
};

watch(selectedInboxId, () => {
  loadRequestId += 1;
  websiteUrl.value = '';
  previewMaterial.value = null;
  loadKnowledge();
});

watch(hasActiveWork, active => {
  window.clearInterval(pollTimer);
  pollTimer = active
    ? window.setInterval(() => loadKnowledge({ quiet: true }), 5000)
    : undefined;
});

onMounted(async () => {
  await store.dispatch('inboxes/get');
  selectedInboxId.value ||= inboxOptions.value[0]?.value || '';
});

onBeforeUnmount(() => window.clearInterval(pollTimer));
</script>

<template>
  <main class="flex overflow-y-auto flex-col flex-1 bg-n-background">
    <header class="px-8 py-6 border-b border-n-weak">
      <div class="flex justify-between items-end gap-4 max-w-6xl mx-auto">
        <div>
          <h1 class="text-xl font-medium text-n-slate-12">
            {{ t('CHATRING_KNOWLEDGE.TITLE') }}
          </h1>
          <p class="mt-1 text-sm text-n-slate-11">
            {{ t('CHATRING_KNOWLEDGE.DESCRIPTION') }}
          </p>
        </div>
        <div class="grid gap-1">
          <label
            class="text-sm font-medium text-n-slate-12"
            for="knowledge-inbox"
          >
            {{ t('CHATRING_KNOWLEDGE.SELECT_INBOX') }}
          </label>
          <Select
            id="knowledge-inbox"
            v-model="selectedInboxId"
            :options="inboxOptions"
            :placeholder="t('CHATRING_KNOWLEDGE.SELECT_INBOX')"
          />
        </div>
      </div>
    </header>

    <div class="grid gap-6 px-8 py-6 max-w-6xl w-full mx-auto">
      <section
        class="rounded-xl outline outline-1 outline-n-weak bg-n-solid-1 p-6"
      >
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('CHATRING_KNOWLEDGE.SOURCES') }}
        </h2>
        <div
          class="grid grid-cols-2 gap-1 p-1 mt-5 rounded-lg bg-n-alpha-2"
          role="tablist"
        >
          <button
            v-for="tab in sourceTabs"
            :key="tab.key"
            type="button"
            role="tab"
            :aria-selected="activeInput === tab.key"
            class="flex justify-center items-center gap-2 rounded-md py-2 text-sm"
            :class="
              activeInput === tab.key
                ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                : 'text-n-slate-11'
            "
            @click="activeInput = tab.key"
          >
            <span :class="tab.icon" class="size-4" />
            {{ tab.label }}
          </button>
        </div>

        <form
          v-if="activeInput === 'webpages'"
          class="flex items-end gap-3 mt-6"
          @submit.prevent="submitWebsite"
        >
          <Input
            v-model="websiteUrl"
            type="url"
            class="flex-1"
            :label="t('CHATRING_KNOWLEDGE.WEBSITE_URL')"
            placeholder="https://example.com"
          />
          <Button
            :label="t('CHATRING_KNOWLEDGE.ADD_WEBSITE')"
            :is-loading="isSubmitting"
            type="submit"
          />
        </form>

        <form v-else class="grid gap-4 mt-6" @submit.prevent="uploadFile">
          <label
            class="grid place-items-center p-10 rounded-xl border border-dashed border-n-strong cursor-pointer"
          >
            <span class="i-lucide-cloud-upload size-8 text-n-brand" />
            <span class="mt-3 text-sm font-medium text-n-slate-12">
              {{ selectedFile?.name || t('CHATRING_KNOWLEDGE.FILE_PROMPT') }}
            </span>
            <span class="mt-1 text-sm text-n-slate-10">
              {{ t('CHATRING_KNOWLEDGE.FILE_SUPPORT') }}
            </span>
            <input
              ref="fileInput"
              class="sr-only"
              type="file"
              accept=".pdf,.docx,application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
              @change="chooseFile"
            />
          </label>
          <div class="flex justify-end">
            <Button
              :disabled="!selectedFile"
              :label="t('CHATRING_KNOWLEDGE.UPLOAD')"
              :is-loading="isSubmitting"
              type="submit"
            />
          </div>
        </form>
      </section>

      <section
        class="rounded-xl outline outline-1 outline-n-weak bg-n-solid-1 overflow-hidden"
      >
        <div
          class="flex justify-between items-center px-6 py-4 border-b border-n-weak"
        >
          <div>
            <h2 class="text-base font-medium text-n-slate-12">
              {{ t('CHATRING_KNOWLEDGE.TRAINING_MATERIALS') }}
            </h2>
            <p class="text-sm text-n-slate-10">
              {{ t('CHATRING_KNOWLEDGE.ADDITIVE_NOTE') }}
            </p>
          </div>
          <Button
            :disabled="!canUpdateKnowledge"
            :label="t('CHATRING_KNOWLEDGE.UPDATE_KNOWLEDGE')"
            :is-loading="isSubmitting || hasActiveWork"
            @click="updateKnowledge"
          />
        </div>

        <div v-if="isLoading" class="p-8 text-center text-sm text-n-slate-10">
          {{ t('CHATRING_KNOWLEDGE.LOADING') }}
        </div>
        <table v-else class="w-full text-sm">
          <thead class="text-left text-n-slate-10 bg-n-alpha-2">
            <tr>
              <th class="px-6 py-3 font-medium">
                {{ t('CHATRING_KNOWLEDGE.MATERIAL') }}
              </th>
              <th class="px-4 py-3 font-medium">
                {{ t('CHATRING_KNOWLEDGE.TYPE') }}
              </th>
              <th class="px-4 py-3 font-medium">
                {{ t('CHATRING_KNOWLEDGE.CHARACTERS') }}
              </th>
              <th class="px-4 py-3 font-medium">
                {{ t('CHATRING_KNOWLEDGE.STATUS') }}
              </th>
              <th class="px-4 py-3 font-medium">
                {{ t('CHATRING_KNOWLEDGE.LAST_PROCESSED') }}
              </th>
              <th class="px-6 py-3 font-medium text-right">
                {{ t('CHATRING_KNOWLEDGE.ACTION') }}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-n-weak">
            <tr v-for="material in materials" :key="material.material_key">
              <td class="px-6 py-4">
                <button
                  type="button"
                  class="text-left"
                  @click="preview(material)"
                >
                  <span class="block text-n-slate-12">{{
                    material.display_name
                  }}</span>
                  <span
                    v-if="material.display_reference"
                    class="block mt-1 text-xs text-n-brand"
                  >
                    {{ material.display_reference }}
                  </span>
                </button>
                <p
                  v-if="material.failure_message"
                  class="mt-1 text-xs text-n-ruby-9"
                >
                  {{ material.failure_message }}
                </p>
              </td>
              <td class="px-4 py-4 uppercase text-n-slate-11">
                {{
                  material.material_type === 'website'
                    ? t('CHATRING_KNOWLEDGE.WEBSITE')
                    : material.source_kind
                }}
              </td>
              <td class="px-4 py-4 text-n-slate-11">
                {{ formatNumber(material.character_count) }}
              </td>
              <td class="px-4 py-4 text-n-slate-11">{{ material.status }}</td>
              <td class="px-4 py-4 text-n-slate-11">
                {{ formatDate(material.last_processed_at) }}
              </td>
              <td class="px-6 py-4 text-right">
                <Button
                  sm
                  slate
                  ghost
                  :label="t('CHATRING_KNOWLEDGE.PREVIEW')"
                  @click="preview(material)"
                />
                <Button
                  sm
                  slate
                  ghost
                  :label="t('CHATRING_KNOWLEDGE.REPROCESS')"
                  @click="retryMaterial(material)"
                />
                <Button
                  sm
                  ruby
                  ghost
                  :label="t('CHATRING_KNOWLEDGE.DELETE')"
                  @click="deleteMaterial(material)"
                />
              </td>
            </tr>
            <tr v-if="!materials.length">
              <td colspan="6" class="px-6 py-8 text-center text-n-slate-10">
                {{ t('CHATRING_KNOWLEDGE.NO_MATERIALS') }}
              </td>
            </tr>
          </tbody>
        </table>

        <div
          v-if="previewMaterial"
          class="grid gap-4 border-t border-n-weak px-6 py-5 text-sm"
        >
          <div class="flex justify-between gap-4">
            <div>
              <h3 class="font-medium text-n-slate-12">
                {{ previewMaterial.display_name || previewMaterial.filename }}
              </h3>
              <p class="mt-1 text-xs text-n-slate-10">
                {{ previewMaterial.source_reference }}
              </p>
            </div>
            <Select
              v-if="previewMaterial.material_type === 'file'"
              :model-value="previewMaterial.authority_class"
              :options="authorityOptions"
              @update:model-value="updateAuthority"
            />
          </div>
          <div>
            <p class="font-medium text-n-slate-12">
              {{ t('CHATRING_KNOWLEDGE.EXTRACTED_CONTENT') }}
            </p>
            <pre
              class="mt-2 max-h-80 overflow-auto whitespace-pre-wrap rounded-lg bg-n-alpha-2 p-4 text-xs text-n-slate-11"
              :text-content.prop="previewMaterial.markdown"
            />
          </div>
          <div v-if="previewMaterial.headings?.length">
            <p class="font-medium text-n-slate-12">
              {{ t('CHATRING_KNOWLEDGE.HEADINGS') }}
            </p>
            <ul class="mt-2 grid gap-1 text-n-slate-11">
              <li
                v-for="heading in previewMaterial.headings"
                :key="`${heading.level}-${heading.path}`"
              >
                {{ heading.path }}
              </li>
            </ul>
          </div>
        </div>
      </section>
    </div>
  </main>
</template>
