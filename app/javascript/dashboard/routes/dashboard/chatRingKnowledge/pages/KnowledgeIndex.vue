<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import ChatRingKnowledgeAPI from 'dashboard/api/chatRingKnowledge';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';

const { t } = useI18n();

const activeInput = ref('webpages');
const webpageInputUrl = ref('');
const fileInput = ref(null);
const materials = ref([]);
const previewMaterial = ref(null);
const searchQuery = ref('');
const isLoading = ref(false);
const isSubmitting = ref(false);
let pollTimer;

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

const filteredMaterials = computed(() => {
  const query = searchQuery.value.trim().toLocaleLowerCase();
  if (!query) return materials.value;

  return materials.value.filter(material =>
    [material.name, material.public_url, material.type]
      .filter(Boolean)
      .some(value => value.toLocaleLowerCase().includes(query))
  );
});
const hasActiveWork = computed(() =>
  materials.value.some(material =>
    ['processing', 'updating'].includes(material.status)
  )
);

const apiError = error =>
  error?.response?.data?.error ||
  error?.message ||
  t('CHATRING_KNOWLEDGE.ERROR');
const formatNumber = value => new Intl.NumberFormat().format(value || 0);
const formatDate = value => (value ? new Date(value).toLocaleString() : '—');
const statusLabel = status =>
  ({
    processing: t('CHATRING_KNOWLEDGE.MATERIAL_STATUS.PROCESSING'),
    available: t('CHATRING_KNOWLEDGE.MATERIAL_STATUS.AVAILABLE'),
    updating: t('CHATRING_KNOWLEDGE.MATERIAL_STATUS.UPDATING'),
    refresh_failed: t('CHATRING_KNOWLEDGE.MATERIAL_STATUS.REFRESH_FAILED'),
    failed: t('CHATRING_KNOWLEDGE.MATERIAL_STATUS.FAILED'),
  })[status] || status;

const loadMaterials = async ({ quiet = false } = {}) => {
  if (!quiet) isLoading.value = true;
  try {
    const response = await ChatRingKnowledgeAPI.materials();
    materials.value = response.data;
    if (previewMaterial.value) {
      const current = materials.value.find(
        material => material.id === previewMaterial.value.id
      );
      if (!current) previewMaterial.value = null;
    }
  } catch (error) {
    if (!quiet) useAlert(apiError(error));
  } finally {
    if (!quiet) isLoading.value = false;
  }
};

const isCompleteWebsite = value => {
  try {
    const normalized = /^https?:\/\//i.test(value) ? value : `https://${value}`;
    const url = new URL(normalized);
    return (!url.pathname || url.pathname === '/') && !url.search && !url.hash;
  } catch {
    return false;
  }
};

const submitWebpageSource = async () => {
  const url = webpageInputUrl.value.trim();
  if (!url) return;

  isSubmitting.value = true;
  try {
    if (isCompleteWebsite(url)) {
      await ChatRingKnowledgeAPI.addWebsite(url);
      useAlert(t('CHATRING_KNOWLEDGE.WEBSITE_QUEUED'));
    } else {
      await ChatRingKnowledgeAPI.addWebpage(url);
      useAlert(t('CHATRING_KNOWLEDGE.WEBPAGE_QUEUED'));
    }
    webpageInputUrl.value = '';
    await loadMaterials({ quiet: true });
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isSubmitting.value = false;
  }
};

const uploadFile = async file => {
  if (!file) return;
  if (file.size > 50 * 1024 * 1024) {
    useAlert(t('CHATRING_KNOWLEDGE.FILE_TOO_LARGE'));
    return;
  }
  isSubmitting.value = true;
  try {
    const response = await ChatRingKnowledgeAPI.uploadFile(file);
    if (fileInput.value) fileInput.value.value = '';
    useAlert(
      response.data.reused
        ? t('CHATRING_KNOWLEDGE.FILE_REUSED')
        : t('CHATRING_KNOWLEDGE.FILE_QUEUED')
    );
    await loadMaterials({ quiet: true });
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isSubmitting.value = false;
  }
};

const chooseFile = async event => {
  const [file] = event.target.files;
  await uploadFile(file);
};

const dropFile = async event => {
  const [file] = event.dataTransfer.files;
  await uploadFile(file);
};

const rerunMaterial = async material => {
  try {
    await ChatRingKnowledgeAPI.rerunMaterial(material.id);
    useAlert(t('CHATRING_KNOWLEDGE.RERUN_QUEUED'));
    await loadMaterials({ quiet: true });
  } catch (error) {
    useAlert(apiError(error));
  }
};

const deleteMaterial = async material => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('CHATRING_KNOWLEDGE.DELETE_CONFIRM'))) return;
  try {
    await ChatRingKnowledgeAPI.deleteMaterial(material.id);
    previewMaterial.value = null;
    materials.value = materials.value.filter(item => item.id !== material.id);
    useAlert(t('CHATRING_KNOWLEDGE.DELETED'));
  } catch (error) {
    useAlert(apiError(error));
  }
};

const preview = async material => {
  if (previewMaterial.value?.id === material.id) {
    previewMaterial.value = null;
    return;
  }
  try {
    const response = await ChatRingKnowledgeAPI.material(material.id);
    previewMaterial.value = response.data;
  } catch (error) {
    useAlert(apiError(error));
  }
};

watch(hasActiveWork, active => {
  window.clearInterval(pollTimer);
  pollTimer = active
    ? window.setInterval(() => loadMaterials({ quiet: true }), 5000)
    : undefined;
});

onMounted(loadMaterials);
onBeforeUnmount(() => window.clearInterval(pollTimer));
</script>

