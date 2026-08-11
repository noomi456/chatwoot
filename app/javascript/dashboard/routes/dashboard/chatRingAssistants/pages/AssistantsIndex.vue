<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import ChatRingAssistantsAPI from 'dashboard/api/chatRingAssistants';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const { t } = useI18n();
const store = useStore();
const route = useRoute();

const assistants = ref([]);
const selectedAssistant = ref(null);
const turns = ref([]);
const selectedTurn = ref(null);
const activePanel = ref('configuration');
const newAssistantName = ref('');
const selectedInboxId = ref('');
const preflight = ref(null);
const isLoading = ref(true);
const isSaving = ref(false);
const isCreating = ref(false);
const isOperating = ref(false);
const hasStaleDraft = ref(false);
const savedFormFingerprint = ref('');
let accountLoadGeneration = 0;
let assistantSelectionGeneration = 0;
let turnDetailGeneration = 0;

const form = ref({
  name: '',
  identityName: '',
  goals: '',
  instructions: '',
  responseGuidelines: '',
  guardrails: '',
  appointmentTool: false,
  insufficientEvidence: 'handoff',
  providerFailure: 'handoff',
});

const inboxes = useMapGetter('inboxes/getWebsiteInboxes');
const websiteInboxes = computed(() =>
  inboxes.value.slice().sort((a, b) => a.name.localeCompare(b.name))
);
const inboxOptions = computed(() =>
  websiteInboxes.value.map(inbox => ({ value: inbox.id, label: inbox.name }))
);
const outcomeOptions = computed(() => [
  { value: 'handoff', label: t('CHATRING_ASSISTANTS.HANDOFF') },
  { value: 'abstain', label: t('CHATRING_ASSISTANTS.ABSTAIN') },
]);
const isArchived = computed(
  () => selectedAssistant.value?.state === 'archived'
);
const isDraftDirty = computed(
  () => JSON.stringify(form.value) !== savedFormFingerprint.value
);
const releaseReady = computed(
  () => selectedAssistant.value?.public_ai_release_ready === true
);
const assistantBindings = computed(
  () => selectedAssistant.value?.bindings || []
);
const isMutationBusy = computed(
  () => isCreating.value || isSaving.value || isOperating.value
);
const controlsDisabled = computed(
  () => isLoading.value || isMutationBusy.value
);
const targetBinding = computed(() => preflight.value?.current_binding);
const targetAlreadyConnected = computed(
  () => targetBinding.value?.assistant_id === selectedAssistant.value?.id
);
const targetRequiresSwitch = computed(
  () => targetBinding.value && !targetAlreadyConnected.value
);

const apiError = error =>
  error?.response?.data?.error ||
  error?.message ||
  t('CHATRING_ASSISTANTS.ERROR');
const lines = value =>
  value
    .split('\n')
    .map(item => item.trim())
    .filter(Boolean);
const formatDate = value => (value ? new Date(value).toLocaleString() : '—');
const stateLabel = state =>
  ({
    draft: t('CHATRING_ASSISTANTS.STATE.DRAFT'),
    published_unbound: t('CHATRING_ASSISTANTS.STATE.PUBLISHED_UNBOUND'),
    active: t('CHATRING_ASSISTANTS.STATE.ACTIVE'),
    configuration_unhealthy: t(
      'CHATRING_ASSISTANTS.STATE.CONFIGURATION_UNHEALTHY'
    ),
    archived: t('CHATRING_ASSISTANTS.STATE.ARCHIVED'),
  })[state] || state;
const issueLabel = issue =>
  ({
    managed_agent_bot_missing: t(
      'CHATRING_ASSISTANTS.ISSUE.MANAGED_AGENT_BOT_MISSING'
    ),
    managed_agent_bot_unhealthy: t(
      'CHATRING_ASSISTANTS.ISSUE.MANAGED_AGENT_BOT_UNHEALTHY'
    ),
  })[issue] || issue;
const conflictLabel = conflict =>
  ({
    public_ai_release_closed: t(
      'CHATRING_ASSISTANTS.CONFLICT.PUBLIC_AI_RELEASE_CLOSED'
    ),
    unsupported_channel: t('CHATRING_ASSISTANTS.CONFLICT.UNSUPPORTED_CHANNEL'),
    archived_assistant: t('CHATRING_ASSISTANTS.CONFLICT.ARCHIVED_ASSISTANT'),
    workspace_inactive: t('CHATRING_ASSISTANTS.CONFLICT.WORKSPACE_INACTIVE'),
    unpublished_assistant: t(
      'CHATRING_ASSISTANTS.CONFLICT.UNPUBLISHED_ASSISTANT'
    ),
    managed_agent_bot_unhealthy: t(
      'CHATRING_ASSISTANTS.CONFLICT.MANAGED_AGENT_BOT_UNHEALTHY'
    ),
    managed_agent_bot_owned_non_pending_conversations: t(
      'CHATRING_ASSISTANTS.CONFLICT.MANAGED_AGENT_BOT_OWNED_NON_PENDING_CONVERSATIONS'
    ),
    agent_bot: t('CHATRING_ASSISTANTS.CONFLICT.AGENT_BOT'),
    dialogflow: t('CHATRING_ASSISTANTS.CONFLICT.DIALOGFLOW'),
    captain: t('CHATRING_ASSISTANTS.CONFLICT.CAPTAIN'),
    automation: t('CHATRING_ASSISTANTS.CONFLICT.AUTOMATION'),
  })[conflict.kind] || conflict.kind;
