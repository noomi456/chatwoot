import { mount } from '@vue/test-utils';
import { vi } from 'vitest';
import AppointmentCalendar from '../AppointmentCalendar.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const presentation = {
  presentation_mode: 'calendar_embed',
  provider: 'calendly',
  approved_url: 'https://calendly.com/cqalerts3/30min',
  link_label: 'Book a 30 minute meeting',
};

describe('AppointmentCalendar', () => {
  it('loads the approved Calendly page only after the visitor opens it', async () => {
    const wrapper = mount(AppointmentCalendar, { props: { presentation } });

    expect(wrapper.find('iframe').exists()).toBe(false);
    expect(wrapper.get('button').text()).toBe('Book a 30 minute meeting');

    await wrapper.get('button').trigger('click');

    expect(wrapper.get('iframe').attributes()).toMatchObject({
      src: 'https://calendly.com/cqalerts3/30min',
      loading: 'lazy',
      referrerpolicy: 'strict-origin-when-cross-origin',
    });
    expect(wrapper.get('iframe').attributes('sandbox')).toContain(
      'allow-scripts'
    );
  });

  it.each([
    ['an unapproved provider', { ...presentation, provider: 'custom_link' }],
    [
      'an insecure URL',
      { ...presentation, approved_url: 'http://calendly.com/cqalerts3/30min' },
    ],
    [
      'a lookalike host',
      {
        ...presentation,
        approved_url: 'https://calendly.com.attacker.example/demo',
      },
    ],
    [
      'a custom port',
      { ...presentation, approved_url: 'https://calendly.com:8443/demo' },
    ],
    [
      'credentials',
      {
        ...presentation,
        approved_url: 'https://user:secret@calendly.com/demo',
      },
    ],
    [
      'an unapproved presentation',
      { ...presentation, presentation_mode: 'approved_link' },
    ],
  ])('renders no iframe control for %s', (_description, candidate) => {
    const wrapper = mount(AppointmentCalendar, {
      props: { presentation: candidate },
    });

    expect(wrapper.find('section').exists()).toBe(false);
  });
});
