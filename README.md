# Nonograms

A WIP [Nonograms](https://en.wikipedia.org/wiki/Nonogram) game written using Zig
and GTK.

This project is often used as a testing ground for new
[zig-gobject](https://github.com/ianprime0509/zig-object) changes, so it is
not guaranteed that it will always be buildable from scratch (the zig-gobject
dependency may refer to a relative path to a custom local build). This will
change as this project approaches some form of stability.

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
