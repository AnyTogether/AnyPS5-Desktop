import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/package_install.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Which copies a package manager installed, so that the launcher's own update stays out of its
/// way: Scoop's app folders on Windows, pacman's database on Arch Linux.
void main() {
  group('Scoop', () {
    const profile = {'USERPROFILE': r'C:\Users\Slick', 'ProgramData': r'C:\ProgramData'};

    test('the default root, through the current junction or the version folder', () {
      for (final exe in [
        r'C:\Users\Slick\scoop\apps\anyps5-desktop\current\anyps5_desktop.exe',
        r'C:\Users\Slick\scoop\apps\anyps5-desktop\0.1.20\anyps5_desktop.exe',
        r'c:/users/slick/SCOOP/apps/anyps5-desktop/current/anyps5_desktop.exe',
      ]) {
        expect(PackageInstall.isScoop(exe, profile), isTrue, reason: exe);
      }
    });

    test('a global install, and a root SCOOP or SCOOP_GLOBAL names', () {
      expect(
        PackageInstall.isScoop(r'C:\ProgramData\scoop\apps\anyps5-desktop\current\anyps5_desktop.exe', profile),
        isTrue,
      );
      const custom = r'D:\Tools\apps\anyps5-desktop\current\anyps5_desktop.exe';
      expect(PackageInstall.isScoop(custom, profile), isFalse, reason: 'no root names D:\\Tools');
      expect(PackageInstall.isScoop(custom, {...profile, 'SCOOP': r'D:\Tools\'}), isTrue);
      expect(PackageInstall.isScoop(custom, {...profile, 'scoop_global': r'D:\Tools'}), isTrue, reason: 'any case');
      expect(PackageInstall.isScoop(r'D:\Toolsmith\apps\x\anyps5_desktop.exe', {'SCOOP': r'D:\Tools'}), isFalse);
    });

    test('the junction followed: a shortcut elsewhere that leads into Scoop', () {
      const link = r'E:\Launchers\AnyPS5\anyps5_desktop.exe';
      expect(PackageInstall.isScoop(link, profile), isFalse);
      expect(
        PackageInstall.isScoop(
          link,
          profile,
          resolve: (_) => r'\\?\C:\Users\Slick\scoop\apps\anyps5-desktop\0.1.20\anyps5_desktop.exe',
        ),
        isTrue,
      );
    });

    test('the installer, the zip unpacked by hand and winget are not Scoop', () {
      for (final exe in [
        r'C:\Users\Slick\AppData\Local\Programs\AnyPS5 Desktop\anyps5_desktop.exe',
        r'C:\Users\Slick\Downloads\AnyPS5-Desktop-windows-x64\anyps5_desktop.exe',
        r'C:\Program Files\AnyPS5 Desktop\anyps5_desktop.exe',
        r'C:\Users\Slick\scoop-notes\anyps5_desktop.exe',
      ]) {
        expect(PackageInstall.isScoop(exe, profile), isFalse, reason: exe);
      }
    });

    test('the command', () {
      expect(PackageManager.scoop.command, 'scoop update anyps5-desktop');
      expect(PackageManager.pacman.command, isNull, reason: 'pacman, an AUR helper or makepkg: the user knows');
    });
  });

  group('pacman', () {
    late Directory database;
    const exe = '/opt/anyps5-desktop/anyps5_desktop';

    setUp(() => database = temporaryFolder('pacman'));
    tearDown(() => database.deleteSync(recursive: true));

    void package(String folder, List<String> files) {
      final entry = Directory(p.join(database.path, folder))..createSync();
      File(p.join(entry.path, 'desc')).writeAsStringSync('%NAME%\n${folder.split('-0').first}\n');
      File(p.join(entry.path, 'files'))
          .writeAsStringSync(['%FILES%', ...files, '', '%BACKUP%', 'etc/x\tabc', ''].join('\n'));
    }

    test('anyps5-desktop-bin owns the launcher', () {
      package('glibc-2.40-1', ['usr/', 'usr/lib/libc.so.6']);
      package('anyps5-desktop-bin-0.1.20-1', [
        'opt/',
        'opt/anyps5-desktop/',
        'opt/anyps5-desktop/anyps5_desktop',
        'usr/bin/anyps5-desktop',
      ]);
      expect(PackageInstall.isPacman(exe, database: database.path), isTrue);
      expect(
        PackageInstall.detect(HostSystem.linux, executable: exe, environment: const {}, database: database.path),
        PackageManager.pacman,
      );
    });

    test('a copy the package does not list is not its own (the archive, an AppImage beside it)', () {
      package('anyps5-desktop-bin-0.1.20-1', ['opt/anyps5-desktop/anyps5_desktop']);
      expect(PackageInstall.isPacman('/home/slick/AnyPS5-Desktop/anyps5_desktop', database: database.path), isFalse);
      expect(
        PackageInstall.detect(
          HostSystem.linux,
          executable: exe,
          environment: const {'APPIMAGE': '/home/slick/AnyPS5-Desktop.AppImage'},
          database: database.path,
        ),
        isNull,
        reason: 'an AppImage updates itself',
      );
    });

    test('another package listing the same path does not count, nor a system without pacman', () {
      package('some-other-tool-1.0-1', ['opt/anyps5-desktop/anyps5_desktop']);
      expect(PackageInstall.isPacman(exe, database: database.path), isFalse);
      expect(PackageInstall.isPacman(exe, database: p.join(database.path, 'missing')), isFalse, reason: 'the .deb');
    });

    test('the path followed to the file the package lists', () {
      package('anyps5-desktop-bin-0.1.20-1', ['opt/anyps5-desktop/anyps5_desktop']);
      expect(PackageInstall.isPacman('/usr/bin/anyps5-desktop', database: database.path, resolve: (_) => exe), isTrue);
    });

    test('a package whose file list cannot be read: its folder says it', () {
      Directory(p.join(database.path, 'anyps5-desktop-bin-0.1.20-1')).createSync();
      expect(PackageInstall.isPacman(exe, database: database.path), isTrue);
      expect(PackageInstall.isPacman('/home/slick/anyps5_desktop', database: database.path), isFalse);
    });
  });

  test('Windows asks only Scoop, Linux only pacman', () {
    expect(
      PackageInstall.detect(
        HostSystem.windows,
        executable: r'C:\Users\Slick\scoop\apps\anyps5-desktop\current\anyps5_desktop.exe',
        environment: const {},
      ),
      PackageManager.scoop,
    );
    expect(
      PackageInstall.detect(
        HostSystem.windows,
        executable: r'C:\Users\Slick\AppData\Local\Programs\AnyPS5 Desktop\anyps5_desktop.exe',
        environment: const {},
      ),
      isNull,
    );
    expect(
      PackageInstall.detect(
        HostSystem.linux,
        executable: '/home/slick/scoop/apps/anyps5-desktop/anyps5_desktop',
        environment: const {},
        database: '/nonexistent/pacman',
      ),
      isNull,
    );
  });
}
