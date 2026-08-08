// Everything the page runs, in the order it has to run in: the theme state
// first, because the shader reads it, then the controls, then the shader.
import { initBeacon } from './beacon';
import { initCopy } from './copy';
import { initSky } from './sky';
import { initSpin } from './spin';
import { initTabs } from './tabs';
import { initTheme } from './theme';

initTheme();
initTabs();
initCopy();
initSpin();
initSky();

// Last, and not awaited: the only thing here that touches the network. It
// resolves after the page is already usable, and its failure mode is silence.
void initBeacon();
