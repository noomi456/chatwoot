import { flushPromises, mount } from '@vue/test-utils';
import { vi } from 'vitest';
import AssistantsIndex from './AssistantsIndex.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  dispatch: vi.fn().mockResolvedValue(),
  list: vi.fn(),
  show: vi.fn(),
  createAssistant: vi.fn(),
  updateDraft: vi.fn(),
  publish: vi.fn(),
  bindingPreflight: vi.fn(),
  bind: vi.fn(),
  disableBinding: vi.fn(),
  rotateManagedSecret: vi.fn(),
  archive: vi.fn(),
  turns: vi.fn(),
  turn: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      Object.entries(params).reduce(
        (value, [name, replacement]) =>
          `${value} ${name}:${String(replacement)}`,
        key
      ),
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '1' } }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: () => ({
    value: [{ id: 7, name: 'Website', channel_type: 'Channel::WebWidget' }],
  }),
}));

vi.mock('dashboard/api/chatRingAssistants', () => ({
  default: {
    list: mocks.list,
    show: mocks.show,
    createAssistant: mocks.createAssistant,
    updateDraft: mocks.updateDraft,
    publish: mocks.publish,
    bindingPreflight: mocks.bindingPreflight,
    bind: mocks.bind,
    disableBinding: mocks.disableBinding,
    rotateManagedSecret: mocks.rotateManagedSecret,
    archive: mocks.archive,
    turns: mocks.turns,
    turn: mocks.turn,
  },
}));

const assistant = ({
  state = 'draft',
  currentVersion = null,
  bindings = [],
  lockVersion = 0,
  releaseReady = false,
} = {}) => ({
  id: 3,
  name: 'Website Sales',
  state,
  public_ai_release_ready: releaseReady,
  current_version: currentVersion,
  bindings,
  configuration_issues: [],
  draft: {
    identity: { name: 'Sales specialist' },
    goals: ['Qualify the visitor'],
    instructions: 'Use the shared Business Knowledge Base.',
    response_guidelines: ['Be concise'],
    guardrails: ['Never invent pricing'],
    handoff_policy: {
      on_insufficient_evidence: 'handoff',
      on_provider_failure: 'handoff',
    },
    llm_provider: 'openai',
    llm_model: 'gpt-5.4',
    lock_version: lockVersion,
  },
});

const mountPage = async (detail = assistant()) => {
  mocks.list.mockResolvedValue({ data: [{ ...detail, draft: undefined }] });
  mocks.show.mockResolvedValue({ data: detail });
  mocks.turns.mockResolvedValue({ data: [] });
  const wrapper = mount(AssistantsIndex, {
    global: {
      stubs: {
        RouterLink: { template: '<a><slot /></a>' },
      },
    },
  });
  await flushPromises();
  return wrapper;
};

