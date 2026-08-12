import store from '../../store';
import campaignTimer from '../campaignTimer';

describe('CampaignTimer', () => {
  let dispatchSpy;

  beforeEach(() => {
    vi.useFakeTimers();
    dispatchSpy = vi.spyOn(store, 'dispatch').mockImplementation(() => {});
    campaignTimer.clearTimers();
  });

  afterEach(() => {
    dispatchSpy.mockRestore();
    vi.useRealTimers();
  });

  it('uses the existing native Campaign start action for wait-time triggers', () => {
    campaignTimer.initTimers(
      {
        campaigns: [{ id: 1, triggerType: 'time_on_page', timeOnPage: 3 }],
      },
      'website-token'
    );

    vi.advanceTimersByTime(3000);

    expect(store.dispatch).toHaveBeenCalledOnce();
    expect(store.dispatch).toHaveBeenCalledWith('campaign/startCampaign', {
      campaignId: 1,
      websiteToken: 'website-token',
    });
  });

  it('starts a scroll campaign once when the host page crosses its threshold', () => {
    campaignTimer.initTimers(
      {
        campaigns: [
          {
            id: 2,
            triggerType: 'scroll_percentage',
            scrollPercentage: 60,
          },
        ],
      },
      'website-token'
    );

    campaignTimer.updateScrollPercentage(59);
    campaignTimer.updateScrollPercentage(60);
    campaignTimer.updateScrollPercentage(90);

    expect(store.dispatch).toHaveBeenCalledOnce();
    expect(store.dispatch).toHaveBeenCalledWith('campaign/startCampaign', {
      campaignId: 2,
      websiteToken: 'website-token',
    });
  });
});
