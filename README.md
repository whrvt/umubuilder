# umubuilder
A script for easily creating Proton packages, with custom patches and out-of-the-box support for umu-launcher.

With no added options, `./setup.sh` will compile and bundle [Proton](https://github.com/GloriousEggroll/proton-ge-custom) + [protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes) + [umu-run](https://github.com/Open-Wine-Components/umu-launcher) together into a redistributable `$pkgname.tar.xz`, along with installing to `$HOME/.steam/root/compatibilitytools.d/$buildname` (`umu-run` is excluded from the Steam installation). 

Run `./setup.sh help` to see an overview of the options, or take a look inside the script; it's not that big.

# Credit
Of course, none of this would be possible without the teams behind Proton and Wine, but I'd like to give special credit to:
- [loathingKernel](https://github.com/loathingKernel) for help with all things related to Proton, umu-launcher, and build scripts
- [MarshNello](https://github.com/NelloKudo/osu-winello) for making it easy to use this package for playing osu! with just a couple commands
- The team behind [Open-Wine-Components](https://github.com/Open-Wine-Components/) for making using Proton outside of Steam as easy as this
