<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import ChatRingPlaybooksAPI from 'dashboard/api/chatRingPlaybooks';
import ChatRingToolsAPI from 'dashboard/api/chatRingTools';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const { t } = useI18n();

const playbooks = ref([]);
const policies = ref([]);
const selectedInboxId = ref('');
const selectedPlaybookId = ref('');
const isLoading = ref(true);
const isSaving = ref(false);
const validation = ref(null);
const form = ref({
  name: '',
  purpose: '',
  triggersText: '',
  appointmentTool: false,
  collectedFields: [],
  steps: [],
});

const stepKindOptions = [
  { value: 'ask_text', label: 'Ask text question' },
  { value: 'ask_choice', label: 'Ask choice question' },
  { value: 'inform', label: 'Share information' },
  { value: 'tool', label: 'Run approved Tool' },
  { value: 'terminal', label: 'Complete or hand off' },
  { value: 'transition', label: 'Transition to Playbook version' },
];
const fieldTypeOptions = [
  'string',
  'email',
  'phone',
  'number',
  'boolean',
  'choice',
].map(value => ({
  value,
  label: value,
}));
const outcomeOptions = ['complete', 'stop', 'handoff'].map(value => ({
  value,
  label: value,
}));

const inboxOptions = computed(() =>
  policies.value.map(policy => ({
    value: String(policy.inbox.id),
    label: `${policy.inbox.name} · ${policy.inbox.channel_type}`,
  }))
);
const selectedPolicy = computed(() =>
  policies.value.find(
    policy => String(policy.inbox.id) === String(selectedInboxId.value)
  )
);
const inboxPlaybooks = computed(() =>
  playbooks.value.filter(
    playbook => String(playbook.inbox.id) === String(selectedInboxId.value)
  )
);
const selectedPlaybook = computed(() =>
  playbooks.value.find(
    playbook => String(playbook.id) === String(selectedPlaybookId.value)
  )
);
const appointmentCapability = computed(() =>
  selectedPolicy.value?.capabilities?.find(
    capability =>
      capability.key === 'request_appointment' && capability.version === 1
  )
);
const appointmentAvailable = computed(
  () => appointmentCapability.value?.available === true
);
const isReadOnly = computed(
  () => selectedPlaybook.value?.status === 'archived'
);

const apiError = error =>
  error?.response?.data?.error ||
  error?.message ||
  t('CHATRING_PLAYBOOKS.ERROR');

const deepCopy = value => JSON.parse(JSON.stringify(value));
const lines = value =>
  value
    .split('\n')
    .map(item => item.trim())
    .filter(Boolean);

const editableStep = step => ({
  ...deepCopy(step),
  choicesText: (step.choices || [])
    .map(choice => `${choice.label}|${choice.value}|${choice.next_step_id}`)
    .join('\n'),
  carryFieldsText: (step.carry_fields || []).join('\n'),
});

const setForm = playbook => {
  validation.value = null;
  if (!playbook) {
    form.value = {
      name: '',
      purpose: '',
      triggersText: '',
      appointmentTool: false,
      collectedFields: [],
      steps: [],
    };
    return;
  }

  const definition = playbook.draft_definition || {};
  form.value = {
    name: playbook.name,
    purpose: playbook.purpose,
    triggersText: (definition.trigger_phrases || []).join('\n'),
    appointmentTool: (definition.tool_allowlist || []).some(
      tool => tool.key === 'request_appointment' && Number(tool.version) === 1
    ),
    collectedFields: deepCopy(definition.collected_fields || []),
    steps: (definition.steps || []).map(editableStep),
  };
};

watch(selectedPlaybook, playbook => setForm(playbook));
watch(selectedInboxId, () => {
  const currentBelongsToInbox = inboxPlaybooks.value.some(
    playbook => String(playbook.id) === String(selectedPlaybookId.value)
  );
  if (!currentBelongsToInbox) {
    selectedPlaybookId.value = String(inboxPlaybooks.value[0]?.id || '');
  }
});

