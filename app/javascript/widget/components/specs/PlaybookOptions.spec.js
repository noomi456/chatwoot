import { mount } from '@vue/test-utils';
import PlaybookOptions from '../PlaybookOptions.vue';

describe('PlaybookOptions', () => {
  it('emits a server-projected option without mutating the original bot Message', async () => {
    const option = { label: 'Heavy Usage', value: 'heavy' };
    const wrapper = mount(PlaybookOptions, { props: { options: [option] } });

    await wrapper.get('button').trigger('click');

    expect(wrapper.emitted('select')).toEqual([[option]]);
  });
});
