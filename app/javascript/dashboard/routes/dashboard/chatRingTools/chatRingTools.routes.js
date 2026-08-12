import { frontendURL } from 'dashboard/helper/URLHelper';

export const routes = [
  {
    path: frontendURL('accounts/:accountId/ai/tools'),
    name: 'chatring_tools_index',
    meta: { permissions: ['administrator'] },
    redirect: to => ({
      name: 'chatring_playbooks_index',
      params: { accountId: to.params.accountId },
    }),
  },
];
