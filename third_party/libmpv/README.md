# libmpv

The clip player (media_kit) plays through libmpv. On Windows `media_kit_libs_windows_video` downloads
`libmpv-2.dll` at build time; windows/CMakeLists.txt puts `LICENSE.txt` from this folder beside it as
`libmpv-LICENSE.txt`, so the installer and the .zip carry it.

`LICENSE.txt` says which build it is (mpv's `-Dgpl=false` and FFmpeg's `--disable-gpl --enable-version3`,
as the DLL's own configuration strings show), where its source is, and holds the LGPL version 3, the
GPL version 3 and mpv's Copyright file. Change it when the media_kit package brings a different libmpv.

On Linux the bundle copies the build machine's libmpv with its packages' copyright files to `lib/licenses/`
(packaging/linux/bundle-libmpv.sh).
