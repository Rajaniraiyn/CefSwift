// Runs one chrome.tabs / chrome.windows / chrome.tabGroups operation named
// in the page's address and shows its result in the title, for checks that
// load `chrome-extension://<id>/tabs.html?op=<op>&…` and read the title:
//   op=query                         every tab: [id, windowId, index, active, pinned, groupId, url]
//   op=windows                       every window: [id, type, focused, tabCount]
//   op=groups                        every group: [id, windowId, title, color, collapsed]
//   op=create&url=U[&windowId=W]     tabs.create
//   op=update&tab=T&url=U            tabs.update (navigate)
//   op=activate&tab=T                tabs.update({active: true})
//   op=pin&tab=T[&pinned=false]      tabs.update({pinned})
//   op=move&tab=T&index=I[&windowId=W]   tabs.move
//   op=group&tabs=T1,T2[&title=…&color=…]   tabs.group, then tabGroups.update
//   op=ungroup&tabs=T1,T2            tabs.ungroup
//   op=remove&tab=T                  tabs.remove
//   op=window&url=U                  windows.create
//   op=tabToWindow&tab=T             windows.create({tabId}) — moves the tab to a new window
// The title is `ok <json>` or `error <message>`.
const query = new URLSearchParams(location.search);
const number = name => Number(query.get(name));
const numbers = name => (query.get(name) ?? '').split(',').filter(Boolean).map(Number);
const operations = {
  query: async () => (await chrome.tabs.query({})).map(t => [t.id, t.windowId, t.index, t.active, t.pinned, t.groupId, t.url]),
  windows: async () => (await chrome.windows.getAll({ populate: true })).map(w => [w.id, w.type, w.focused, (w.tabs ?? []).length]),
  groups: async () => (await chrome.tabGroups.query({})).map(g => [g.id, g.windowId, g.title, g.color, g.collapsed]),
  create: async () => {
    const t = await chrome.tabs.create({ url: query.get('url'), active: false, ...(query.has('windowId') ? { windowId: number('windowId') } : {}) });
    return [t.id, t.windowId, t.index];
  },
  update: async () => (await chrome.tabs.update(number('tab'), { url: query.get('url') })).id,
  activate: async () => (await chrome.tabs.update(number('tab'), { active: true })).active,
  pin: async () => (await chrome.tabs.update(number('tab'), { pinned: query.get('pinned') !== 'false' })).pinned,
  move: async () => {
    const moved = await chrome.tabs.move(number('tab'), { index: number('index'), ...(query.has('windowId') ? { windowId: number('windowId') } : {}) });
    return [moved.id, moved.windowId, moved.index];
  },
  group: async () => {
    const group = await chrome.tabs.group({ tabIds: numbers('tabs') });
    if (query.has('title') || query.has('color')) {
      await chrome.tabGroups.update(group, { title: query.get('title') ?? undefined, color: query.get('color') ?? undefined });
    }
    return group;
  },
  ungroup: async () => { await chrome.tabs.ungroup(numbers('tabs')); return true; },
  remove: async () => { await chrome.tabs.remove(number('tab')); return true; },
  window: async () => { const w = await chrome.windows.create({ url: query.get('url') }); return [w.id, w.type]; },
  tabToWindow: async () => { const w = await chrome.windows.create({ tabId: number('tab') }); return [w.id, w.type]; },
};
(async () => {
  try {
    const run = operations[query.get('op') ?? 'query'];
    if (!run) throw new Error('unknown op ' + query.get('op'));
    document.title = 'ok ' + JSON.stringify(await run());
  } catch (e) {
    document.title = 'error ' + (e?.message ?? e);
  }
})();
