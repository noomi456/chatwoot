export const replaceProductName = (text, installationName) => {
  if (typeof text !== 'string' || !text || !installationName) return text;

  return text.replace(/chatwoot/gi, installationName);
};

export const replaceInstallationNameInTranslation = translatedText => {
  const installationName =
    typeof window === 'undefined'
      ? undefined
      : window.globalConfig?.INSTALLATION_NAME;

  return replaceProductName(translatedText, installationName);
};
