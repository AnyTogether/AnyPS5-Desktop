import 'package:anyps5_desktop/core/libmpv.dart';
import 'package:test/test.dart';

/// The system's libmpv on Linux: which one media_kit opens, and how to install it when none does.
void main() {
  group('finding the system libmpv', () {
    test('the names media_kit opens, in its order', () {
      final tried = <String>[];
      expect(
        SystemLibmpv.find(
          opens: (name) {
            tried.add(name);
            return false;
          },
          environment: const {},
        ),
        isNull,
      );
      expect(tried, ['libmpv.so', 'libmpv.so.2', 'libmpv.so.1']);
    });

    test('Ubuntu 22.04 has only libmpv.so.1, newer systems libmpv.so.2', () {
      expect(SystemLibmpv.find(opens: (name) => name == 'libmpv.so.1', environment: const {}), 'libmpv.so.1');
      expect(SystemLibmpv.find(opens: (name) => name.startsWith('libmpv.so'), environment: const {}), 'libmpv.so');
      expect(SystemLibmpv.find(opens: (name) => name == 'libmpv.so.2', environment: const {}), 'libmpv.so.2');
    });

    test('LIBMPV_LIBRARY_PATH comes first, as media_kit reads it', () {
      expect(
        SystemLibmpv.find(opens: (_) => true, environment: const {'LIBMPV_LIBRARY_PATH': '/opt/mpv/libmpv.so.2'}),
        '/opt/mpv/libmpv.so.2',
      );
      expect(SystemLibmpv.find(opens: (_) => false, environment: const {'LIBMPV_LIBRARY_PATH': '/nope'}), isNull);
    });

    test('a library that cannot be opened is missing (the real dlopen)', () {
      expect(
        SystemLibmpv.find(opens: null, environment: const {'LIBMPV_LIBRARY_PATH': '/no/such/folder/libmpv.so.9'}),
        anyOf(isNull, isNot('/no/such/folder/libmpv.so.9')),
      );
    });
  });

  group('the command that installs it', () {
    test('Ubuntu 24.04 and Debian 12 and 13: libmpv2', () {
      const noble =
          'NAME="Ubuntu"\nVERSION_ID="24.04"\nID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=noble\nUBUNTU_CODENAME=noble\n';
      const bookworm = 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nID=debian\nVERSION_CODENAME=bookworm\n';
      const trixie = 'ID=debian\nVERSION_CODENAME=trixie\n';
      for (final release in [noble, bookworm, trixie]) {
        expect(SystemLibmpv.installCommands(release), ['sudo apt install libmpv2']);
      }
    });

    test('Ubuntu 22.04 and what is built on it, and Debian 11: libmpv1', () {
      const jammy =
          'NAME="Ubuntu"\nVERSION_ID="22.04"\nID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=jammy\nUBUNTU_CODENAME=jammy\n';
      const mint =
          'NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_CODENAME=virginia\nUBUNTU_CODENAME=jammy\n';
      const pop = "NAME='Pop!_OS'\nID=pop\nID_LIKE=\"ubuntu debian\"\nVERSION_CODENAME=jammy\nUBUNTU_CODENAME=jammy\n";
      const bullseye = 'ID=debian\nVERSION_CODENAME=bullseye\n';
      for (final release in [jammy, mint, pop, bullseye]) {
        expect(SystemLibmpv.installCommands(release), ['sudo apt install libmpv1'], reason: release);
      }
    });

    test('Fedora, Arch and what is built on it, openSUSE', () {
      expect(SystemLibmpv.installCommands('NAME="Fedora Linux"\nID=fedora\nVERSION_ID=43\n'), [
        'sudo dnf install mpv-libs',
      ]);
      expect(SystemLibmpv.installCommands('NAME="Arch Linux"\nID=arch\n'), ['sudo pacman -S mpv']);
      expect(SystemLibmpv.installCommands('NAME="Manjaro Linux"\nID=manjaro\nID_LIKE=arch\n'), ['sudo pacman -S mpv']);
      expect(
        SystemLibmpv.installCommands('NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n'),
        ['sudo zypper install libmpv2'],
      );
    });

    test('a distribution it does not know, or no os-release: every family', () {
      const all = [
        'sudo apt install libmpv2',
        'sudo apt install libmpv1',
        'sudo dnf install mpv-libs',
        'sudo pacman -S mpv',
        'sudo zypper install libmpv2',
      ];
      expect(SystemLibmpv.installCommands('NAME="Void"\nID=void\n'), all);
      expect(SystemLibmpv.installCommands(''), all);
    });
  });
}