<template>
  <main class="flex overflow-y-auto flex-col flex-1 bg-n-background">
    <header class="px-8 py-6 border-b border-n-weak">
      <div class="max-w-6xl mx-auto">
        <h1 class="text-xl font-medium text-n-slate-12">
          {{ t('CHATRING_KNOWLEDGE.TITLE') }}
        </h1>
        <p class="mt-1 text-sm text-n-slate-11">
          {{ t('CHATRING_KNOWLEDGE.DESCRIPTION') }}
        </p>
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

        <div v-if="activeInput === 'webpages'" class="grid gap-5 mt-6">
          <form
            class="flex items-end gap-3"
            @submit.prevent="submitWebpageSource"
          >
            <Input
              v-model="webpageInputUrl"
              type="text"
              class="flex-1"
              :label="t('CHATRING_KNOWLEDGE.WEBPAGE_INPUT_URL')"
              :placeholder="t('CHATRING_KNOWLEDGE.WEBPAGE_INPUT_PLACEHOLDER')"
            />
            <Button
              :label="
                isCompleteWebsite(webpageInputUrl.trim())
                  ? t('CHATRING_KNOWLEDGE.ADD_WEBSITE')
                  : t('CHATRING_KNOWLEDGE.ADD_PAGE')
              "
              :is-loading="isSubmitting"
              type="submit"
            />
          </form>
        </div>

        <div v-else class="grid gap-4 mt-6">
          <label
            class="grid place-items-center p-10 rounded-xl border border-dashed border-n-strong cursor-pointer"
            @dragover.prevent
            @drop.prevent="dropFile"
          >
            <span class="i-lucide-cloud-upload size-8 text-n-brand" />
            <span class="mt-3 text-sm font-medium text-n-slate-12">
              {{ t('CHATRING_KNOWLEDGE.FILE_PROMPT') }}
            </span>
            <span class="mt-1 text-sm text-n-slate-10">
              {{ t('CHATRING_KNOWLEDGE.FILE_SUPPORT') }}
            </span>
            <input
              ref="fileInput"
              class="sr-only"
              type="file"
              accept=".pdf,.docx,.doc,.odt,.rtf,.xlsx,.xls,.html,.htm,.xhtml"
              @change="chooseFile"
            />
          </label>
          <p v-if="isSubmitting" class="text-center text-sm text-n-slate-10">
            {{ t('CHATRING_KNOWLEDGE.FILE_UPLOADING') }}
          </p>
        </div>
      </section>

      <section
        class="rounded-xl outline outline-1 outline-n-weak bg-n-solid-1 overflow-hidden"
      >
        <div class="grid gap-4 px-6 py-4 border-b border-n-weak">
          <h2 class="text-base font-medium text-n-slate-12">
            {{ t('CHATRING_KNOWLEDGE.TRAINING_MATERIALS') }}
          </h2>
          <p class="text-sm text-n-slate-10">
            {{ t('CHATRING_KNOWLEDGE.TRAINING_MATERIALS_NOTE') }}
          </p>
          <Input
            v-model="searchQuery"
            :placeholder="t('CHATRING_KNOWLEDGE.SEARCH')"
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
            <tr
              v-for="material in filteredMaterials"
              :key="material.material_key"
            >
              <td class="px-6 py-4">
                <button
                  type="button"
                  class="text-left"
                  @click="preview(material)"
                >
                  <span class="block text-n-slate-12">{{ material.name }}</span>
                  <span
                    v-if="material.public_url"
                    class="block mt-1 text-xs text-n-brand"
                  >
                    {{ material.public_url }}
                  </span>
                </button>
              </td>
              <td class="px-4 py-4 uppercase text-n-slate-11">
                {{ material.type }}
              </td>
              <td class="px-4 py-4 text-n-slate-11">
                {{ formatNumber(material.characters) }}
              </td>
              <td class="px-4 py-4 text-n-slate-11">
                {{ statusLabel(material.status) }}
              </td>
              <td class="px-4 py-4 text-n-slate-11">
                {{ formatDate(material.extracted_at || material.updated_at) }}
              </td>
              <td class="px-6 py-4 text-right">
                <Button
                  sm
                  slate
                  ghost
                  :disabled="
                    ['processing', 'updating'].includes(material.status)
                  "
                  :label="t('CHATRING_KNOWLEDGE.RERUN')"
                  @click="rerunMaterial(material)"
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
            <tr v-if="!filteredMaterials.length">
              <td colspan="6" class="px-6 py-8 text-center text-n-slate-10">
                {{ t('CHATRING_KNOWLEDGE.NO_MATERIALS') }}
              </td>
            </tr>
          </tbody>
        </table>

        <div
          v-if="previewMaterial?.markdown"
          class="grid gap-4 border-t border-n-weak px-6 py-5 text-sm"
        >
          <div>
            <h3 class="font-medium text-n-slate-12">
              {{ previewMaterial.name }}
            </h3>
            <p
              v-if="previewMaterial.source_reference"
              class="mt-1 text-xs text-n-slate-10"
            >
              {{ previewMaterial.source_reference }}
            </p>
          </div>
          <div>
            <p class="font-medium text-n-slate-12">
              {{
                previewMaterial.available_to_ai
                  ? t('CHATRING_KNOWLEDGE.CONTENT_AVAILABLE')
                  : t('CHATRING_KNOWLEDGE.CONTENT_NOT_AVAILABLE')
              }}
            </p>
            <pre
              class="mt-2 max-h-80 overflow-auto whitespace-pre-wrap rounded-lg bg-n-alpha-2 p-4 text-xs text-n-slate-11"
              :text-content.prop="previewMaterial.markdown"
            />
          </div>
        </div>
      </section>
    </div>
  </main>
</template>
