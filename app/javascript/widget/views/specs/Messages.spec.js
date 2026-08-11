import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import Messages from '../Messages.vue';

describe('Widget Messages conversation starters', () => {
  let sendMessage;
  let store;

  const mountView = (
    messages,
    { allMessagesLoaded = true, isFetchingList = false } = {}
  ) => {
    store = createStore({
      modules: {
        conversation: {
          namespaced: true,
          state: { messages },
          getters: {
            getGroupedConversation: () => [],
            getConversationSize: () => messages.length,
            getAllMessagesLoaded: () => allMessagesLoaded,
            getIsFetchingList: () => isFetchingList,
          },
          actions: {
            sendMessage,
            setUserLastSeen: vi.fn(),
          },
        },
      },
    });

    return shallowMount(Messages, { global: { plugins: [store] } });
  };

  beforeEach(() => {
    sendMessage = vi.fn();
    window.chatwootWebChannel = {
      conversationStarters: [
        {
          label: 'See pricing',
          prompt: 'What pricing plans do you offer?',
        },
      ],
    };
  });

  it('sends a starter through the existing native Widget message action', async () => {
    const wrapper = mountView([]);

    await wrapper.getComponent({ name: 'ConversationStarters' }).vm.$emit(
      'select',
      'What pricing plans do you offer?'
    );

    expect(sendMessage).toHaveBeenCalledWith(expect.anything(), {
      content: 'What pricing plans do you offer?',
      replyTo: null,
    });
  });

  it('does not show starters after the native conversation contains a message', () => {
    const wrapper = mountView([{ id: 1, content: 'Existing message' }]);

    expect(wrapper.findComponent({ name: 'ConversationStarters' }).exists()).toBe(
      false
    );
  });

  it('does not show starters before native message history has loaded', () => {
    const wrapper = mountView([], { allMessagesLoaded: false });

    expect(wrapper.findComponent({ name: 'ConversationStarters' }).exists()).toBe(
      false
    );
  });
});
