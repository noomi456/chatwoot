<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import ChatRingToolsAPI from 'dashboard/api/chatRingTools';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const { t } = useI18n();

const policies = ref([]);
const definitions = ref([]);
const selectedInboxId = ref('');
const isLoading = ref(true);
const isSaving = ref(false);
const form = ref({
  enabled: false,
  provider: 'calendly',
  url: '',
  linkLabel: 'Book a meeting',
  calendarEmbed: false,
});

const inboxOptions = computed(() =>
  policies.value.map(policy => ({
    value: String(policy.inbox.id),
    label: `${policy.inbox.name} · ${policy.inbox.channel_type}`,
  }))
);
const providerOptions = [
  { value: 'calendly', label: 'Calendly' },
  { value: 'calcom', label: 'Cal.com' },
  { value: 'custom_link', label: 'Approved link' },
];
const selectedPolicy = computed(() =>
  policies.value.find(
    policy => String(policy.inbox.id) === String(selectedInboxId.value)
  )
);
const currentCapability = computed(() =>
  selectedPolicy.value?.capabilities?.find(
    capability => capability.key === 'request_appointment'
  )
);
const appointmentDefinition = computed(() =>
  definitions.value.find(definition => definition.key === 'request_appointment')
);
const canEmbedCalendar = computed(
  () =>
    selectedPolicy.value?.inbox?.channel_type === 'Channel::WebWidget' &&
    form.value.provider === 'calendly'
);

const apiError = error =>
  error?.response?.data?.error || error?.message || t('CHATRING_TOOLS.ERROR');

const setFormFromPolicy = policy => {
  const version = policy?.current_version;
  const configuration = version?.tool_configurations?.request_appointment || {};
  form.value = {
    enabled:
      version?.enabled_tools?.some(
        tool => tool.key === 'request_appointment' && tool.version === 1
      ) || false,
    provider: configuration.provider || 'calendly',
    url: configuration.url || '',
    linkLabel: configuration.link_label || 'Book a meeting',
    calendarEmbed: configuration.website_presentation === 'calendar_embed',
  };
};

watch(selectedPolicy, policy => setFormFromPolicy(policy));
watch(
  () => form.value.provider,
  () => {
    if (!canEmbedCalendar.value) form.value.calendarEmbed = false;
  }
);

const load = async () => {
  isLoading.value = true;
  try {
    const [policyResponse, definitionResponse] = await Promise.all([
      ChatRingToolsAPI.list(),
      ChatRingToolsAPI.definitions(),
    ]);
    policies.value = policyResponse.data;
    definitions.value = definitionResponse.data;
    selectedInboxId.value ||= String(policies.value[0]?.inbox?.id || '');
    setFormFromPolicy(selectedPolicy.value);
  } catch (error) {
    useAlert(apiError(error));
  } finally {
    isLoading.value = false;
  }
};