const serializedStep = step => {
  const common = {
    id: step.id?.trim(),
    kind: step.kind,
    tool_allowlist:
      step.kind === 'tool' && form.value.appointmentTool
        ? [{ key: 'request_appointment', version: 1 }]
        : [],
  };
  if (step.kind === 'ask_text') {
    return {
      ...common,
      prompt: step.prompt?.trim(),
      field_key: step.field_key?.trim(),
      next_step_id: step.next_step_id?.trim(),
    };
  }
  if (step.kind === 'ask_choice') {
    return {
      ...common,
      prompt: step.prompt?.trim(),
      field_key: step.field_key?.trim(),
      choices: lines(step.choicesText || '').map(item => {
        const [label, value, nextStepId] = item
          .split('|')
          .map(part => part.trim());
        return { label, value, next_step_id: nextStepId };
      }),
    };
  }
  if (step.kind === 'inform') {
    return {
      ...common,
      message: step.message?.trim(),
      next_step_id: step.next_step_id?.trim(),
    };
  }
  if (step.kind === 'tool') {
    return {
      ...common,
      tool: { key: 'request_appointment', version: 1 },
      ...(step.next_step_id?.trim()
        ? { next_step_id: step.next_step_id.trim() }
        : {}),
    };
  }
  if (step.kind === 'transition') {
    return {
      ...common,
      target_playbook_version_id: Number(step.target_playbook_version_id),
      carry_fields: lines(step.carryFieldsText || ''),
    };
  }
  return { ...common, outcome: step.outcome || 'complete' };
};

const definition = () => ({
  trigger_phrases: lines(form.value.triggersText),
  entry_step_id: form.value.steps[0]?.id?.trim() || '',
  steps: form.value.steps.map(serializedStep),
  collected_fields: form.value.collectedFields.map(field => ({
    key: field.key?.trim(),
    type: field.type,
    required: field.required === true,
    native_contact_attribute_key:
      field.native_contact_attribute_key?.trim() || null,
  })),
  tool_allowlist: form.value.appointmentTool
    ? [{ key: 'request_appointment', version: 1 }]
    : [],
  safety_rules: {
    on_human_request: 'native_availability',
    on_side_question: 'answer_then_resume',
  },
});

const replacePlaybook = item => {
  const index = playbooks.value.findIndex(playbook => playbook.id === item.id);
  if (index === -1) playbooks.value.push(item);
  else playbooks.value.splice(index, 1, item);
  selectedPlaybookId.value = String(item.id);
  setForm(item);
};

const load = async () => {
  isLoading.value = true;
  try {
    const [playbookResponse, policyResponse] = await Promise.all([
      ChatRingPlaybooksAPI.list(),
      ChatRingToolsAPI.list(),
    ]);
    playbooks.value = playbookResponse.data;
    policies.value = policyResponse.data;
    selectedInboxId.value = String(policies.value[0]?.inbox?.id || '');
    selectedPlaybookId.value = String(inboxPlaybooks.value[0]?.id || '');
    setForm(selectedPlaybook.value);
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isLoading.value = false;
  }
};

const createPlaybook = async () => {
  if (!selectedInboxId.value || isSaving.value) return;
  isSaving.value = true;
  try {
    const response = await ChatRingPlaybooksAPI.create({
      inbox_id: Number(selectedInboxId.value),
      name: t('CHATRING_PLAYBOOKS.CREATE_NAME', {
        number: inboxPlaybooks.value.length + 1,
      }),
      purpose: '',
    });
    replacePlaybook(response.data);
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isSaving.value = false;
  }
};

const saveDraft = async ({ notify = true } = {}) => {
  if (!selectedPlaybook.value || isSaving.value) return null;
  isSaving.value = true;
  try {
    const response = await ChatRingPlaybooksAPI.updateDraft(
      selectedPlaybook.value.id,
      {
        lock_version: selectedPlaybook.value.lock_version,
        name: form.value.name.trim(),
        purpose: form.value.purpose.trim(),
        definition: definition(),
      }
    );
    replacePlaybook(response.data);
    if (notify) useAlert(t('CHATRING_PLAYBOOKS.SAVED'));
    return response.data;
  } catch (error) {
    useAlert(apiError(error));
    return null;
  } finally {
    isSaving.value = false;
  }
};

const validateDefinition = async () => {
  if (!selectedPlaybook.value) return;
  try {
    const response = await ChatRingPlaybooksAPI.validate(
      selectedPlaybook.value.id,
      definition()
    );
    validation.value = response.data;
  } catch (error) {
    useAlert(apiError(error));
  }
};

