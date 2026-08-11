<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import ChatRingEngagementsAPI from 'dashboard/api/chatRingEngagements';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const { t } = useI18n();
const engagements = ref([]);
const selectedInboxId = ref('');
const isLoading = ref(true);
const isSaving = ref(false);
const form = ref({ enabled: false, starters: [] });
let nextStarterKey = 0;
const newStarterKey = () => {
  nextStarterKey += 1;
  return nextStarterKey;
};

const selectedEngagement = computed(() =>
  engagements.value.find(
    engagement =>
      String(engagement.inbox.id) === String(selectedInboxId.value)
  )
);
const inboxOptions = computed(() =>
  engagements.value.map(engagement => ({
    value: String(engagement.inbox.id),
    label: engagement.inbox.name,
  }))
);
const canAddStarter = computed(() => form.value.starters.length < 6);

const apiError = error =>
  error?.response?.data?.error ||
  error?.message ||
  t('CHATRING_ENGAGEMENTS.ERROR');

const setForm = engagement => {
  form.value = {
    enabled: engagement?.enabled || false,
    starters: (engagement?.starters || []).map(starter => ({
      ...starter,
      clientKey: newStarterKey(),
    })),
  };
};

watch(selectedEngagement, engagement => setForm(engagement));

const load = async () => {
  isLoading.value = true;
  try {
    const response = await ChatRingEngagementsAPI.list();
    engagements.value = response.data;
    selectedInboxId.value ||= String(engagements.value[0]?.inbox?.id || '');
    setForm(selectedEngagement.value);
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isLoading.value = false;
  }
};

const addStarter = () => {
  if (!canAddStarter.value) return;
  form.value.starters.push({
    label: '',
    prompt: '',
    clientKey: newStarterKey(),
  });
};

const removeStarter = index => form.value.starters.splice(index, 1);

const moveStarter = (index, offset) => {
  const target = index + offset;
  if (target < 0 || target >= form.value.starters.length) return;
  const [starter] = form.value.starters.splice(index, 1);
  form.value.starters.splice(target, 0, starter);
};

const save = async () => {
  if (!selectedEngagement.value || isSaving.value) return;
  isSaving.value = true;
  try {
    const response = await ChatRingEngagementsAPI.update(
      selectedEngagement.value.inbox.id,
      {
        lock_version: selectedEngagement.value.lock_version,
        enabled: form.value.enabled,
        starters: form.value.starters.map(starter => ({
          label: starter.label.trim(),
          prompt: starter.prompt.trim(),
        })),
      }
    );
    const index = engagements.value.findIndex(
      engagement => engagement.inbox.id === response.data.inbox.id
    );
    engagements.value.splice(index, 1, response.data);
    setForm(response.data);
    useAlert(t('CHATRING_ENGAGEMENTS.SAVED'));
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isSaving.value = false;
  }
};

onMounted(load);
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto bg-n-background">
    <header class="px-8 py-6 border-b border-n-weak">
      <h1 class="text-2xl font-semibold text-n-slate-12">
        {{ t('CHATRING_ENGAGEMENTS.TITLE') }}
      </h1>
      <p class="mt-1 text-sm text-n-slate-11">
        {{ t('CHATRING_ENGAGEMENTS.DESCRIPTION') }}
      </p>
    </header>

    <div v-if="isLoading" class="flex items-center justify-center flex-1">
      <Spinner />
    </div>

    <main v-else class="grid max-w-6xl gap-6 p-8 lg:grid-cols-[18rem_1fr]">
      <aside class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
        <label class="block mb-2 text-sm font-medium text-n-slate-12">
          {{ t('CHATRING_ENGAGEMENTS.INBOX') }}
        </label>
        <Select v-model="selectedInboxId" :options="inboxOptions" />
        <p class="mt-4 text-xs text-n-slate-10">
          {{ t('CHATRING_ENGAGEMENTS.NATIVE_MESSAGE_NOTE') }}
        </p>
      </aside>

      <section v-if="selectedEngagement" class="space-y-5">
        <article class="p-6 border rounded-xl border-n-weak bg-n-solid-1">
          <div class="flex items-start justify-between gap-5">
            <div>
              <h2 class="text-lg font-semibold text-n-slate-12">
                {{ t('CHATRING_ENGAGEMENTS.STARTERS') }}
              </h2>
              <p class="mt-1 text-sm text-n-slate-11">
                {{ t('CHATRING_ENGAGEMENTS.STARTERS_DESCRIPTION') }}
              </p>
            </div>
            <div class="flex items-center gap-2 text-sm text-n-slate-12">
              <span>{{ t('CHATRING_ENGAGEMENTS.ENABLED') }}</span>
              <Switch v-model="form.enabled" />
            </div>
          </div>

          <div class="mt-6 space-y-4">
            <div
              v-for="(starter, index) in form.starters"
              :key="starter.clientKey"
              class="grid gap-3 p-4 border rounded-lg border-n-weak md:grid-cols-[1fr_2fr_auto]"
            >
              <Input
                v-model="starter.label"
                :label="t('CHATRING_ENGAGEMENTS.LABEL')"
              />
              <Input
                v-model="starter.prompt"
                :label="t('CHATRING_ENGAGEMENTS.PROMPT')"
              />
              <div class="flex items-end gap-1">
                <Button
                  variant="outline"
                  color="slate"
                  :disabled="index === 0"
                  :aria-label="t('CHATRING_ENGAGEMENTS.MOVE_UP')"
                  @click="moveStarter(index, -1)"
                >
                  ↑
                </Button>
                <Button
                  variant="outline"
                  color="slate"
                  :disabled="index === form.starters.length - 1"
                  :aria-label="t('CHATRING_ENGAGEMENTS.MOVE_DOWN')"
                  @click="moveStarter(index, 1)"
                >
                  ↓
                </Button>
                <Button
                  variant="outline"
                  color="ruby"
                  :aria-label="t('CHATRING_ENGAGEMENTS.REMOVE')"
                  @click="removeStarter(index)"
                >
                  ×
                </Button>
              </div>
            </div>

            <Button
              variant="outline"
              :disabled="!canAddStarter"
              @click="addStarter"
            >
              {{ t('CHATRING_ENGAGEMENTS.ADD') }}
            </Button>
          </div>
        </article>

        <div class="flex justify-end">
          <Button :is-loading="isSaving" :disabled="isSaving" @click="save">
            {{ t('CHATRING_ENGAGEMENTS.SAVE') }}
          </Button>
        </div>
      </section>
    </main>
  </div>
</template>
