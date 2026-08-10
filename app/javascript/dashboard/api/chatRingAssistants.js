/* global axios */
import ApiClient from './ApiClient';

class ChatRingAssistantsAPI extends ApiClient {
  constructor() {
    super('chat_ring/assistants', { accountScoped: true });
  }

  list() {
    return axios.get(this.url);
  }

  show(id) {
    return axios.get(`${this.url}/${id}`);
  }

  createAssistant(name) {
    return axios.post(this.url, { assistant: { name } });
  }

  updateDraft(id, draft) {
    return axios.patch(`${this.url}/${id}/update_draft`, { draft });
  }

  publish(id, lockVersion) {
    return axios.post(`${this.url}/${id}/publish`, {
      lock_version: lockVersion,
    });
  }

  archive(id) {
    return axios.post(`${this.url}/${id}/archive`);
  }

  bindingPreflight(id, inboxId) {
    return axios.get(`${this.url}/${id}/binding_preflight`, {
      params: { inbox_id: inboxId },
    });
  }

  bind(id, inboxId) {
    return axios.post(`${this.url}/${id}/bind`, { inbox_id: inboxId });
  }

  disableBinding(bindingId) {
    return axios.delete(
      `${this.baseUrl()}/chat_ring/assistant_bindings/${bindingId}`
    );
  }

  rotateManagedSecret(id) {
    return axios.post(`${this.url}/${id}/rotate_managed_secret`);
  }

  turns(params = {}) {
    return axios.get(`${this.baseUrl()}/chat_ring/ai_turns`, { params });
  }

  turn(id) {
    return axios.get(`${this.baseUrl()}/chat_ring/ai_turns/${id}`);
  }
}

export default new ChatRingAssistantsAPI();
