/* global axios */
import ApiClient from './ApiClient';

class ChatRingKnowledgeAPI extends ApiClient {
  constructor() {
    super('chat_ring/knowledge', { accountScoped: true });
  }

  addWebsite(rootUrl) {
    return axios.post(`${this.url}/websites`, { root_url: rootUrl });
  }

  addWebpage(url) {
    return axios.post(`${this.url}/webpages`, { url });
  }

  materials() {
    return axios.get(`${this.url}/materials`);
  }

  material(id) {
    return axios.get(`${this.url}/materials/${id}`);
  }

  uploadFile(file) {
    const body = new FormData();
    body.append('file', file);
    return axios.post(`${this.url}/file_sources`, body, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  }

  rerunMaterial(id) {
    return axios.post(`${this.url}/materials/${id}/rerun`);
  }

  deleteMaterial(id) {
    return axios.delete(`${this.url}/materials/${id}`);
  }
}

export default new ChatRingKnowledgeAPI();
