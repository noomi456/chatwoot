import store from '../store';
class CampaignTimer {
  constructor() {
    this.campaignTimers = [];
    this.scrollCampaigns = [];
    this.triggeredCampaignIds = new Set();
    this.websiteToken = null;
  }

  initTimers = ({ campaigns }, websiteToken) => {
    this.clearTimers();
    this.websiteToken = websiteToken;
    campaigns.forEach(campaign => {
      const { timeOnPage, id: campaignId, triggerType } = campaign;
      if (triggerType === 'scroll_percentage') {
        this.scrollCampaigns.push(campaign);
        return;
      }
      this.campaignTimers[campaignId] = setTimeout(() => {
        this.startCampaign(campaignId);
      }, timeOnPage * 1000);
    });
  };

  updateScrollPercentage = percentage => {
    const normalized = Number(percentage);
    if (!Number.isFinite(normalized)) return;

    this.scrollCampaigns.forEach(campaign => {
      if (normalized >= Number(campaign.scrollPercentage)) {
        this.startCampaign(campaign.id);
      }
    });
  };

  startCampaign = campaignId => {
    if (this.triggeredCampaignIds.has(campaignId)) return;

    this.triggeredCampaignIds.add(campaignId);
    store.dispatch('campaign/startCampaign', {
      campaignId,
      websiteToken: this.websiteToken,
    });
  };

  clearTimers = () => {
    this.campaignTimers.forEach(timerId => {
      clearTimeout(timerId);
      this.campaignTimers[timerId] = null;
    });
    this.scrollCampaigns = [];
    this.triggeredCampaignIds.clear();
  };
}
export default new CampaignTimer();
