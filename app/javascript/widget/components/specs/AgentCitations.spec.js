import { mount } from '@vue/test-utils';
import AgentCitations from '../AgentCitations.vue';

describe('AgentCitations', () => {
  it('renders visitor-safe source links in a new tab', () => {
    const wrapper = mount(AgentCitations, {
      props: {
        citations: [
          {
            title: 'Pricing',
            url: 'https://chatring.ai/pricing',
            heading_path: ['Plans'],
          },
        ],
      },
    });

    const link = wrapper.get('a');
    expect(link.text()).toBe('Pricing');
    expect(link.attributes()).toMatchObject({
      href: 'https://chatring.ai/pricing',
      target: '_blank',
      rel: 'noopener noreferrer',
    });
  });

  it('renders nothing without approved citations', () => {
    const wrapper = mount(AgentCitations);

    expect(wrapper.find('ul').exists()).toBe(false);
  });

  it('rejects unsafe or malformed citation links at the rendering boundary', () => {
    const wrapper = mount(AgentCitations, {
      props: {
        citations: [
          { title: 'Unsafe', url: 'data:text/html,unsafe' },
          { title: 'Malformed', url: 'not a URL' },
          { title: '', url: 'https://chatring.ai' },
        ],
      },
    });

    expect(wrapper.find('ul').exists()).toBe(false);
  });
});