const bindingInbox = binding =>
  websiteInboxes.value.find(inbox => inbox.id === Number(binding.inbox_id));
const currentAccountId = () => String(route.params.accountId);
const captureContext = assistantId => ({
  accountGeneration: accountLoadGeneration,
  accountId: currentAccountId(),
  assistantId,
});
const contextIsCurrent = context =>
  context.accountGeneration === accountLoadGeneration &&
  context.accountId === currentAccountId() &&
  (!context.assistantId || context.assistantId === selectedAssistant.value?.id);

const setForm = assistant => {
  const draft = assistant?.draft || {};
  form.value = {
    name: assistant?.name || '',
    identityName: draft.identity?.name || '',
    goals: (draft.goals || []).join('\n'),
    instructions: draft.instructions || '',
    responseGuidelines: (draft.response_guidelines || []).join('\n'),
    guardrails: (draft.guardrails || []).join('\n'),
    appointmentTool: (draft.tool_grants || []).some(
      grant =>
        grant.key === 'request_appointment' && Number(grant.version) === 1
    ),
    insufficientEvidence:
      draft.handoff_policy?.on_insufficient_evidence || 'handoff',
    providerFailure: draft.handoff_policy?.on_provider_failure || 'handoff',
  };
  savedFormFingerprint.value = JSON.stringify(form.value);
  hasStaleDraft.value = false;
};

const replaceAssistant = assistant => {
  const index = assistants.value.findIndex(item => item.id === assistant.id);
  if (index === -1) assistants.value.push(assistant);
  else assistants.value.splice(index, 1, assistant);
  assistants.value.sort((a, b) => a.name.localeCompare(b.name));
  selectedAssistant.value = assistant;
  setForm(assistant);
};

const selectAssistant = async (assistant, { force = false } = {}) => {
  if (isMutationBusy.value && !force) return;
  assistantSelectionGeneration += 1;
  const selectionGeneration = assistantSelectionGeneration;
  const accountGeneration = accountLoadGeneration;
  const accountId = currentAccountId();
  isLoading.value = true;
  preflight.value = null;
  selectedInboxId.value = '';
  try {
    const [assistantResponse, turnsResponse] = await Promise.all([
      ChatRingAssistantsAPI.show(assistant.id),
      ChatRingAssistantsAPI.turns({ assistant_id: assistant.id }),
    ]);
    if (
      selectionGeneration !== assistantSelectionGeneration ||
      accountGeneration !== accountLoadGeneration ||
      accountId !== currentAccountId()
    )
      return;

    turns.value = turnsResponse.data;
    selectedTurn.value = null;
    replaceAssistant(assistantResponse.data);
  } catch (error) {
    if (selectionGeneration === assistantSelectionGeneration)
      useAlert(apiError(error));
  } finally {
    if (selectionGeneration === assistantSelectionGeneration)
      isLoading.value = false;
  }
};

const createAssistant = async () => {
  const name = newAssistantName.value.trim();
  if (!name || controlsDisabled.value) return;
  const context = captureContext();
  isCreating.value = true;
  try {
    const response = await ChatRingAssistantsAPI.createAssistant(name);
    if (!contextIsCurrent(context)) return;
    newAssistantName.value = '';
    replaceAssistant(response.data);
    turns.value = [];
    useAlert(t('CHATRING_ASSISTANTS.CREATED'));
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isCreating.value = false;
  }
};

const saveDraft = async () => {
  const draft = selectedAssistant.value?.draft;
  if (!draft || controlsDisabled.value) return;
  const context = captureContext(selectedAssistant.value.id);
  isSaving.value = true;
  try {
    const response = await ChatRingAssistantsAPI.updateDraft(
      selectedAssistant.value.id,
      {
        name: form.value.name,
        lock_version: draft.lock_version,
        identity: { name: form.value.identityName.trim() },
        goals: lines(form.value.goals),
        instructions: form.value.instructions,
        response_guidelines: lines(form.value.responseGuidelines),
        guardrails: lines(form.value.guardrails),
        tool_grants: form.value.appointmentTool
          ? [{ key: 'request_appointment', version: 1 }]
          : [],
        handoff_policy: {
          on_insufficient_evidence: form.value.insufficientEvidence,
          on_provider_failure: form.value.providerFailure,
        },
      }
    );
    if (!contextIsCurrent(context)) return;
    replaceAssistant(response.data);
    useAlert(t('CHATRING_ASSISTANTS.SAVED'));
  } catch (error) {
    if (!contextIsCurrent(context)) return;
    if (error?.response?.status === 409) {
      hasStaleDraft.value = true;
      useAlert(t('CHATRING_ASSISTANTS.STALE_DRAFT_PRESERVED'));
    } else useAlert(apiError(error));
  } finally {
    isSaving.value = false;
  }
};

