import { frontendURL } from 'dashboard/helper/URLHelper';

const ToolsIndex = () => import('./pages/ToolsIndex.vue');

export const routes = [
  {
    path: frontendURL('accounts/:accountId/ai/tools'),
    name: 'chatring_tools_index',
    meta: { permissions: ['administrator'] },
    component: ToolsIndex,
  },
];
