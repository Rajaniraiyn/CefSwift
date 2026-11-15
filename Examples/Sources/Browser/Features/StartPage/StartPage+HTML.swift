extension StartPage {
    /// The page: tiles filled from the `startPage` bridge, redrawn when it
    /// says bookmarks changed.
    nonisolated static let html = """
        <title>New Tab</title>
        <style>
          body { padding: 72px 40px 40px; }
          main { max-width: 720px; margin: 0 auto; }
          h2 { font-size: 15px; font-weight: 650; margin: 0 0 10px 6px; }
          section { margin-bottom: 36px; }
          [hidden] { display: none !important; }
          .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(88px, 1fr)); gap: 6px; }
          .tile { display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 12px 4px 8px;
            border-radius: 12px; color: inherit; text-decoration: none; cursor: default; min-width: 0; }
          .tile:hover { background: color-mix(in srgb, currentColor 7%, transparent); }
          .monogram { width: 56px; height: 56px; border-radius: 14px; display: grid; place-items: center;
            font-size: 24px; font-weight: 600; color: white; background: hsl(var(--hue) 52% 50%);
            box-shadow: 0 1px 2px rgb(0 0 0 / 0.18), inset 0 0 0 0.5px rgb(255 255 255 / 0.2); }
          .monogram.icon { background: color-mix(in srgb, currentColor 8%, transparent); }
          .monogram.icon img { width: 32px; height: 32px; }
          .name { font-size: 12px; line-height: 1.3; max-width: 100%; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; text-align: center; }
          .note { display: flex; gap: 12px; align-items: center; padding: 14px 16px; margin-bottom: 36px;
            border-radius: 12px; background: color-mix(in srgb, currentColor 6%, transparent); }
          .note p { margin: 0; font-size: 13px; }
          .note strong { display: block; font-weight: 600; }
          .empty { margin-left: 6px; font-size: 13px; }
        </style>
        <main>
          <div class="note" id="private" hidden>
            <span style="font-size: 26px">✋</span>
            <p><strong>Private Browsing</strong>This tab doesn’t keep history, cookies or site data once it closes.</p>
          </div>
          <section id="frequent" hidden><h2>Frequently Visited</h2><div class="tiles"></div></section>
          <section id="bookmarks" hidden><h2>Bookmarks</h2><div class="tiles"></div></section>
          <p class="empty" id="empty" hidden>Sites you visit often and pages you bookmark appear here.</p>
        </main>
        <script>
          const hostOf = url => { try { return new URL(url).hostname.replace(/^www\\./, ''); } catch { return url; } };
          const hue = text => [...text].reduce((sum, c) => (sum * 31 + c.charCodeAt(0)) % 360, 7);
          function tile(site) {
            const host = hostOf(site.url);
            const link = document.createElement('a');
            link.className = 'tile';
            link.href = site.url;
            link.title = site.title ? site.title + '\\n' + site.url : site.url;
            const monogram = document.createElement('span');
            monogram.className = 'monogram';
            monogram.style.setProperty('--hue', hue(host));
            if (site.icon) {
              const icon = document.createElement('img');
              icon.src = site.icon;
              icon.alt = '';
              monogram.classList.add('icon');
              monogram.append(icon);
            } else {
              monogram.textContent = (host[0] ?? '?').toUpperCase();
            }
            const name = document.createElement('span');
            name.className = 'name';
            name.textContent = site.title || host;
            link.append(monogram, name);
            return link;
          }
          function fill(id, sites) {
            const section = document.getElementById(id);
            section.querySelector('.tiles').replaceChildren(...sites.map(tile));
            section.hidden = sites.length === 0;
          }
          async function render() {
            const content = await startPage.load();
            document.getElementById('private').hidden = !content.isPrivate;
            fill('frequent', content.frequentlyVisited);
            fill('bookmarks', content.bookmarks);
            document.getElementById('empty').hidden = content.frequentlyVisited.length + content.bookmarks.length > 0;
          }
          render();
          startPage.on('changed', render);
        </script>
        """
}