const reloadDraft = async () => {
  if (controlsDisabled.value) return;
  const context = captureContext(selectedAssistant.value.id);
  isLoading.value = true;
  try {
    const response = await ChatRingAssistantsAPI.show(
      selectedAssistant.value.id
    );
    if (!contextIsCurrent(context)) return;
    replaceAssistant(response.data);
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isLoading.value = false;
  }
};

const publish = async () => {
  if (controlsDisabled.value || isDraftDirty.value || hasStaleDraft.value)
    return;
  const context = captureContext(selectedAssistant.value.id);
  isOperating.value = true;
  try {
    const response = await ChatRingAssistantsAPI.publish(
      selectedAssistant.value.id,
      selectedAssistant.value.draft.lock_version
    );
    if (!contextIsCurrent(context)) return;
    replaceAssistant(response.data.assistant);
    useAlert(t('CHATRING_ASSISTANTS.PUBLISHED'));
  } catch (error) {
    if (!contextIsCurrent(context)) return;
    if (error?.response?.status === 409) {
      hasStaleDraft.value = true;
      useAlert(t('CHATRING_ASSISTANTS.STALE_DRAFT_PRESERVED'));
    } else useAlert(apiError(error));
  } finally {
    isOperating.value = false;
  }
};

const checkInbox = async () => {
  if (!selectedInboxId.value || controlsDisabled.value) return;
  const context = captureContext(selectedAssistant.value.id);
  isOperating.value = true;
  try {
    const response = await ChatRingAssistantsAPI.bindingPreflight(
      selectedAssistant.value.id,
      selectedInboxId.value
    );
    if (!contextIsCurrent(context)) return;
    preflight.value = response.data;
  } catch (error) {
    if (contextIsCurrent(context)) useAlert(apiError(error));
  } finally {
    isOperating.value = false;
  }
};

const bindInbox = async () => {
  if (
    !preflight.value?.ready ||
    targetAlreadyConnected.value ||
    controlsDisabled.value
  )
    return;
  const context = captureContext(selectedAssistant.value.id);
  isOperating.value = true;
  try {
    await ChatRingAssistantsAPI.bind(
      selectedAssistant.value.id,
      selectedInboxId.value
    );
    const response = await ChatRingAssistantsAPI.show(
      selectedAssistant.value.id
    );
    if (!contextIsCurrent(context)) return;
    replaceAssistant(response.data);
    preflight.value = null;
    useAlert(t('CHATRING_ASSISTANTS.CONNECTION_SAVED'));
  } catch (error) {
    if (!contextIsCurrent(context)) return;
    preflight.value = null;
    useAlert(apiError(error));
  } finally {
    isOperating.value = false;
  }
};

const disableBinding = async binding => {
  if (!binding || controlsDisabled.value) return;
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('CHATRING_ASSISTANTS.DISABLE_CONFIRM'))) return;
  const context = captureContext(selectedAssistant.value.id);
  isOperating.value = true;
  try {
    await ChatRingAssistantsAPI.disableBinding(binding.id);
    const response = await ChatRingAssistantsAPI.show(
      selectedAssistant.value.id
    );
    if (!contextIsCurrent(context)) return;
    replaceAssistant(response.data);
    useAlert(t('CHATRING_ASSISTANTS.CONNECTION_DISABLED'));
  } catch (error) {
    if (contextIsCurrent(context)) useAlert(apiError(error));
  } finally {
    isOperating.value = false;
  }
};

const rotateSecret = async () => {
  if (controlsDisabled.value) return;
  const context = captureContext(selectedAssistant.value.id);
  isOperating.value = true;
  try {
    await ChatRingAssistantsAPI.rotateManagedSecret(selectedAssistant.value.id);
    if (contextIsCurrent(context))
      useAlert(t('CHATRING_ASSISTANTS.SECRET_ROTATED'));
  } catch (error) {
    if (contextIsCurrent(context)) useAlert(apiError(error));
  } finally {
    isOperating.value = false;
  }
};