const publish = async () => {
  if (!selectedPolicy.value || isSaving.value) return;
  isSaving.value = true;
  try {
    const payload = form.value.enabled
      ? {
          lock_version: selectedPolicy.value.lock_version,
          enabled_tools: [{ key: 'request_appointment', version: 1 }],
          tool_configurations: {
            request_appointment: {
              provider: form.value.provider,
              url: form.value.url.trim(),
              fallback_mode: 'approved_link',
              link_label: form.value.linkLabel.trim(),
              website_presentation: form.value.calendarEmbed
                ? 'calendar_embed'
                : 'approved_link',
            },
          },
          renderer_policy: {},
        }
      : {
          lock_version: selectedPolicy.value.lock_version,
          enabled_tools: [],
          tool_configurations: {},
          renderer_policy: {},
        };
    const response = await ChatRingToolsAPI.publish(
      selectedPolicy.value.inbox.id,
      payload
    );
    const index = policies.value.findIndex(
      policy => policy.inbox.id === response.data.inbox.id
    );
    policies.value.splice(index, 1, response.data);
    setFormFromPolicy(response.data);
    useAlert(t('CHATRING_TOOLS.SAVED'));
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
        {{ t('CHATRING_TOOLS.TITLE') }}
      </h1>
      <p class="mt-1 text-sm text-n-slate-11">
        {{ t('CHATRING_TOOLS.DESCRIPTION') }}
      </p>
    </header>

    <div v-if="isLoading" class="flex items-center justify-center flex-1">
      <Spinner />
    </div>

    <main v-else class="grid max-w-6xl gap-6 p-8 lg:grid-cols-[18rem_1fr]">
      <aside class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
        <Select
          v-model="selectedInboxId"
          :label="t('CHATRING_TOOLS.INBOX')"
          :options="inboxOptions"
        />
        <p class="mt-4 text-xs text-n-slate-10">
          {{
            selectedPolicy?.current_version
              ? t('CHATRING_TOOLS.VERSION', {
                  version: selectedPolicy.current_version.version,
                })
              : t('CHATRING_TOOLS.NOT_CONFIGURED')
          }}
        </p>
      </aside>

      <section class="space-y-5">
        <article class="p-6 border rounded-xl border-n-weak bg-n-solid-1">
          <div class="flex items-start justify-between gap-5">
            <div>
              <h2 class="text-lg font-semibold text-n-slate-12">
                {{ t('CHATRING_TOOLS.APPOINTMENT_TITLE') }}
              </h2>
              <p class="mt-1 text-sm text-n-slate-11">
                {{
                  appointmentDefinition?.description ||
                  t('CHATRING_TOOLS.APPOINTMENT_DESCRIPTION')
                }}
              </p>
            </div>
            <div class="flex items-center gap-2 text-sm text-n-slate-12">
              <span>{{ t('CHATRING_TOOLS.ENABLED') }}</span>
              <Switch v-model="form.enabled" />
            </div>
          </div>

          <div v-if="form.enabled" class="grid gap-5 mt-6 md:grid-cols-2">
            <Select
              v-model="form.provider"
              :label="t('CHATRING_TOOLS.PROVIDER')"
              :options="providerOptions"
            />
            <Input
              v-model="form.linkLabel"
              :label="t('CHATRING_TOOLS.LINK_LABEL')"
            />
            <div class="md:col-span-2">
              <Input
                v-model="form.url"
                type="url"
                :label="t('CHATRING_TOOLS.URL')"
                placeholder="https://calendly.com/your-team/demo"
              />
            </div>
            <div
              class="flex items-start justify-between gap-5 p-4 border rounded-lg md:col-span-2 border-n-weak"
            >
              <div>
                <p class="text-sm font-medium text-n-slate-12">
                  {{ t('CHATRING_TOOLS.CALENDAR_EMBED') }}
                </p>
                <p class="mt-1 text-xs text-n-slate-10">
                  {{
                    canEmbedCalendar
                      ? t('CHATRING_TOOLS.CALENDAR_EMBED_DESCRIPTION')
                      : t('CHATRING_TOOLS.CALENDAR_EMBED_UNAVAILABLE')
                  }}
                </p>
              </div>
              <Switch
                v-model="form.calendarEmbed"
                :disabled="!canEmbedCalendar"
              />
            </div>
          </div>
        </article>

        <article class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
          <h3 class="text-sm font-semibold text-n-slate-12">
            {{ t('CHATRING_TOOLS.CAPABILITY') }}
          </h3>
          <p class="mt-2 text-sm text-n-slate-11">
            {{
              currentCapability?.renderer === 'calendar_embed'
                ? t('CHATRING_TOOLS.CALENDAR_EMBED_ACTIVE')
                : t('CHATRING_TOOLS.APPROVED_LINK')
            }}
          </p>
          <p class="mt-2 text-xs text-n-slate-10">
            {{ t('CHATRING_TOOLS.APPROVED_LINK_FALLBACK') }}
          </p>
          <p v-if="currentCapability" class="mt-3 text-xs text-n-slate-10">
            {{ currentCapability.renderer }}
          </p>
        </article>

        <div class="flex justify-end">
          <Button :is-loading="isSaving" :disabled="isSaving" @click="publish">
            {{ t('CHATRING_TOOLS.SAVE') }}
          </Button>
        </div>
      </section>
    </main>
  </div>
</template>
