# umubuilder
A script for easily creating Proton packages, with custom patches and out-of-the-box support for a statically linked umu-launcher.

With no added options, `./setup.sh` will download, compile, and bundle [Proton](https://github.com/GloriousEggroll/proton-ge-custom) + [protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes) + [umu-run](https://github.com/Open-Wine-Components/umu-launcher) together into a redistributable `$pkgname.tar.xz` in a `build_tarballs` directory. It will also try to install these files to your `$HOME/.steam/root/compatibilitytools.d/`, with the `$buildname` as the compatibility tool's name.

The process of creating the statically linked `umu-run` will require [PyOxidizer](https://github.com/indygreg/PyOxidizer) 0.23.0 to be available, along with the rust `x86_64-unknown-linux-musl` toolchain. A minimal [bootstrap script](https://github.com/whrvt/umubuilder/blob/master/umu-bundler/pyoxidizer_bootstrap.sh) will try to make sure that these are available before proceeding to create it, but it doesn't try too hard to cover anything but the most common cases. If these aren't available on your system, then `umu-run` won't be built, but the script will still build Proton as usual.

You can try making a static umu-launcher build by itself by running `./setup.sh umu-only`.

A caveat: As of writing this, PyOxidizer's bundled Python version is 3.10.8. This means that umu-launcher's `--config` flag will not work, as it requires Python 3.11. Solutions for this should be looked into before Python 3.10 goes out of support.

Run `./setup.sh help` to see an overview of the options.

# Credit
Of course, none of this would be possible without the teams behind Proton and Wine, but I'd like to give special credit to:
- [loathingKernel](https://github.com/loathingKernel) for help with all things related to Proton, umu-launcher, and build scripts
- [MarshNello](https://github.com/NelloKudo/osu-winello) for making it easy to use this package for playing osu! with just a couple commands
- The team behind [Open-Wine-Components](https://github.com/Open-Wine-Components/) for making using Proton outside of Steam as easy as this
