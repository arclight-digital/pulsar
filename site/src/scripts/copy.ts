// Copy buttons.
//
// data-copy-text wins -- the verify sessions copy their one-line form rather
// than the wrapped transcript on screen -- otherwise the nearest row's or
// figure's code. A denied clipboard falls back to selecting the text so a
// manual Ctrl+C still works, and the live region narrates both outcomes.
export function initCopy(): void {
  const live = document.getElementById('live');
  const say = (message: string): void => {
    if (live) live.textContent = message;
  };

  for (const button of document.querySelectorAll<HTMLButtonElement>('[data-copy]')) {
    button.addEventListener('click', async () => {
      const code = button.closest('.row, figure')?.querySelector('code');
      const text = button.dataset.copyText ?? code?.textContent?.trim();
      if (!text) return;

      try {
        await navigator.clipboard.writeText(text);
      } catch {
        if (code) {
          const range = document.createRange();
          range.selectNodeContents(code);
          const selection = getSelection();
          selection?.removeAllRanges();
          selection?.addRange(range);
          say('Copy was blocked — the command is selected, press Ctrl+C');
        } else {
          say('Copy was blocked');
        }
        return;
      }

      button.classList.add('did');
      say('Copied to clipboard');
      setTimeout(() => button.classList.remove('did'), 1400);
    });
  }
}
