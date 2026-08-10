/* global axios */
import ApiClient from './ApiClient';

class ChatRingToolsAPI extends ApiClient {
  constructor() {
    super('chat_ring/inbox_tool_policies', { accountScoped: true });
  }

  list() {
    return axios.get(this.url);
  }

  definitions() {
    return axios.get(`${this.url}/definitions`);
  }

  show(inboxId) {
    return axios.get(`${this.url}/${inboxId}`);
  }

  publish(inboxId, toolPolicy) {
    return axios.patch(`${this.url}/${inboxId}`, {
      tool_policy: toolPolicy,
    });
  }
}

export default new ChatRingToolsAPI();
