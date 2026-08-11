/* global axios */
import ApiClient from './ApiClient';

class ChatRingEngagementsAPI extends ApiClient {
  constructor() {
    super('chat_ring/inbox_engagements', { accountScoped: true });
  }

  list() {
    return axios.get(this.url);
  }

  update(inboxId, engagement) {
    return axios.patch(`${this.url}/${inboxId}`, { engagement });
  }
}

export default new ChatRingEngagementsAPI();