describe('ChatRing Assistant administration page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.dispatch.mockResolvedValue();
  });

  it('loads native Inboxes and the selected Assistant without calling AgentBot APIs', async () => {
    const wrapper = await mountPage();

    expect(mocks.dispatch).toHaveBeenCalledWith('inboxes/get');
    expect(mocks.list).toHaveBeenCalledOnce();
    expect(mocks.show).toHaveBeenCalledWith(3);
    expect(mocks.turns).toHaveBeenCalledWith({ assistant_id: 3 });
    expect(wrapper.text()).toContain('Website Sales');
    expect(wrapper.text()).toContain('gpt-5.4');
  });

  it('saves one optimistic-locked draft and publishes through the management API', async () => {
    const detail = assistant({ lockVersion: 4 });
    const updated = assistant({ lockVersion: 5 });
    const published = assistant({
      state: 'published_unbound',
      releaseReady: true,
      lockVersion: 5,
      currentVersion: { id: 10, version: 1, llm_model: 'gpt-5.4' },
    });
    mocks.updateDraft.mockResolvedValue({ data: updated });
    mocks.publish.mockResolvedValue({ data: { assistant: published } });
    const wrapper = await mountPage(detail);

    const textareas = wrapper.findAll('textarea');
    await textareas[0].setValue('Qualify\nBook a demo');
    await textareas[1].setValue('Answer only from approved evidence.');
    await textareas[2].setValue('Be concise\nAsk one question');
    await textareas[3].setValue('Never invent pricing\nNever expose PII');
    const saveButton = wrapper
      .findAll('button')
      .find(item => item.text().includes('CHATRING_ASSISTANTS.SAVE_DRAFT'));
    await saveButton.trigger('click');
    await flushPromises();

    expect(mocks.updateDraft).toHaveBeenCalledWith(
      3,
      expect.objectContaining({
        lock_version: 4,
        goals: ['Qualify', 'Book a demo'],
        instructions: 'Answer only from approved evidence.',
        response_guidelines: ['Be concise', 'Ask one question'],
        guardrails: ['Never invent pricing', 'Never expose PII'],
      })
    );

    const publishButton = wrapper
      .findAll('button')
      .find(item => item.text().includes('CHATRING_ASSISTANTS.PUBLISH'));
    await publishButton.trigger('click');
    await flushPromises();
    expect(mocks.publish).toHaveBeenCalledWith(3, 5);
  });

  it('preserves unsaved edits when optimistic locking rejects a stale draft', async () => {
    mocks.updateDraft.mockRejectedValue({ response: { status: 409 } });
    const wrapper = await mountPage(assistant({ lockVersion: 4 }));
    const instructions = wrapper.findAll('textarea')[1];
    await instructions.setValue('My unsaved replacement instructions');
    const saveButton = wrapper
      .findAll('button')
      .find(item => item.text().includes('CHATRING_ASSISTANTS.SAVE_DRAFT'));
    await saveButton.trigger('click');
    await flushPromises();

    expect(instructions.element.value).toBe(
      'My unsaved replacement instructions'
    );
    expect(wrapper.text()).toContain('CHATRING_ASSISTANTS.RELOAD_DRAFT');
    expect(mocks.show).toHaveBeenCalledTimes(1);
  });

  it('keeps new Inbox connection controls closed with the public release gate', async () => {
    const wrapper = await mountPage(
      assistant({
        state: 'published_unbound',
        currentVersion: { id: 10, version: 1, llm_model: 'gpt-5.4' },
        releaseReady: false,
      })
    );

    expect(wrapper.text()).toContain('CHATRING_ASSISTANTS.RELEASE_CLOSED');
    expect(wrapper.findAll('select')[2].attributes('disabled')).toBeDefined();
    expect(mocks.bindingPreflight).not.toHaveBeenCalled();
  });

  it('requires native preflight before connecting and disables by binding id', async () => {
    const published = assistant({
      state: 'published_unbound',
      releaseReady: true,
      currentVersion: { id: 10, version: 1, llm_model: 'gpt-5.4' },
    });
    const active = assistant({
      state: 'active',
      releaseReady: true,
      currentVersion: { id: 10, version: 1, llm_model: 'gpt-5.4' },
      bindings: [{ id: 44, inbox_id: 7, status: 'active' }],
    });
    mocks.bindingPreflight.mockResolvedValue({
      data: {
        ready: true,
        conflicts: [],
        impact: {
          pending_conversations: 0,
          non_pending_conversations: 0,
          nonterminal_turns: 0,
        },
      },
    });
    mocks.bind.mockResolvedValue({ data: active.bindings[0] });
    mocks.disableBinding.mockResolvedValue({});
    const wrapper = await mountPage(published);

    const selects = wrapper.findAll('select');
    await selects[2].setValue('7');
    const checkButton = wrapper
      .findAll('button')
      .find(item => item.text().includes('CHATRING_ASSISTANTS.CHECK_INBOX'));
    await checkButton.trigger('click');
    await flushPromises();
    expect(mocks.bindingPreflight).toHaveBeenCalledWith(3, 7);

    mocks.show.mockResolvedValueOnce({ data: active });
    const connectButton = wrapper
      .findAll('button')
      .find(item => item.text().includes('CHATRING_ASSISTANTS.CONNECT'));
    await connectButton.trigger('click');
    await flushPromises();
    expect(mocks.bind).toHaveBeenCalledWith(3, 7);

    vi.spyOn(window, 'confirm').mockReturnValueOnce(true);
    const disableButton = wrapper
      .findAll('button')
      .find(item => item.text().includes('CHATRING_ASSISTANTS.DISABLE'));
    await disableButton.trigger('click');
    await flushPromises();
    expect(mocks.disableBinding).toHaveBeenCalledWith(44);
  });
});
