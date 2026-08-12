import { mount } from '@vue/test-utils';
import MicrositeCard from '../MicrositeCard.vue';

describe('MicrositeCard', () => {
  it('renders only a bounded live public URL supplied by the server', () => {
    const wrapper = mount(MicrositeCard, {
      props: {
        presentation: {
          title: 'Internet guide',
          url: 'https://share.chatring.ai/s/token',
          section_types: ['hero', 'features_grid', 'faq_accordion'],
          expires_at: new Date(Date.now() + 60_000).toISOString(),
        },
      },
    });

    expect(wrapper.get('a').attributes('href')).toBe(
      'https://share.chatring.ai/s/token'
    );
    expect(wrapper.text()).toContain('Internet guide');
  });

  it('hides expired or non-http presentations', () => {
    const expired = mount(MicrositeCard, {
      props: {
        presentation: {
          title: 'Expired',
          url: 'https://share.chatring.ai/s/token',
          expires_at: new Date(Date.now() - 60_000).toISOString(),
        },
      },
    });
    const unsafe = mount(MicrositeCard, {
      props: {
        presentation: {
          title: 'Unsafe',
          url: ['java', 'script:alert(1)'].join(''),
          expires_at: new Date(Date.now() + 60_000).toISOString(),
        },
      },
    });

    expect(expired.find('a').exists()).toBe(false);
    expect(unsafe.find('a').exists()).toBe(false);
  });
});
