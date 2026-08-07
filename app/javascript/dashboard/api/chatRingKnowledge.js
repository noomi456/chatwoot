/* global axios */
import ApiClient from './ApiClient';

class ChatRingKnowledgeAPI extends ApiClient {
  constructor() {
    super('chat_ring/knowledge', { accountScoped: true });
  }

  website(inboxId, rootUrl) {
    return axios.post(`${this.url}/websites`, {
      inbox_id: inboxId,
      root_url: rootUrl,
    });
  }

  fileSources(inboxId) {
    return axios.get(`${this.url}/file_sources`, {
      params: { inbox_id: inboxId },
    });
  }

  fileSource(inboxId, id) {
    return axios.get(`${this.url}/file_sources/${id}`, {
      params: { inbox_id: inboxId },
    });
  }

  uploadFile(inboxId, file, authorityClass) {
    const body = new FormData();
    body.append('inbox_id', inboxId);
    body.append('file', file);
    body.append('authority_class', authorityClass);
    return axios.post(`${this.url}/file_sources`, body, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  }

  updateFile(inboxId, id, authorityClass) {
    return axios.patch(`${this.url}/file_sources/${id}`, {
      inbox_id: inboxId,
      authority_class: authorityClass,
    });
  }

  disableFile(inboxId, id) {
    return axios.delete(`${this.url}/file_sources/${id}`, {
      params: { inbox_id: inboxId },
    });
  }

  enableFile(inboxId, id) {
    return axios.post(`${this.url}/file_sources/${id}/enable`, {
      inbox_id: inboxId,
    });
  }

  purgeFile(inboxId, id) {
    return axios.delete(`${this.url}/file_sources/${id}/purge`, {
      params: { inbox_id: inboxId },
    });
  }

  retryFile(inboxId, id) {
    return axios.post(`${this.url}/file_sources/${id}/retry_parse`, {
      inbox_id: inboxId,
    });
  }

  versions(inboxId) {
    return axios.get(`${this.url}/versions`, {
      params: { inbox_id: inboxId },
    });
  }

  version(inboxId, id) {
    return axios.get(`${this.url}/versions/${id}`, {
      params: { inbox_id: inboxId },
    });
  }

  deleteWebsiteMaterial(inboxId, versionId, documentId) {
    return axios.delete(`${this.url}/website_materials/${documentId}`, {
      params: { inbox_id: inboxId, version_id: versionId },
    });
  }

  buildVersion(inboxId, baseVersionId) {
    return axios.post(`${this.url}/versions`, {
      inbox_id: inboxId,
      base_version_id: baseVersionId,
    });
  }

  publishVersion(inboxId, versionId) {
    return axios.post(`${this.url}/versions/${versionId}/publish`, {
      inbox_id: inboxId,
    });
  }

  rollback(inboxId) {
    return axios.post(`${this.url}/publication/rollback`, {
      inbox_id: inboxId,
    });
  }

  testRetrieval(inboxId, knowledgeVersionId, query) {
    return axios.post(`${this.url}/retrieval_tests`, {
      inbox_id: inboxId,
      knowledge_version_id: knowledgeVersionId,
      query,
    });
  }
}

export default new ChatRingKnowledgeAPI();
