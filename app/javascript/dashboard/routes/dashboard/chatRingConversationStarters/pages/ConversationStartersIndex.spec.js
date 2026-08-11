import { flushPromises, mount } from '@vue/test-utils';
import { vi } from 'vitest';
import ConversationStartersIndex from './ConversationStartersIndex.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  list: vi.fn(),
  update: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('dashboard/api/chatRingConversationStarters', () => ({
  default: { list: mocks.list, update: mocks.update },
}));

const configuration = lockVersion => ({
  inbox: {
    id: 7,
    name: 'Website Sales',
    channel_type: 'Channel::WebWidget',
  },
  id: 4,
  enabled: true,
  lock_version: lockVersion,
  starters: [
    { label: 'See pricing', prompt: 'What pricing plans do you offer?' },
    { label: 'Book a demo', prompt: 'I would like to book a demo.' },
  ],
});

describe('ChatRing Conversation Starters administration page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.list.mockResolvedValue({ data: [configuration(2)] });
    mocks.update.mockResolvedValue({ data: configuration(3) });
  });

  it('loads ordered Website Inbox starters', async () => {
    const wrapper = mount(ConversationStartersIndex);
    await flushPromises();

    expect(mocks.list).toHaveBeenCalledOnce();
    expect(wrapper.findAll('input').map(input => input.element.value)).toEqual([
      'See pricing',
      'What pricing plans do you offer?',
      'Book a demo',
      'I would like to book a demo.',
    ]);
    expect(wrapper.text()).toContain(
      'CHATRING_CONVERSATION_STARTERS.NATIVE_MESSAGE_NOTE'
    );
  });

  it('reorders and saves only the bounded starter contract', async () => {
    const wrapper = mount(ConversationStartersIndex);
    await flushPromises();

    const moveDown = wrapper
      .findAll('button')
      .find(
        button =>
          button.attributes('aria-label') ===
          'CHATRING_CONVERSATION_STARTERS.MOVE_DOWN'
      );
    await moveDown.trigger('click');

    const save = wrapper
      .findAll('button')
      .find(button =>
        button.text().includes('CHATRING_CONVERSATION_STARTERS.SAVE')
      );
    await save.trigger('click');
    await flushPromises();

    expect(mocks.update).toHaveBeenCalledWith(7, {
      lock_version: 2,
      enabled: true,
      starters: [
        { label: 'Book a demo', prompt: 'I would like to book a demo.' },
        { label: 'See pricing', prompt: 'What pricing plans do you offer?' },
      ],
    });
    expect(mocks.alert).toHaveBeenCalledWith(
      'CHATRING_CONVERSATION_STARTERS.SAVED'
    );
  });
});
