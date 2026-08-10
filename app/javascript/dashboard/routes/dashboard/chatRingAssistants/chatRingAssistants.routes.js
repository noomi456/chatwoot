import { frontendURL } from 'dashboard/helper/URLHelper';

const AssistantsIndex = () => import('./pages/AssistantsIndex.vue');

export const routes = [
  {
    path: frontendURL('accounts/:accountId/ai/assistants'),
    name: 'chatring_assistants_index',
    meta: { permissions: ['administrator'] },
    component: AssistantsIndex,
  },
];
