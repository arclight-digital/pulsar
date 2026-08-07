// The install card's terminal tabs.
//
// The default tab is whichever button starts aria-selected in the markup, so
// flipping the default to the ISO is a markup edit, not a code change. Arrow
// keys move between tabs per the tablist pattern.
export function initTabs(): void {
  for (const list of document.querySelectorAll<HTMLElement>('.tabs')) {
    const tabs = [...list.querySelectorAll<HTMLElement>('[role="tab"]')];

    const select = (tab: HTMLElement): void => {
      for (const candidate of tabs) {
        const on = candidate === tab;
        candidate.setAttribute('aria-selected', String(on));
        // Roving tabindex: without it Tab lands on every tab in turn, which
        // is not what a tablist is supposed to do.
        candidate.tabIndex = on ? 0 : -1;
        const id = candidate.getAttribute('aria-controls');
        const panel = id ? document.getElementById(id) : null;
        if (panel) panel.hidden = !on;
      }
    };

    for (const tab of tabs) {
      tab.tabIndex = tab.getAttribute('aria-selected') === 'true' ? 0 : -1;
      tab.addEventListener('click', () => select(tab));
    }

    list.addEventListener('keydown', (event: KeyboardEvent) => {
      const step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
      if (!step) return;
      event.preventDefault();
      const from = tabs.indexOf(document.activeElement as HTMLElement);
      const next = tabs[(from + step + tabs.length) % tabs.length];
      if (!next) return;
      next.focus();
      select(next);
    });
  }
}
