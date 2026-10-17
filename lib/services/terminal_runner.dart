import 'dart:io';

import 'host_env.dart';

/// A terminal emulator candidate and how to launch it.
///
/// [execArgs] are always passed (how to pass the command to the terminal);
/// [waitArgs] are passed only when the caller wants to block until the
/// command finishes.
class Term {
  final String command;
  final List<String> execArgs;
  final List<String> waitArgs;
  const Term(this.command,
      {required this.execArgs, this.waitArgs = const <String>[]});
}

const _defaultTerminals = <Term>[
  Term('gnome-terminal', execArgs: ['--'], waitArgs: ['--wait']),
  Term('ptyxis', execArgs: ['--'], waitArgs: ['--wait']),
  Term('konsole', execArgs: ['-e']),
  Term('tilix', execArgs: ['-e']),
  Term('xfce4-terminal', execArgs: ['-x']),
  Term('alacritty', execArgs: <String>[]),
  Term('kitty', execArgs: <String>[]),
  Term('xterm', execArgs: ['-e']),
];

/// Runs a shell command inside a terminal emulator so interactive prompts
/// (passphrases, 2FA) have a real tty. Shared by login and key operations.
///
/// The [which] lookup and the terminal [candidates] are injectable so the
/// argv construction and the no-terminal path can be tested hermetically;
/// the defaults probe the real host.
///
/// TEST CONTRACT (see `test/terminal_runner_test.dart`):
///   * [buildLaunchArgs] is a pure function and its exact output is asserted
///     (wait-arg prefix, exec-args, `sh -c <command>` tail, and the `setsid`
///     wrap). Do not change its argument ordering or the `sh -c` shape
///     without updating those tests.
///   * [findTerminal] returns the FIRST candidate for which [which] is
///     non-null, and `null` when none are found; [start]/[runToEnd] then
///     throw [NoTerminalException] when the result is `null`.
/// The actual terminal spawn (Process.start of a real emulator) is NOT
/// tested — it needs a display.
class TerminalRunner {
  final Future<String?> Function(String cmd) which;
  final List<Term> candidates;

  TerminalRunner({
    Future<String?> Function(String cmd)? which,
    List<Term>? candidates,
  })  : which = which ?? _defaultWhich,
        candidates = candidates ?? _defaultTerminals;

  static final TerminalRunner _instance = TerminalRunner();

  /// Static entry point (used by the app) backed by a default instance.
  static Future<int> runToCompletion(String command, {bool wait = true}) =>
      _instance.runToEnd(command, wait: wait);

  /// Pure argv construction: the executable to spawn and its argument list
  /// for [term] running [command], honouring [wait] and whether to wrap the
  /// whole invocation in `setsid`.
  ///
  /// Returns `(executable, args)`:
  ///   * without setsid -> `(term.command, [...waitArgs?, ...execArgs, 'sh',
  ///     '-c', command])`
  ///   * with setsid -> `('setsid', [term.command, ...waitArgs?, ...execArgs,
  ///     'sh', '-c', command])`
  ///
  /// TEST CONTRACT (see `test/terminal_runner_test.dart`): the tests pin
  /// these exact argv lists. Keep the `waitArgs`-before-`execArgs`-before-
  /// `sh -c <command>` ordering and the `setsid` wrapping stable; changing
  /// either requires updating the tests.
  static (String, List<String>) buildLaunchArgs(
    Term term,
    String command, {
    required bool wait,
    required bool useSetsid,
  }) {
    final waitArgs = wait ? term.waitArgs : const <String>[];
    final launchArgs = <String>[
      ...waitArgs,
      ...term.execArgs,
      'sh',
      '-c',
      command,
    ];
    if (useSetsid) {
      return ('setsid', [term.command, ...launchArgs]);
    }
    return (term.command, launchArgs);
  }

  /// Returns the first candidate terminal whose binary is found, or `null`.
  Future<Term?> findTerminal() async {
    for (final c in candidates) {
      final p = await which(c.command);
      if (p != null) return c;
    }
    return null;
  }

  Future<Process> start(String command, {bool wait = false}) async {
    final term = await findTerminal();
    if (term == null) throw NoTerminalException();

    final useSetsid = await which('setsid') != null;
    final (exe, args) =
        buildLaunchArgs(term, command, wait: wait, useSetsid: useSetsid);
    final env = HostEnv.sanitized;

    return Process.start(exe, args,
        mode: ProcessStartMode.normal,
        environment: env,
        includeParentEnvironment: false);
  }

  Future<int> runToEnd(String command, {bool wait = true}) async {
    final proc = await start(command, wait: wait);
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();
    return proc.exitCode;
  }

  static Future<String?> _defaultWhich(String cmd) async {
    // `which` itself is a host binary; run it with a sanitized environment.
    final r = await Process.run(
      'which',
      [cmd],
      environment: HostEnv.sanitized,
      includeParentEnvironment: false,
    );
    if (r.exitCode != 0) return null;
    final out = (r.stdout as String).trim();
    return out.isEmpty ? null : out;
  }
}

class NoTerminalException implements Exception {
  @override
  String toString() =>
      'No terminal emulator found to run the interactive command.';
}
