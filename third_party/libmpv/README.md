# libmpv

The clip player (media_kit) plays through libmpv. On Windows `media_kit_libs_windows_video` downloads
`libmpv-2.dll` at build time; windows/CMakeLists.txt puts `LICENSE.txt` from this folder beside it as
`libmpv-LICENSE.txt`, so the installer and the .zip carry it.

`LICENSE.txt` says which build it is (mpv's `-Dgpl=false` and FFmpeg's `--disable-gpl --enable-version3`,
as the DLL's own configuration strings show), where its source is, and holds the LGPL version 3, the
GPL version 3 and mpv's Copyright file. Change it when the media_kit package brings a different libmpv.

On Linux no package carries a libmpv: the launcher (GPL-2.0-only) uses the one the system's package
manager installs (the .deb depends on `libmpv2 | libmpv1`, the Arch package on `mpv`), and the clip
player's plugin reaches it through `libanyps5_mpv.so` (linux/mpv_shim). The 0.1.21 nightlies of 9 and 10
November 2026 carried Ubuntu 22.04's libmpv1 in the bundle, with the 129 libraries it links (FFmpeg
built with `--enable-gpl`, and libcdio and libcdio-paranoia under the GPL version 3 or later among
them), which a GPL-2.0-only program cannot ship with. No stable release did.
