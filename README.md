# umubuilder
A script for easily creating Proton packages, with custom patches and out-of-the-box support for GloriousEggroll's umu-launcher.

With no added options, `./setup.sh` will compile and bundle [Proton](https://github.com/CachyOS/proton-cachyos) + [protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes) + [umu-run](https://github.com/Open-Wine-Components/umu-launcher) together into a redistributable `$pkgname.tar.xz`, along with installing to `$HOME/.steam/root/compatibilitytools.d/$buildname` (`umu-run` is excluded from the Steam installation). 

Run `./setup.sh help` to see an overview of the options, or take a look inside the script; it's not that big.

# Credit
Of course, none of this would be possible without the teams behind Proton and Wine, but I'd like to give special credit to:
- [loathingKernel](https://github.com/loathingKernel) for putting together the [version](https://github.com/CachyOS/proton-cachyos) of Proton that this build script uses
- The team behind [Open-Wine-Components](https://github.com/Open-Wine-Components/) for making using Proton outside of Steam as easy as this
