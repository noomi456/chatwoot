import { frontendURL } from 'dashboard/helper/URLHelper';

const EngagementsIndex = () => import('./pages/EngagementsIndex.vue');

export const routes = [
  {
    path: frontendURL('accounts/:accountId/ai/engagements'),
    name: 'chatring_engagements_index',
    meta: { permissions: ['administrator'] },
    component: EngagementsIndex,
  },
];
