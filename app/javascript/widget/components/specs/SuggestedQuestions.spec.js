import { mount } from '@vue/test-utils';
import SuggestedQuestions from '../SuggestedQuestions.vue';

describe('SuggestedQuestions', () => {
  it('renders at most two server-projected questions and emits the selected prompt', async () => {
    const wrapper = mount(SuggestedQuestions, {
      props: { questions: ['One?', 'Two?', 'Three?'] },
    });

    expect(wrapper.findAll('button')).toHaveLength(2);
    await wrapper.findAll('button')[1].trigger('click');
    expect(wrapper.emitted('select')).toEqual([['Two?']]);
  });
});
