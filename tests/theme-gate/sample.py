#!/usr/bin/python3
"""Sample buffer for the GtkSourceView screenshots."""
import colorsys  # a comment, in the muted slot

ACCENTS = {"blue": "#3584e4", "teal": 0x2190A4, "on": True}


class Palette:
    def __init__(self, name: str, *, dark: bool = True):
        self.name = name  # TODO: variants
        self.dark = dark

    def swatch(self, n=16):
        return [colorsys.hsv_to_rgb(i / n, 0.6, 0.9) for i in range(n)]


if __name__ == "__main__":
    print(f"{Palette('pulsar').name!r} -> {len(ACCENTS)} accents\n")