const archiveAssistant = async () => {
  if (controlsDisabled.value || isDraftDirty.value || hasStaleDraft.value)
    return;
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('CHATRING_ASSISTANTS.ARCHIVE_CONFIRM'))) return;
  const context = captureContext(selectedAssistant.value.id);
  isOperating.value = true;
  try {
    const response = await ChatRingAssistantsAPI.archive(
      selectedAssistant.value.id
    );
    if (!contextIsCurrent(context)) return;
    replaceAssistant(response.data);
    useAlert(t('CHATRING_ASSISTANTS.ARCHIVED'));
  } catch (error) {
    if (contextIsCurrent(context)) useAlert(apiError(error));
  } finally {
    isOperating.value = false;
  }
};

const showTurn = async turn => {
  if (selectedTurn.value?.id === turn.id) {
    selectedTurn.value = null;
    return;
  }
  turnDetailGeneration += 1;
  const detailGeneration = turnDetailGeneration;
  const context = captureContext(selectedAssistant.value.id);
  try {
    const response = await ChatRingAssistantsAPI.turn(turn.id);
    if (detailGeneration !== turnDetailGeneration || !contextIsCurrent(context))
      return;
    selectedTurn.value = response.data;
  } catch (error) {
    if (detailGeneration === turnDetailGeneration && contextIsCurrent(context))
      useAlert(apiError(error));
  }
};

const loadAccount = async () => {
  accountLoadGeneration += 1;
  const generation = accountLoadGeneration;
  const accountId = currentAccountId();
  assistantSelectionGeneration += 1;
  turnDetailGeneration += 1;
  isLoading.value = true;
  assistants.value = [];
  selectedAssistant.value = null;
  turns.value = [];
  selectedTurn.value = null;
  preflight.value = null;
  selectedInboxId.value = '';
  try {
    await store.dispatch('inboxes/get');
    const response = await ChatRingAssistantsAPI.list();
    if (
      generation !== accountLoadGeneration ||
      accountId !== currentAccountId()
    )
      return;

    assistants.value = response.data;
    if (assistants.value.length)
      await selectAssistant(assistants.value[0], { force: true });
  } catch (error) {
    if (generation === accountLoadGeneration) useAlert(apiError(error));
  } finally {
    if (generation === accountLoadGeneration && !assistants.value.length)
      isLoading.value = false;
  }
};

watch(
  () => route.params.accountId,
  (accountId, previousAccountId) => {
    if (previousAccountId && accountId !== previousAccountId) loadAccount();
  }
);

onMounted(loadAccount);
</script>

