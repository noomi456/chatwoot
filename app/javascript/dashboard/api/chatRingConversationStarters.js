/* global axios */
import ApiClient from './ApiClient';

class ChatRingConversationStartersAPI extends ApiClient {
  constructor() {
    super('chat_ring/inbox_conversation_starters', { accountScoped: true });
  }

  list() {
    return axios.get(this.url);
  }

  update(inboxId, conversationStarters) {
    return axios.patch(`${this.url}/${inboxId}`, {
      conversation_starters: conversationStarters,
    });
  }
}

export default new ChatRingConversationStartersAPI();
