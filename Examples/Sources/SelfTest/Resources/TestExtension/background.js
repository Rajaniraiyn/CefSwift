// SelfTest fixture: records what happened in chrome.storage.local, where the
// checks read it from the extension's options page.
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: 'cefswift-item', title: 'CefSwift Test Item', contexts: ['page'] });
});
chrome.action.setBadgeText({ text: '7' });
chrome.action.setBadgeBackgroundColor({ color: '#d03030' });
chrome.contextMenus.onClicked.addListener(info => {
  chrome.storage.local.set({ menuClicked: info.menuItemId });
});
chrome.commands.onCommand.addListener(command => {
  chrome.storage.local.set({ command });
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message === 'content-script-ran') {
    chrome.storage.local.set({ contentScriptURL: sender.url, contentScriptTab: sender.tab?.id ?? -1 });
  }
  reply('ok');
});
chrome.omnibox.onInputEntered.addListener(text => {
  chrome.storage.local.set({ omnibox: text });
});
