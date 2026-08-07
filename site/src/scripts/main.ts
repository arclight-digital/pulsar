// Everything the page runs, in the order it has to run in: the theme state
// first, because the shader reads it, then the controls, then the shader.
import { initCopy } from './copy';
import { initSky } from './sky';
import { initTabs } from './tabs';
import { initTheme } from './theme';

initTheme();
initTabs();
initCopy();
initSky();
