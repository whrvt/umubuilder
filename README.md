# umubuilder
A script for easily creating Proton packages, with custom patches and out-of-the-box support for a statically linked umu-launcher.

With no added options, `./setup.sh` will download, compile, and bundle [Proton](https://github.com/GloriousEggroll/proton-ge-custom) + [protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes) + [umu-run](https://github.com/Open-Wine-Components/umu-launcher) together into a redistributable `$pkgname.tar.xz` in a `build_tarballs` directory. It will also try to install these files to your `$HOME/.steam/root/compatibilitytools.d/`, with the `$buildname` as the compatibility tool's name.

You can try making a static umu-launcher build by itself by running `./setup.sh umu-only`. It can also be used by itself from the `umu-static-bundler` directory, which will be turned into a submodule eventually, as I have plans of extending it to build static bundles for other (GPL-compatible) python apps as well.

Run `./setup.sh help` to see an overview of the options.

# Credit
Of course, none of this would be possible without the teams behind Proton and Wine, but I'd like to give special credit to:
- [loathingKernel](https://github.com/loathingKernel) for help with all things related to Proton, umu-launcher, and build scripts
- [MarshNello](https://github.com/NelloKudo/osu-winello) for making it easy to use this package for playing osu! with just a couple commands
- The team behind [Open-Wine-Components](https://github.com/Open-Wine-Components/) for making using Proton outside of Steam as easy as this
- The maintainers of [python-build-standalone](https://github.com/indygreg/python-build-standalone) for regularly releasing up-to-date static Python distributions
