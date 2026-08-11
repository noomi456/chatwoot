import { frontendURL } from 'dashboard/helper/URLHelper';

const PlaybooksIndex = () => import('./pages/PlaybooksIndex.vue');

export const routes = [
  {
    path: frontendURL('accounts/:accountId/ai/playbooks'),
    name: 'chatring_playbooks_index',
    meta: { permissions: ['administrator'] },
    component: PlaybooksIndex,
  },
];
