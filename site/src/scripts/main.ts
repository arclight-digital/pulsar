// Everything of Pulsar's own the page runs, in the order it has to run in:
// the theme state first, because the shader reads it, then the easter egg,
// then the shader. Copy buttons, tabs and the theme toggle are ARC UI's now
// and register from the layout's script block before this module runs.
import { initBeacon } from './beacon';
import { initSky } from './sky';
import { initSpin } from './spin';
import { initTheme } from './theme';

initTheme();
initSpin();
initSky();

// Last, and not awaited: the only thing here that touches the network. It
// resolves after the page is already usable, and its failure mode is silence.
void initBeacon();
