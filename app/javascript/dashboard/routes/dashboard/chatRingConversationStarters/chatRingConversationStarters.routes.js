import { frontendURL } from 'dashboard/helper/URLHelper';

const ConversationStartersIndex = () =>
  import('./pages/ConversationStartersIndex.vue');

export const routes = [
  {
    path: frontendURL('accounts/:accountId/ai/conversation-starters'),
    name: 'chatring_conversation_starters_index',
    meta: { permissions: ['administrator'] },
    component: ConversationStartersIndex,
  },
];