<template>
  <main class="flex overflow-y-auto flex-col flex-1 bg-n-background">
    <header class="px-8 py-6 border-b border-n-weak">
      <div class="flex items-start justify-between gap-6 max-w-7xl mx-auto">
        <div>
          <h1 class="text-xl font-medium text-n-slate-12">
            {{ t('CHATRING_ASSISTANTS.TITLE') }}
          </h1>
          <p class="mt-1 text-sm text-n-slate-11">
            {{ t('CHATRING_ASSISTANTS.DESCRIPTION') }}
          </p>
        </div>
        <form class="flex items-end gap-2" @submit.prevent="createAssistant">
          <Input
            v-model="newAssistantName"
            :label="t('CHATRING_ASSISTANTS.CREATE_NAME')"
            :placeholder="t('CHATRING_ASSISTANTS.CREATE_PLACEHOLDER')"
          />
          <Button
            type="submit"
            icon="i-lucide-plus"
            :label="t('CHATRING_ASSISTANTS.CREATE')"
            :is-loading="isCreating"
            :disabled="!newAssistantName.trim() || controlsDisabled"
          />
        </form>
      </div>
    </header>

    <div
      v-if="isLoading && !assistants.length"
      class="grid flex-1 place-items-center"
    >
      <Spinner :size="28" />
    </div>

    <section
      v-else-if="!assistants.length"
      class="grid flex-1 place-items-center px-8 py-12"
    >
      <div class="max-w-md text-center">
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('CHATRING_ASSISTANTS.EMPTY_TITLE') }}
        </h2>
        <p class="mt-2 text-sm text-n-slate-11">
          {{ t('CHATRING_ASSISTANTS.EMPTY_DESCRIPTION') }}
        </p>
      </div>
    </section>

    <div v-else class="grid grid-cols-[18rem_minmax(0,1fr)] flex-1 min-h-0">
      <aside class="overflow-y-auto border-r border-n-weak bg-n-solid-1 p-4">
        <button
          v-for="assistant in assistants"
          :key="assistant.id"
          type="button"
          class="flex flex-col gap-1 w-full rounded-lg px-3 py-3 text-left"
          :class="
            selectedAssistant?.id === assistant.id
              ? 'bg-n-alpha-3'
              : 'hover:bg-n-alpha-2'
          "
          :disabled="isMutationBusy"
          @click="selectAssistant(assistant)"
        >
          <span class="text-sm font-medium text-n-slate-12">
            {{ assistant.name }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{ stateLabel(assistant.state) }}
          </span>
        </button>
      </aside>

      <div v-if="selectedAssistant" class="overflow-y-auto px-8 py-6">
        <div class="max-w-5xl mx-auto">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="text-lg font-medium text-n-slate-12">
                {{ selectedAssistant.name }}
              </h2>
              <p class="mt-1 text-sm text-n-slate-11">
                {{
                  selectedAssistant.current_version
                    ? t('CHATRING_ASSISTANTS.PUBLISHED_VERSION', {
                        version: selectedAssistant.current_version.version,
                      })
                    : t('CHATRING_ASSISTANTS.UNPUBLISHED')
                }}
              </p>
              <p
                v-if="selectedAssistant.configuration_issues?.length"
                class="mt-2 text-sm text-n-ruby-10"
              >
                {{
                  t('CHATRING_ASSISTANTS.CONFIGURATION_ISSUES', {
                    issues: selectedAssistant.configuration_issues
                      .map(issueLabel)
                      .join(', '),
                  })
                }}
              </p>
            </div>
            <span
              class="rounded-full bg-n-alpha-3 px-3 py-1 text-xs font-medium text-n-slate-12"
            >
              {{ stateLabel(selectedAssistant.state) }}
            </span>
          </div>

          <div class="flex gap-1 mt-6 border-b border-n-weak">
            <button
              v-for="panel in ['configuration', 'operations']"
              :key="panel"
              type="button"
              class="border-b-2 px-3 py-2 text-sm font-medium"
              :class="
                activePanel === panel
                  ? 'border-n-brand text-n-slate-12'
                  : 'border-transparent text-n-slate-11'
              "
              @click="activePanel = panel"
            >
              {{
                panel === 'configuration'
                  ? t('CHATRING_ASSISTANTS.CONFIGURATION')
                  : t('CHATRING_ASSISTANTS.OPERATIONS')
              }}
            </button>
          </div>

          <div v-if="activePanel === 'configuration'" class="grid gap-6 mt-6">
            <p
              v-if="!releaseReady"
              class="rounded-lg bg-n-amber-3 px-4 py-3 text-sm text-n-amber-11"
            >
              {{ t('CHATRING_ASSISTANTS.RELEASE_CLOSED') }}
            </p>
            <p
              v-if="isArchived"
              class="rounded-lg bg-n-ruby-3 px-4 py-3 text-sm text-n-ruby-11"
            >
              {{ t('CHATRING_ASSISTANTS.READ_ONLY') }}
            </p>
            <div
              v-if="hasStaleDraft"
              class="flex items-center justify-between gap-4 rounded-lg bg-n-ruby-3 px-4 py-3"
            >
              <p class="text-sm text-n-ruby-11">
                {{ t('CHATRING_ASSISTANTS.STALE_DRAFT_PRESERVED') }}
              </p>
              <Button
                variant="outline"
                color="ruby"
                :label="t('CHATRING_ASSISTANTS.RELOAD_DRAFT')"
                :disabled="controlsDisabled"
                @click="reloadDraft"
              />
            </div>
            <section
              class="grid gap-5 rounded-xl outline outline-1 outline-n-weak bg-n-solid-1 p-6"
            >
              <Input
                v-model="form.name"
                :label="t('CHATRING_ASSISTANTS.NAME')"
                :disabled="
                  isArchived ||
                  controlsDisabled ||
                  !!selectedAssistant.current_version
                "
              />
              <Input
                v-model="form.identityName"
                :label="t('CHATRING_ASSISTANTS.IDENTITY_NAME')"
                :placeholder="t('CHATRING_ASSISTANTS.IDENTITY_PLACEHOLDER')"
                :disabled="isArchived || controlsDisabled"
              />
              <TextArea
                v-model="form.goals"
                :label="t('CHATRING_ASSISTANTS.GOALS')"
                :placeholder="t('CHATRING_ASSISTANTS.GOALS_HINT')"
                :disabled="isArchived || controlsDisabled"
                auto-height
                resize
              />
              <TextArea
                v-model="form.instructions"
                :label="t('CHATRING_ASSISTANTS.INSTRUCTIONS')"
                :disabled="isArchived || controlsDisabled"
                auto-height
                resize
                min-height="8rem"
              />
              <TextArea
                v-model="form.responseGuidelines"
                :label="t('CHATRING_ASSISTANTS.RESPONSE_GUIDELINES')"
                :placeholder="t('CHATRING_ASSISTANTS.RESPONSE_GUIDELINES_HINT')"
                :disabled="isArchived || controlsDisabled"
                auto-height
                resize
              />
              <TextArea
                v-model="form.guardrails"
                :label="t('CHATRING_ASSISTANTS.GUARDRAILS')"
                :placeholder="t('CHATRING_ASSISTANTS.GUARDRAILS_HINT')"
                :disabled="isArchived || controlsDisabled"
                auto-height
                resize
              />
              <label
                class="flex items-start gap-3 rounded-lg outline outline-1 outline-n-weak bg-n-alpha-1 px-4 py-3"
              >
                <input
                  v-model="form.appointmentTool"
                  type="checkbox"
                  class="mt-1"
                  :disabled="isArchived || controlsDisabled"
                  data-testid="appointment-tool-grant"
                />
                <span>
                  <span class="block text-sm font-medium text-n-slate-12">
                    {{ t('CHATRING_ASSISTANTS.APPOINTMENT_TOOL') }}
                  </span>
                  <span class="mt-1 block text-xs text-n-slate-11">
                    {{ t('CHATRING_ASSISTANTS.APPOINTMENT_TOOL_DESCRIPTION') }}
                  </span>
                </span>
              </label>
              <div class="grid grid-cols-2 gap-5">
                <label class="grid gap-2 text-sm font-medium text-n-slate-12">
                  {{ t('CHATRING_ASSISTANTS.INSUFFICIENT_EVIDENCE') }}
                  <Select
                    v-model="form.insufficientEvidence"
                    :options="outcomeOptions"
                    :disabled="isArchived || controlsDisabled"
                  />
                </label>
                <label class="grid gap-2 text-sm font-medium text-n-slate-12">
                  {{ t('CHATRING_ASSISTANTS.PROVIDER_FAILURE') }}
                  <Select
                    v-model="form.providerFailure"
                    :options="outcomeOptions"
                    :disabled="isArchived || controlsDisabled"
                  />
                </label>
              </div>
              <div class="rounded-lg bg-n-alpha-2 px-4 py-3">
                <p class="text-sm font-medium text-n-slate-12">
                  {{
                    t('CHATRING_ASSISTANTS.MODEL_VALUE', {
                      model: selectedAssistant.draft?.llm_model,
                    })
                  }}
                </p>
                <p class="mt-1 text-xs text-n-slate-11">
                  {{ t('CHATRING_ASSISTANTS.MODEL_FIXED') }}
                </p>
              </div>
              <div class="flex justify-end gap-3">
                <Button
                  variant="outline"
                  color="slate"
                  :label="t('CHATRING_ASSISTANTS.SAVE_DRAFT')"
                  :is-loading="isSaving"
                  :disabled="isArchived || hasStaleDraft || controlsDisabled"
                  @click="saveDraft"
                />
                <Button
                  :label="t('CHATRING_ASSISTANTS.PUBLISH')"
                  :is-loading="isOperating"
                  :disabled="
                    isArchived ||
                    hasStaleDraft ||
                    isDraftDirty ||
                    controlsDisabled
                  "
                  :title="
                    isDraftDirty
                      ? t('CHATRING_ASSISTANTS.SAVE_BEFORE_PUBLISH')
                      : undefined
                  "
                  @click="publish"
                />
              </div>
            </section>

            <section
              class="grid gap-4 rounded-xl outline outline-1 outline-n-weak bg-n-solid-1 p-6"
            >
              <div>
                <h3 class="text-base font-medium text-n-slate-12">
                  {{ t('CHATRING_ASSISTANTS.INBOX_BINDING') }}
                </h3>
                <p class="mt-1 text-sm text-n-slate-11">
                  {{ t('CHATRING_ASSISTANTS.INBOX_DESCRIPTION') }}
                </p>
              </div>
              <div class="grid gap-2">
                <p class="text-sm font-medium text-n-slate-12">
                  {{ t('CHATRING_ASSISTANTS.CONNECTED_INBOXES') }}
                </p>
                <p
                  v-if="!assistantBindings.length"
                  class="text-sm text-n-slate-11"
                >
                  {{ t('CHATRING_ASSISTANTS.NO_CONNECTED_INBOXES') }}
                </p>
                <div
                  v-for="binding in assistantBindings"
                  :key="binding.id"
                  class="flex items-center justify-between gap-3 rounded-lg bg-n-alpha-2 px-4 py-3"
                >
                  <div>
                    <p class="text-sm font-medium text-n-slate-12">
                      {{
                        bindingInbox(binding)?.name ||
                        t('CHATRING_ASSISTANTS.INBOX_ID', {
                          id: binding.inbox_id,
                        })
                      }}
                    </p>
                    <p class="mt-1 text-xs text-n-slate-11">
                      {{
                        t('CHATRING_ASSISTANTS.BINDING_STATUS', {
                          status: binding.status,
                        })
                      }}
                    </p>
                  </div>
                  <Button
                    v-if="!isArchived"
                    variant="outline"
                    color="ruby"
                    :label="t('CHATRING_ASSISTANTS.DISABLE')"
                    :is-loading="isOperating"
                    :disabled="controlsDisabled"
                    @click="disableBinding(binding)"
                  />
                </div>
              </div>
              <div v-if="!isArchived" class="flex items-end gap-3">
                <label
                  class="grid flex-1 gap-2 text-sm font-medium text-n-slate-12"
                >
                  {{ t('CHATRING_ASSISTANTS.INBOX_BINDING') }}
                  <Select
                    v-model="selectedInboxId"
                    :options="inboxOptions"
                    :placeholder="t('CHATRING_ASSISTANTS.SELECT_INBOX')"
                    :disabled="!releaseReady || controlsDisabled"
                    @update:model-value="preflight = null"
                  />
                </label>
                <Button
                  variant="outline"
                  color="slate"
                  :label="t('CHATRING_ASSISTANTS.CHECK_INBOX')"
                  :is-loading="isOperating"
                  :disabled="
                    !selectedInboxId || !releaseReady || controlsDisabled
                  "
                  @click="checkInbox"
                />
              </div>
              <div
                v-if="preflight"
                class="grid gap-3 rounded-lg bg-n-alpha-2 px-4 py-4 text-sm"
              >
                <p
                  class="font-medium"
                  :class="preflight.ready ? 'text-n-teal-11' : 'text-n-ruby-11'"
                >
                  {{
                    preflight.ready
                      ? t('CHATRING_ASSISTANTS.PREFLIGHT_READY')
                      : t('CHATRING_ASSISTANTS.PREFLIGHT_BLOCKED')
                  }}
                </p>
                <div class="grid gap-1 text-n-slate-11">
                  <span>{{
                    t('CHATRING_ASSISTANTS.PENDING_CONVERSATIONS', {
                      count: preflight.impact.pending_conversations,
                    })
                  }}</span>
                  <span>{{
                    t('CHATRING_ASSISTANTS.NON_PENDING_CONVERSATIONS', {
                      count: preflight.impact.non_pending_conversations,
                    })
                  }}</span>
                  <span>{{
                    t('CHATRING_ASSISTANTS.NONTERMINAL_TURNS', {
                      count: preflight.impact.nonterminal_turns,
                    })
                  }}</span>
                </div>
                <div v-if="preflight.conflicts.length">
                  <p class="font-medium text-n-slate-12">
                    {{ t('CHATRING_ASSISTANTS.CONFLICTS') }}
                  </p>
                  <ul class="mt-1 list-disc pl-5 text-n-slate-11">
                    <li
                      v-for="conflict in preflight.conflicts"
                      :key="`${conflict.kind}-${conflict.record_id}`"
                    >
                      {{ conflictLabel(conflict) }}
                    </li>
                  </ul>
                </div>
                <Button
                  v-if="preflight.ready && !targetAlreadyConnected"
                  class="justify-self-end"
                  :label="
                    targetRequiresSwitch
                      ? t('CHATRING_ASSISTANTS.SWITCH')
                      : t('CHATRING_ASSISTANTS.CONNECT')
                  "
                  :is-loading="isOperating"
                  :disabled="controlsDisabled"
                  @click="bindInbox"
                />
                <p
                  v-else-if="preflight.ready && targetAlreadyConnected"
                  class="text-sm text-n-teal-11"
                >
                  {{ t('CHATRING_ASSISTANTS.ALREADY_CONNECTED') }}
                </p>
              </div>
            </section>

            <section
              class="grid gap-4 rounded-xl outline outline-1 outline-n-weak bg-n-solid-1 p-6"
            >
              <div>
                <h3 class="text-base font-medium text-n-slate-12">
                  {{ t('CHATRING_ASSISTANTS.SECRET') }}
                </h3>
                <p class="mt-1 text-sm text-n-slate-11">
                  {{ t('CHATRING_ASSISTANTS.SECRET_DESCRIPTION') }}
                </p>
              </div>
              <div class="flex justify-between gap-3">
                <Button
                  variant="outline"
                  color="slate"
                  :label="t('CHATRING_ASSISTANTS.ROTATE_SECRET')"
                  :disabled="
                    isArchived ||
                    !selectedAssistant.current_version ||
                    controlsDisabled
                  "
                  :is-loading="isOperating"
                  @click="rotateSecret"
                />
                <Button
                  variant="outline"
                  color="ruby"
                  :label="t('CHATRING_ASSISTANTS.ARCHIVE')"
                  :disabled="
                    isArchived ||
                    isDraftDirty ||
                    hasStaleDraft ||
                    controlsDisabled
                  "
                  :is-loading="isOperating"
                  @click="archiveAssistant"
                />
              </div>
            </section>
          </div>

          <section
            v-else
            class="mt-6 rounded-xl outline outline-1 outline-n-weak bg-n-solid-1"
          >
            <div class="p-6 border-b border-n-weak">
              <h3 class="text-base font-medium text-n-slate-12">
                {{ t('CHATRING_ASSISTANTS.FAILURES') }}
              </h3>
              <p class="mt-1 text-sm text-n-slate-11">
                {{ t('CHATRING_ASSISTANTS.FAILURES_DESCRIPTION') }}
              </p>
            </div>
            <p v-if="!turns.length" class="p-6 text-sm text-n-slate-11">
              {{ t('CHATRING_ASSISTANTS.NO_TURNS') }}
            </p>
            <template v-else>
              <div
                v-for="turn in turns"
                :key="turn.id"
                class="border-b border-n-weak last:border-b-0"
              >
                <button
                  type="button"
                  class="grid grid-cols-[1fr_repeat(3,auto)] items-center gap-6 w-full px-6 py-4 text-left hover:bg-n-alpha-2"
                  @click="showTurn(turn)"
                >
                  <span>
                    <span class="block text-sm font-medium text-n-slate-12">{{
                      t('CHATRING_ASSISTANTS.TURN', { id: turn.id })
                    }}</span>
                    <span class="block mt-1 text-xs text-n-slate-11">{{
                      formatDate(turn.created_at)
                    }}</span>
                  </span>
                  <span class="text-xs text-n-slate-11">{{ turn.status }}</span>
                  <span class="text-xs text-n-slate-11">{{
                    turn.failure_code || '—'
                  }}</span>
                  <span class="text-xs font-medium text-n-blue-11">
                    {{
                      selectedTurn?.id === turn.id
                        ? t('CHATRING_ASSISTANTS.CLOSE_DETAILS')
                        : t('CHATRING_ASSISTANTS.DETAILS')
                    }}
                  </span>
                </button>
                <div
                  v-if="selectedTurn?.id === turn.id"
                  class="grid gap-4 bg-n-alpha-2 px-6 py-5 text-sm"
                >
                  <dl class="grid grid-cols-3 gap-4">
                    <div>
                      <dt class="text-n-slate-11">
                        {{ t('CHATRING_ASSISTANTS.CONVERSATION') }}
                      </dt>
                      <dd class="mt-1 text-n-slate-12">
                        <RouterLink
                          class="text-n-blue-11 hover:underline"
                          :to="{
                            name: 'conversation_through_inbox',
                            params: {
                              accountId: route.params.accountId,
                              inbox_id: selectedTurn.inbox_id,
                              conversation_id: selectedTurn.conversation_id,
                            },
                          }"
                        >
                          {{ t('CHATRING_ASSISTANTS.OPEN_CONVERSATION') }}
                        </RouterLink>
                      </dd>
                    </div>
                    <div>
                      <dt class="text-n-slate-11">
                        {{ t('CHATRING_ASSISTANTS.DECISION') }}
                      </dt>
                      <dd class="mt-1 text-n-slate-12">
                        {{ selectedTurn.decision_type || '—' }}
                      </dd>
                    </div>
                    <div>
                      <dt class="text-n-slate-11">
                        {{ t('CHATRING_ASSISTANTS.EVIDENCE') }}
                      </dt>
                      <dd class="mt-1 text-n-slate-12">
                        {{ selectedTurn.evidence_count }}
                      </dd>
                    </div>
                  </dl>
                  <div v-if="selectedTurn.outbound_commit">
                    <h4 class="font-medium text-n-slate-12">
                      {{ t('CHATRING_ASSISTANTS.OUTBOUND_OUTCOME') }}
                    </h4>
                    <p class="mt-2 text-n-slate-11">
                      {{
                        t('CHATRING_ASSISTANTS.OUTBOUND_SUMMARY', {
                          outcome: selectedTurn.outbound_commit.outcome_type,
                          status: selectedTurn.outbound_commit.status,
                          failure:
                            selectedTurn.outbound_commit.failure_code || '—',
                        })
                      }}
                    </p>
                  </div>
                  <div v-if="selectedTurn.attempts?.length">
                    <h4 class="font-medium text-n-slate-12">
                      {{ t('CHATRING_ASSISTANTS.ATTEMPTS') }}
                    </h4>
                    <ul class="mt-2 grid gap-2 text-n-slate-11">
                      <li
                        v-for="attempt in selectedTurn.attempts"
                        :key="attempt.id"
                      >
                        {{
                          t('CHATRING_ASSISTANTS.ATTEMPT_SUMMARY', {
                            number: attempt.attempt_number,
                            provider: attempt.provider,
                            model: attempt.model,
                            status: attempt.status,
                            failure: attempt.failure_code || '—',
                          })
                        }}
                      </li>
                    </ul>
                  </div>
                </div>
              </div>
            </template>
          </section>
        </div>
      </div>
    </div>
  </main>
</template>
