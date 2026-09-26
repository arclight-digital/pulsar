"""Import the pulsar-theme engine as a module.

The engine is a script named `pulsar-theme` (no .py suffix: it is a command),
so `import` cannot find it. This is the one place that knows how; the
picker, the build scripts and the theme gate all go through it. It is
installed beside the engine in /usr/libexec/pulsar/, and lives beside it in
scripts/ in a checkout.

Uses spec_from_loader + exec_module: SourceFileLoader.load_module is
deprecated and goes away in Python 3.15.
"""
import importlib.machinery
import importlib.util
import pathlib


def load(path=None):
    path = pathlib.Path(path) if path else pathlib.Path(__file__).resolve().parent / "pulsar-theme"
    loader = importlib.machinery.SourceFileLoader("pulsar_theme", str(path))
    spec = importlib.util.spec_from_loader("pulsar_theme", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod
