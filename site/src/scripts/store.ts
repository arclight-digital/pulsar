// localStorage can throw wholesale in strict privacy modes, not just on write.
// One throw must not take down theming, the copy buttons and the shader
// together, so every access goes through here.
export const store = {
  get(key: string): string | null {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set(key: string, value: string): void {
    try {
      localStorage.setItem(key, value);
    } catch {
      /* private mode: the choice simply does not persist */
    }
  },
};
