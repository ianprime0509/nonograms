# Nonograms

A WIP [Nonograms](https://en.wikipedia.org/wiki/Nonogram) game written using Zig
and GTK.

![A screenshot of Nonograms showing an in-progress puzzle](./screenshot.png)

Flatpak build and install command:

```sh
flatpak-builder \
  --user \
  --install \
  --force-clean \
  --state-dir=zig-out/flatpak-builder \
  --install-deps-from=flathub \
  --repo=zig-out/repo \
  zig-out/builddir \
  build-aux/dev.ianjohnson.Nonograms.yaml
```