const publish = async () => {
  const saved = await saveDraft({ notify: false });
  if (!saved) return;
  isSaving.value = true;
  try {
    const response = await ChatRingPlaybooksAPI.publish(
      saved.id,
      saved.lock_version
    );
    replacePlaybook(response.data.playbook);
    validation.value = response.data.version.validation_result;
    useAlert(t('CHATRING_PLAYBOOKS.PUBLISHED'));
  } catch (error) {
    validation.value = error?.response?.data || null;
    useAlert(apiError(error));
  } finally {
    isSaving.value = false;
  }
};

const addField = () => {
  form.value.collectedFields.push({
    key: `field_${form.value.collectedFields.length + 1}`,
    type: 'string',
    required: true,
    native_contact_attribute_key: null,
  });
};

const addStep = () => {
  form.value.steps.push({
    id: `step_${form.value.steps.length + 1}`,
    kind: 'inform',
    message: '',
    next_step_id: '',
  });
};

onMounted(load);
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto bg-n-background">
    <header
      class="flex items-start justify-between gap-4 px-8 py-6 border-b border-n-weak"
    >
      <div>
        <h1 class="text-2xl font-semibold text-n-slate-12">
          {{ t('CHATRING_PLAYBOOKS.TITLE') }}
        </h1>
        <p class="mt-1 text-sm text-n-slate-11">
          {{ t('CHATRING_PLAYBOOKS.DESCRIPTION') }}
        </p>
      </div>
      <Button
        data-testid="new-playbook"
        :disabled="!selectedInboxId || isSaving"
        @click="createPlaybook"
      >
        {{ t('CHATRING_PLAYBOOKS.NEW') }}
      </Button>
    </header>

    <div v-if="isLoading" class="flex items-center justify-center flex-1">
      <Spinner />
    </div>

    <main
      v-else
      class="grid gap-5 p-6 xl:grid-cols-[18rem_minmax(0,1fr)_20rem]"
    >
      <aside class="space-y-4">
        <section class="p-4 border rounded-xl border-n-weak bg-n-solid-1">
          <p class="mb-2 text-sm font-medium text-n-slate-12">
            {{ t('CHATRING_PLAYBOOKS.INBOX') }}
          </p>
          <Select v-model="selectedInboxId" :options="inboxOptions" />
        </section>
        <section
          class="overflow-hidden border rounded-xl border-n-weak bg-n-solid-1"
        >
          <button
            v-for="playbook in inboxPlaybooks"
            :key="playbook.id"
            class="w-full px-4 py-3 text-left border-b border-n-weak last:border-b-0"
            :class="
              playbook.id === selectedPlaybook?.id
                ? 'bg-n-brand/10'
                : 'hover:bg-n-alpha-black2'
            "
            @click="selectedPlaybookId = String(playbook.id)"
          >
            <span class="block text-sm font-medium text-n-slate-12">
              {{ playbook.name }}
            </span>
            <span class="text-xs uppercase text-n-slate-10">
              {{ playbook.status }}
            </span>
          </button>
          <p v-if="!inboxPlaybooks.length" class="p-5 text-sm text-n-slate-10">
            {{ t('CHATRING_PLAYBOOKS.EMPTY') }}
          </p>
        </section>
      </aside>

      <section v-if="selectedPlaybook" class="space-y-5">
        <article
          class="grid gap-4 p-5 border rounded-xl border-n-weak bg-n-solid-1 md:grid-cols-2"
        >
          <Input
            v-model="form.name"
            :disabled="isReadOnly"
            :label="t('CHATRING_PLAYBOOKS.NAME')"
          />
          <div class="text-xs text-right text-n-slate-10">
            {{
              selectedPlaybook.current_version
                ? t('CHATRING_PLAYBOOKS.VERSION', {
                    version: selectedPlaybook.current_version.version,
                  })
                : t('CHATRING_PLAYBOOKS.DRAFT')
            }}
          </div>
          <div class="md:col-span-2">
            <TextArea
              v-model="form.purpose"
              :disabled="isReadOnly"
              :label="t('CHATRING_PLAYBOOKS.PURPOSE')"
              :max-length="500"
              show-character-count
            />
          </div>
          <div class="md:col-span-2">
            <TextArea
              v-model="form.triggersText"
              :disabled="isReadOnly"
              :label="t('CHATRING_PLAYBOOKS.TRIGGERS')"
              :message="t('CHATRING_PLAYBOOKS.TRIGGERS_HINT')"
              :max-length="3200"
            />
          </div>
        </article>

        <article class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
          <h2 class="text-sm font-semibold text-n-slate-12">
            {{ t('CHATRING_PLAYBOOKS.TOOLS') }}
          </h2>
          <div
            v-if="appointmentAvailable"
            class="flex items-center gap-2 mt-3 text-sm text-n-slate-12"
          >
            <Switch v-model="form.appointmentTool" :disabled="isReadOnly" />
            <span>{{ t('CHATRING_PLAYBOOKS.APPOINTMENT_TOOL') }}</span>
          </div>
          <p v-else class="mt-2 text-sm text-n-slate-10">
            {{ t('CHATRING_PLAYBOOKS.NO_TOOLS') }}
          </p>
        </article>

        <article class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-sm font-semibold text-n-slate-12">
              {{ t('CHATRING_PLAYBOOKS.FIELDS') }}
            </h2>
            <Button variant="outline" :disabled="isReadOnly" @click="addField">
              {{ t('CHATRING_PLAYBOOKS.ADD_FIELD') }}
            </Button>
          </div>
          <div
            v-for="(field, index) in form.collectedFields"
            :key="index"
            class="grid gap-3 pt-4 mt-4 border-t border-n-weak md:grid-cols-5"
          >
            <Input
              v-model="field.key"
              :disabled="isReadOnly"
              :placeholder="t('CHATRING_PLAYBOOKS.FIELD_PLACEHOLDER')"
            />
            <Select
              v-model="field.type"
              :disabled="isReadOnly"
              :options="fieldTypeOptions"
            />
            <Input
              v-model="field.native_contact_attribute_key"
              :disabled="isReadOnly"
              :placeholder="
                t('CHATRING_PLAYBOOKS.NATIVE_ATTRIBUTE_PLACEHOLDER')
              "
            />
            <div class="flex items-center gap-2 text-sm text-n-slate-12">
              <Switch v-model="field.required" :disabled="isReadOnly" />
              <span>{{ t('CHATRING_PLAYBOOKS.REQUIRED') }}</span>
            </div>
            <Button
              variant="ghost"
              :disabled="isReadOnly"
              @click="form.collectedFields.splice(index, 1)"
            >
              {{ t('CHATRING_PLAYBOOKS.REMOVE_STEP') }}
            </Button>
          </div>
        </article>

        <article class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-sm font-semibold text-n-slate-12">
              {{ t('CHATRING_PLAYBOOKS.STEPS') }}
            </h2>
            <Button variant="outline" :disabled="isReadOnly" @click="addStep">
              {{ t('CHATRING_PLAYBOOKS.ADD_STEP') }}
            </Button>
          </div>

          <div
            v-for="(step, index) in form.steps"
            :key="index"
            class="p-4 mt-4 space-y-3 border rounded-lg border-n-weak"
          >
            <div class="grid gap-3 md:grid-cols-[1fr_1fr_auto]">
              <Input
                v-model="step.id"
                :disabled="isReadOnly"
                :placeholder="t('CHATRING_PLAYBOOKS.STEP_ID')"
              />
              <Select
                v-model="step.kind"
                :disabled="isReadOnly"
                :options="stepKindOptions"
              />
              <Button
                variant="ghost"
                :disabled="isReadOnly"
                @click="form.steps.splice(index, 1)"
              >
                {{ t('CHATRING_PLAYBOOKS.REMOVE_STEP') }}
              </Button>
            </div>

            <template
              v-if="step.kind === 'ask_text' || step.kind === 'ask_choice'"
            >
              <TextArea
                v-model="step.prompt"
                :disabled="isReadOnly"
                :placeholder="t('CHATRING_PLAYBOOKS.STEP_TEXT')"
                :max-length="1000"
              />
              <Input
                v-model="step.field_key"
                :disabled="isReadOnly"
                :placeholder="t('CHATRING_PLAYBOOKS.FIELD_KEY')"
              />
            </template>
            <TextArea
              v-if="step.kind === 'ask_choice'"
              v-model="step.choicesText"
              :disabled="isReadOnly"
              :placeholder="t('CHATRING_PLAYBOOKS.CHOICE_PLACEHOLDER')"
              :max-length="3000"
            />
            <TextArea
              v-if="step.kind === 'inform'"
              v-model="step.message"
              :disabled="isReadOnly"
              :placeholder="t('CHATRING_PLAYBOOKS.STEP_TEXT')"
              :max-length="1000"
            />
            <Input
              v-if="['ask_text', 'inform', 'tool'].includes(step.kind)"
              v-model="step.next_step_id"
              :disabled="isReadOnly"
              :placeholder="t('CHATRING_PLAYBOOKS.NEXT_STEP')"
            />
            <p v-if="step.kind === 'tool'" class="text-sm text-n-slate-11">
              {{ t('CHATRING_PLAYBOOKS.APPOINTMENT_TOOL') }}
            </p>
            <Select
              v-if="step.kind === 'terminal'"
              v-model="step.outcome"
              :disabled="isReadOnly"
              :options="outcomeOptions"
            />
            <template v-if="step.kind === 'transition'">
              <Input
                v-model="step.target_playbook_version_id"
                type="number"
                :disabled="isReadOnly"
                :placeholder="
                  t('CHATRING_PLAYBOOKS.TARGET_VERSION_PLACEHOLDER')
                "
              />
              <TextArea
                v-model="step.carryFieldsText"
                :disabled="isReadOnly"
                :placeholder="t('CHATRING_PLAYBOOKS.CARRY_FIELDS_PLACEHOLDER')"
                :max-length="1200"
              />
            </template>
          </div>
        </article>

        <article
          v-if="validation"
          class="p-4 border rounded-xl"
          :class="
            validation.valid
              ? 'border-n-teal-7 bg-n-teal-2'
              : 'border-n-ruby-7 bg-n-ruby-2'
          "
        >
          <p class="text-sm font-semibold text-n-slate-12">
            {{
              validation.valid
                ? t('CHATRING_PLAYBOOKS.VALID')
                : t('CHATRING_PLAYBOOKS.INVALID')
            }}
          </p>
          <ul
            v-if="validation.errors?.length"
            class="mt-2 space-y-1 text-sm text-n-slate-11"
          >
            <li
              v-for="error in validation.errors"
              :key="`${error.code}-${error.path}`"
            >
              {{ error.path }}: {{ error.message }}
            </li>
          </ul>
        </article>

        <div class="flex justify-end gap-2">
          <Button
            data-testid="validate-playbook"
            variant="outline"
            @click="validateDefinition"
          >
            {{ t('CHATRING_PLAYBOOKS.VALIDATE') }}
          </Button>
          <Button
            data-testid="save-playbook"
            variant="outline"
            :disabled="isReadOnly || isSaving"
            @click="saveDraft()"
          >
            {{ t('CHATRING_PLAYBOOKS.SAVE') }}
          </Button>
          <Button
            data-testid="publish-playbook"
            :disabled="isReadOnly || isSaving"
            @click="publish"
          >
            {{ t('CHATRING_PLAYBOOKS.PUBLISH') }}
          </Button>
        </div>
      </section>

      <aside v-if="selectedPlaybook" class="space-y-4">
        <section class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
          <h2 class="text-sm font-semibold text-n-slate-12">
            {{ t('CHATRING_PLAYBOOKS.PREVIEW') }}
          </h2>
          <div
            v-for="(step, index) in form.steps"
            :key="index"
            class="p-3 mt-3 border rounded-lg border-n-weak"
          >
            <p class="text-xs font-medium uppercase text-n-slate-10">
              {{ step.id || `step_${index + 1}` }} · {{ step.kind }}
            </p>
            <p class="mt-1 text-sm text-n-slate-12">
              {{
                step.prompt ||
                step.message ||
                step.outcome ||
                step.tool?.key ||
                '—'
              }}
            </p>
          </div>
        </section>
        <p
          class="p-4 text-xs border rounded-xl border-n-weak text-n-slate-10 bg-n-solid-1"
        >
          {{ t('CHATRING_PLAYBOOKS.BOUNDARY') }}
        </p>
      </aside>
    </main>
  </div>
</template>
