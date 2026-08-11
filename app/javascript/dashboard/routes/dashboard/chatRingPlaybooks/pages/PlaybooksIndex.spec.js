import { flushPromises, mount } from '@vue/test-utils';
import { vi } from 'vitest';
import PlaybooksIndex from './PlaybooksIndex.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  listPlaybooks: vi.fn(),
  create: vi.fn(),
  updateDraft: vi.fn(),
  validate: vi.fn(),
  publish: vi.fn(),
  listPolicies: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values) => (values?.number ? `${key} ${values.number}` : key),
  }),
}));

vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('dashboard/api/chatRingPlaybooks', () => ({
  default: {
    list: mocks.listPlaybooks,
    create: mocks.create,
    updateDraft: mocks.updateDraft,
    validate: mocks.validate,
    publish: mocks.publish,
  },
}));
vi.mock('dashboard/api/chatRingTools', () => ({
  default: { list: mocks.listPolicies },
}));

const definition = {
  trigger_phrases: ['pricing options'],
  entry_step_id: 'ask_need',
  collected_fields: [
    {
      key: 'need',
      type: 'string',
      required: true,
      native_contact_attribute_key: null,
    },
  ],
  tool_allowlist: [{ key: 'request_appointment', version: 1 }],
  steps: [
    {
      id: 'ask_need',
      kind: 'ask_text',
      prompt: 'What do you need?',
      field_key: 'need',
      next_step_id: 'appointment',
      tool_allowlist: [],
    },
    {
      id: 'appointment',
      kind: 'tool',
      tool: { key: 'request_appointment', version: 1 },
      tool_allowlist: [{ key: 'request_appointment', version: 1 }],
    },
  ],
  safety_rules: {
    on_human_request: 'native_availability',
    on_side_question: 'answer_then_resume',
  },
};

const playbook = (lockVersion = 2) => ({
  id: 9,
  name: 'Pricing discovery',
  purpose: 'Qualify pricing interest.',
  status: 'active',
  lock_version: lockVersion,
  inbox: {
    id: 7,
    name: 'Website Sales',
    channel_type: 'Channel::WebWidget',
  },
  draft_definition: definition,
  current_version: { id: 19, version: 1, definition },
});

describe('ChatRing Playbooks administration page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.listPlaybooks.mockResolvedValue({ data: [playbook()] });
    mocks.listPolicies.mockResolvedValue({
      data: [
        {
          inbox: {
            id: 7,
            name: 'Website Sales',
            channel_type: 'Channel::WebWidget',
          },
          capabilities: [
            {
              key: 'request_appointment',
              version: 1,
              available: true,
              renderer: 'approved_link',
            },
          ],
        },
      ],
    });
    mocks.updateDraft.mockResolvedValue({ data: playbook(3) });
    mocks.validate.mockResolvedValue({
      data: { valid: true, errors: [], warnings: [] },
    });
    mocks.publish.mockResolvedValue({
      data: {
        playbook: playbook(4),
        version: { validation_result: { valid: true, errors: [] } },
      },
    });
  });

  it('renders the Inbox-owned typed editor and visual preview without donor runtime state', async () => {
    const wrapper = mount(PlaybooksIndex);
    await flushPromises();

    expect(mocks.listPlaybooks).toHaveBeenCalledOnce();
    expect(mocks.listPolicies).toHaveBeenCalledOnce();
    expect(wrapper.text()).toContain('Pricing discovery');
    expect(wrapper.text()).toContain('ask_need · ask_text');
    expect(wrapper.text()).toContain('CHATRING_PLAYBOOKS.BOUNDARY');
    expect(wrapper.text()).not.toContain('Supabase');
  });

  it('saves only the typed definition and publishes the returned immutable revision', async () => {
    const wrapper = mount(PlaybooksIndex);
    await flushPromises();

    await wrapper.get('[data-testid="publish-playbook"]').trigger('click');
    await flushPromises();

    expect(mocks.updateDraft).toHaveBeenCalledWith(
      9,
      expect.objectContaining({
        lock_version: 2,
        name: 'Pricing discovery',
        definition: expect.objectContaining({
          trigger_phrases: ['pricing options'],
          tool_allowlist: [{ key: 'request_appointment', version: 1 }],
          safety_rules: {
            on_human_request: 'native_availability',
            on_side_question: 'answer_then_resume',
          },
        }),
      })
    );
    expect(mocks.publish).toHaveBeenCalledWith(9, 3);
  });
});
