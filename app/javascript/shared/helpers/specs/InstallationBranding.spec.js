import {
  replaceInstallationNameInTranslation,
  replaceProductName,
} from '../InstallationBranding';

describe('InstallationBranding', () => {
  afterEach(() => {
    window.globalConfig = undefined;
  });

  it('replaces every casing of the upstream product name', () => {
    expect(
      replaceProductName('Chatwoot, chatwoot and CHATWOOT', 'ChatRing')
    ).toBe('ChatRing, ChatRing and ChatRing');
  });

  it('leaves non-string translations unchanged', () => {
    expect(replaceProductName(null, 'ChatRing')).toBe(null);
    expect(replaceProductName(undefined, 'ChatRing')).toBe(undefined);
  });

  it('uses the installation name for translated UI text', () => {
    window.globalConfig = { INSTALLATION_NAME: 'ChatRing' };

    expect(replaceInstallationNameInTranslation('Login to Chatwoot')).toBe(
      'Login to ChatRing'
    );
  });
});
