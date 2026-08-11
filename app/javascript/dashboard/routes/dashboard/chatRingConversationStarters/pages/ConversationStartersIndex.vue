<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import ChatRingConversationStartersAPI from 'dashboard/api/chatRingConversationStarters';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const { t } = useI18n();
const configurations = ref([]);
const selectedInboxId = ref('');
const isLoading = ref(true);
const isSaving = ref(false);
const form = ref({ enabled: false, starters: [] });
let nextStarterKey = 0;
const newStarterKey = () => {
  nextStarterKey += 1;
  return nextStarterKey;
};

const selectedConfiguration = computed(() =>
  configurations.value.find(
    configuration =>
      String(configuration.inbox.id) === String(selectedInboxId.value)
  )
);
const inboxOptions = computed(() =>
  configurations.value.map(configuration => ({
    value: String(configuration.inbox.id),
    label: configuration.inbox.name,
  }))
);
const canAddStarter = computed(() => form.value.starters.length < 4);

const apiError = error =>
  error?.response?.data?.error ||
  error?.message ||
  t('CHATRING_CONVERSATION_STARTERS.ERROR');

const setForm = configuration => {
  form.value = {
    enabled: configuration?.enabled || false,
    starters: (configuration?.starters || []).map(starter => ({
      ...starter,
      clientKey: newStarterKey(),
    })),
  };
};

watch(selectedConfiguration, configuration => setForm(configuration));

const load = async () => {
  isLoading.value = true;
  try {
    const response = await ChatRingConversationStartersAPI.list();
    configurations.value = response.data;
    selectedInboxId.value ||= String(configurations.value[0]?.inbox?.id || '');
    setForm(selectedConfiguration.value);
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
  if (!selectedConfiguration.value || isSaving.value) return;
  isSaving.value = true;
  try {
    const response = await ChatRingConversationStartersAPI.update(
      selectedConfiguration.value.inbox.id,
      {
        lock_version: selectedConfiguration.value.lock_version,
        enabled: form.value.enabled,
        starters: form.value.starters.map(starter => ({
          label: starter.label.trim(),
          prompt: starter.prompt.trim(),
        })),
      }
    );
    const index = configurations.value.findIndex(
      configuration => configuration.inbox.id === response.data.inbox.id
    );
    configurations.value.splice(index, 1, response.data);
    setForm(response.data);
    useAlert(t('CHATRING_CONVERSATION_STARTERS.SAVED'));
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
        {{ t('CHATRING_CONVERSATION_STARTERS.TITLE') }}
      </h1>
      <p class="mt-1 text-sm text-n-slate-11">
        {{ t('CHATRING_CONVERSATION_STARTERS.DESCRIPTION') }}
      </p>
    </header>

    <div v-if="isLoading" class="flex items-center justify-center flex-1">
      <Spinner />
    </div>

    <main v-else class="grid max-w-6xl gap-6 p-8 lg:grid-cols-[18rem_1fr]">
      <aside class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
        <label class="block mb-2 text-sm font-medium text-n-slate-12">
          {{ t('CHATRING_CONVERSATION_STARTERS.INBOX') }}
        </label>
        <Select v-model="selectedInboxId" :options="inboxOptions" />
        <p class="mt-4 text-xs text-n-slate-10">
          {{ t('CHATRING_CONVERSATION_STARTERS.NATIVE_MESSAGE_NOTE') }}
        </p>
      </aside>

      <section v-if="selectedConfiguration" class="space-y-5">
        <article class="p-6 border rounded-xl border-n-weak bg-n-solid-1">
          <div class="flex items-start justify-between gap-5">
            <div>
              <h2 class="text-lg font-semibold text-n-slate-12">
                {{ t('CHATRING_CONVERSATION_STARTERS.STARTERS') }}
              </h2>
              <p class="mt-1 text-sm text-n-slate-11">
                {{ t('CHATRING_CONVERSATION_STARTERS.STARTERS_DESCRIPTION') }}
              </p>
            </div>
            <div class="flex items-center gap-2 text-sm text-n-slate-12">
              <span>{{ t('CHATRING_CONVERSATION_STARTERS.ENABLED') }}</span>
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
                :label="t('CHATRING_CONVERSATION_STARTERS.LABEL')"
              />
              <Input
                v-model="starter.prompt"
                :label="t('CHATRING_CONVERSATION_STARTERS.PROMPT')"
              />
              <div class="flex items-end gap-1">
                <Button
                  icon="i-lucide-arrow-up"
                  variant="outline"
                  color="slate"
                  :disabled="index === 0"
                  :aria-label="t('CHATRING_CONVERSATION_STARTERS.MOVE_UP')"
                  @click="moveStarter(index, -1)"
                />
                <Button
                  icon="i-lucide-arrow-down"
                  variant="outline"
                  color="slate"
                  :disabled="index === form.starters.length - 1"
                  :aria-label="t('CHATRING_CONVERSATION_STARTERS.MOVE_DOWN')"
                  @click="moveStarter(index, 1)"
                />
                <Button
                  icon="i-lucide-x"
                  variant="outline"
                  color="ruby"
                  :aria-label="t('CHATRING_CONVERSATION_STARTERS.REMOVE')"
                  @click="removeStarter(index)"
                />
              </div>
            </div>

            <Button
              variant="outline"
              :disabled="!canAddStarter"
              @click="addStarter"
            >
              {{ t('CHATRING_CONVERSATION_STARTERS.ADD') }}
            </Button>
          </div>
        </article>

        <div class="flex justify-end">
          <Button :is-loading="isSaving" :disabled="isSaving" @click="save">
            {{ t('CHATRING_CONVERSATION_STARTERS.SAVE') }}
          </Button>
        </div>
      </section>
    </main>
  </div>
</template>
