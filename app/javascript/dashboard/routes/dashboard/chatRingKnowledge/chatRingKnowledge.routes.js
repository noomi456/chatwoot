import { frontendURL } from 'dashboard/helper/URLHelper';

const KnowledgeIndex = () => import('./pages/KnowledgeIndex.vue');

export const routes = [
  {
    path: frontendURL('accounts/:accountId/ai/knowledge'),
    name: 'chatring_knowledge_index',
    meta: { permissions: ['administrator'] },
    component: KnowledgeIndex,
  },
];
