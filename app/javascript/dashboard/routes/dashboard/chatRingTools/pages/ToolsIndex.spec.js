import { flushPromises, mount } from '@vue/test-utils';
import { vi } from 'vitest';
import ToolsIndex from './ToolsIndex.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  list: vi.fn(),
  definitions: vi.fn(),
  publish: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('dashboard/api/chatRingTools', () => ({
  default: {
    list: mocks.list,
    definitions: mocks.definitions,
    publish: mocks.publish,
  },
}));

const configuredPolicy = (version = 1) => ({
  inbox: {
    id: 7,
    name: 'Website Sales',
    channel_type: 'Channel::WebWidget',
  },
  id: 4,
  status: 'active',
  lock_version: version,
  current_version: {
    id: 10 + version,
    version,
    enabled_tools: [{ key: 'request_appointment', version: 1 }],
    tool_configurations: {
      request_appointment: {
        provider: 'calendly',
        url: 'https://calendly.com/chatring/demo',
        fallback_mode: 'approved_link',
        link_label: 'Book a meeting',
      },
    },
  },
  capabilities: [
    {
      key: 'request_appointment',
      version: 1,
      available: true,
      renderer: 'approved_link',
      fallback: 'approved_link',
      reason: null,
    },
  ],
});

describe('ChatRing Tools administration page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.list.mockResolvedValue({ data: [configuredPolicy()] });
    mocks.definitions.mockResolvedValue({
      data: [
        {
          key: 'request_appointment',
          version: 1,
          description: 'Offer an approved appointment path.',
        },
      ],
    });
    mocks.publish.mockResolvedValue({ data: configuredPolicy(2) });
  });

  it('loads the Inbox policy and shows approved-link capability without offering an embed', async () => {
    const wrapper = mount(ToolsIndex);
    await flushPromises();

    expect(mocks.list).toHaveBeenCalledOnce();
    expect(mocks.definitions).toHaveBeenCalledOnce();
    expect(wrapper.text()).toContain('Offer an approved appointment path.');
    expect(wrapper.text()).toContain('CHATRING_TOOLS.EMBED_DEFERRED');
    expect(wrapper.text()).toContain('approved_link');
  });

  it('publishes only the approved Inbox-owned appointment configuration', async () => {
    const wrapper = mount(ToolsIndex);
    await flushPromises();

    const saveButton = wrapper
      .findAll('button')
      .find(button => button.text().includes('CHATRING_TOOLS.SAVE'));
    await saveButton.trigger('click');
    await flushPromises();

    expect(mocks.publish).toHaveBeenCalledWith(7, {
      lock_version: 1,
      enabled_tools: [{ key: 'request_appointment', version: 1 }],
      tool_configurations: {
        request_appointment: {
          provider: 'calendly',
          url: 'https://calendly.com/chatring/demo',
          fallback_mode: 'approved_link',
          link_label: 'Book a meeting',
        },
      },
      renderer_policy: {},
    });
    expect(mocks.alert).toHaveBeenCalledWith('CHATRING_TOOLS.SAVED');
  });
});
