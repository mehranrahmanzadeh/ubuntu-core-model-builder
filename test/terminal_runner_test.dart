import 'package:flutter_test/flutter_test.dart';

import 'package:ubuntu_core_model_builder/services/terminal_runner.dart';

void main() {
  group('TerminalRunner.buildLaunchArgs (pure argv construction)', () {
    const gnome = Term('gnome-terminal', execArgs: ['--'], waitArgs: ['--wait']);
    const konsole = Term('konsole', execArgs: ['-e']);
    const kitty = Term('kitty', execArgs: <String>[]);

    test('gnome-terminal with wait prepends the wait args', () {
      final (exe, args) = TerminalRunner.buildLaunchArgs(
          gnome, 'echo hi',
          wait: true, useSetsid: false);
      expect(exe, 'gnome-terminal');
      expect(args, ['--wait', '--', 'sh', '-c', 'echo hi']);
    });

    test('gnome-terminal without wait omits the wait args', () {
      final (exe, args) = TerminalRunner.buildLaunchArgs(
          gnome, 'echo hi',
          wait: false, useSetsid: false);
      expect(exe, 'gnome-terminal');
      expect(args, ['--', 'sh', '-c', 'echo hi']);
    });

    test('a terminal with no wait args is unaffected by wait', () {
      final withWait =
          TerminalRunner.buildLaunchArgs(konsole, 'ls', wait: true, useSetsid: false);
      final noWait =
          TerminalRunner.buildLaunchArgs(konsole, 'ls', wait: false, useSetsid: false);
      expect(withWait.$2, ['-e', 'sh', '-c', 'ls']);
      expect(withWait.$2, noWait.$2); // identical
      expect(withWait.$1, 'konsole');
    });

    test('a terminal with empty execArgs passes only sh -c', () {
      final (exe, args) = TerminalRunner.buildLaunchArgs(
          kitty, 'pwd',
          wait: false, useSetsid: false);
      expect(exe, 'kitty');
      expect(args, ['sh', '-c', 'pwd']);
    });

    test('setsid wraps the whole invocation', () {
      final (exe, args) = TerminalRunner.buildLaunchArgs(
          gnome, 'echo hi',
          wait: true, useSetsid: true);
      expect(exe, 'setsid');
      // setsid <terminal> <waitArgs> <execArgs> sh -c <cmd>
      expect(args, ['gnome-terminal', '--wait', '--', 'sh', '-c', 'echo hi']);
    });

    test('the command is always the final argv element', () {
      final (exe, args) = TerminalRunner.buildLaunchArgs(
          konsole, 'complex "quoted" cmd',
          wait: true, useSetsid: false);
      expect(exe, 'konsole');
      expect(args.last, 'complex "quoted" cmd');
      expect(args, ['-e', 'sh', '-c', 'complex "quoted" cmd']);
    });
  });

  group('terminal discovery (hermetic, injected `which`)', () {
    test('findTerminal returns null when no candidate is installed', () async {
      final runner = TerminalRunner(which: (c) async => null);
      expect(await runner.findTerminal(), isNull);
    });

    test('start throws NoTerminalException when no candidate is installed',
        () async {
      final runner = TerminalRunner(which: (c) async => null);
      await expectLater(
        runner.start('echo hi'),
        throwsA(isA<NoTerminalException>()),
      );
    });

    test('findTerminal returns the first installed candidate', () async {
      final runner = TerminalRunner(
        which: (c) async => (c == 'konsole' ? '/usr/bin/konsole' : null),
        candidates: [
          const Term('gnome-terminal', execArgs: ['--']),
          const Term('konsole', execArgs: ['-e']),
          const Term('xterm', execArgs: ['-e']),
        ],
      );
      final term = await runner.findTerminal();
      expect(term, isNotNull);
      expect(term!.command, 'konsole');
      expect(term.execArgs, ['-e']);
    });

    test('findTerminal honours the candidate order (not alphabetical)',
        () async {
      // Both are "installed"; the first in the list must win.
      final runner = TerminalRunner(
        which: (c) async => '/bin/$c',
        candidates: [
          const Term('xterm', execArgs: ['-e']),
          const Term('konsole', execArgs: ['-e']),
        ],
      );
      expect((await runner.findTerminal())!.command, 'xterm');
    });
  });

  group('NoTerminalException', () {
    test('toString is the descriptive message', () {
      expect(
          NoTerminalException().toString(),
          contains('No terminal emulator found'));
    });
  });
}
