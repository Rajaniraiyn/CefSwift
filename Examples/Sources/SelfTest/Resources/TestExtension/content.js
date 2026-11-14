document.documentElement.dataset.cefswiftFixture = 'ran';
chrome.runtime.sendMessage('content-script-ran').catch(() => {});
