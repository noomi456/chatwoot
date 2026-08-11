/* global axios */
import ApiClient from './ApiClient';

class ChatRingPlaybooksAPI extends ApiClient {
  constructor() {
    super('chat_ring/inbox_playbooks', { accountScoped: true });
  }

  list(params = {}) {
    return axios.get(this.url, { params });
  }

  create(playbook) {
    return axios.post(this.url, { playbook });
  }

  updateDraft(id, playbook) {
    return axios.patch(`${this.url}/${id}/update_draft`, { playbook });
  }

  validate(id, definition) {
    return axios.post(`${this.url}/${id}/validate`, { definition });
  }

  publish(id, lockVersion) {
    return axios.post(`${this.url}/${id}/publish`, {
      lock_version: lockVersion,
    });
  }

  disable(id, lockVersion) {
    return axios.post(`${this.url}/${id}/disable`, {
      lock_version: lockVersion,
    });
  }

  archive(id, lockVersion) {
    return axios.post(`${this.url}/${id}/archive`, {
      lock_version: lockVersion,
    });
  }
}

export default new ChatRingPlaybooksAPI();
