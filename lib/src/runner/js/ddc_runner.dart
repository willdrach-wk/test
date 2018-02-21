// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';

import '../../util/io.dart';

/// A class that runs `dartdevc`.
///
/// This ensures that later invocations of DDC can re-use the work done by
/// earlier invocations.
///
/// All compiled files are written to [dir]. Note that some files in [dir] may
/// rely on others, so the whole directory should be served to browsers.
class DdcRunner {
  /// The directory in which compiled output is stored.
  String get dir => _dir ??= createTempDir();
  String _dir;

  /// A lock to ensure that only one `dartdevc` instance runs at once.
  final _lock = new Pool(1);

  /// The currently-active DDC processes.
  Process _process;

  /// Whether [close] has been called.
  bool get _closed => _closeMemo.hasRun;

  /// The memoizer for running [close] exactly once.
  final _closeMemo = new AsyncMemoizer();

  /// Extra arguments to pass to DDC.
  final List<String> _extraArgs;

  /// The paths to summaries that have already been compiled.
  final _summaries = new Set<String>();

  DdcRunner([Iterable<String> extraArgs])
      : _extraArgs = extraArgs?.toList() ?? const [];

  /// Compiles the Dart file at [url], which may be a [Uri] or a [String], to a
  /// file in [dir].
  ///
  /// If [url] is a `file:` URL (including relative URLs), it's compiled to the
  /// same relative path in [dir]. If it's a `package:` URL, it's compiled to
  /// `packages/$path`. In either case, the `.dart` extension is replaced by
  /// `.ddc.js`.
  ///
  /// If [url] has already been compiled, this is a no-op.
  ///
  /// The returned [Future] will complete once the `dartdevc` process completes
  /// *and* all its output has been printed to the command line.
  Future compile(url) {
    return _lock.withResource(() async {
      var executable = p.join(sdkDir, 'bin', 'dartdevc');
      if (Platform.isWindows) executable += '.bat';

      var urlString = url.toString();
      var basePath = p.join(
          dir,
          p.withoutExtension(urlString.startsWith("package:")
                  ? p.join("packages",
                      p.fromUri(urlString.substring("package:".length)))
                  : p.relative(p.fromUri(url))) +
              '.ddc');
      var summaryPath = basePath + '.sum';
      if (_summaries.contains(summaryPath)) return;

      var jsPath = basePath + '.js';
      new Directory(p.dirname(jsPath)).createSync(recursive: true);
      var args = [
        url.toString(),
        '--source-map',
        '--source-map-comment',
        '--inline-source-map',
        "--module-root=$dir",
        "--out=$jsPath"
      ]..addAll(_extraArgs);

      for (var summary in _summaries) {
        args..add('--summary')..add(summary);
      }

      var process = await Process.start(executable, args);
      if (_closed) {
        process.kill();
        return;
      }

      _process = process;

      /// Wait until the process is entirely done to print out any output.
      /// This can produce a little extra time for users to wait with no
      /// update, but it also avoids some really nasty-looking interleaved
      /// output. Write both stdout and stderr to the same buffer in case
      /// they're intended to be printed in order.
      var buffer = new StringBuffer();

      await Future.wait([
        UTF8.decoder.bind(process.stdout).listen(buffer.write).asFuture(),
        UTF8.decoder.bind(process.stderr).listen(buffer.write).asFuture()
      ]);

      var exitCode = await process.exitCode;
      _process = null;
      if (_closed) return;

      var output = buffer.toString();
      if (output.isNotEmpty) print(output);

      if (exitCode != 0) throw "DDC failed.";
      _summaries.add(summaryPath);
    });
  }

  /// Closes the compiler pool.
  ///
  /// This kills all currently-running compilers and ensures that no more will
  /// be started. It returns a [Future] that completes once all the compilers
  /// have been killed and all resources released.
  Future close() => _closeMemo.runOnce(() async {
        _process?.kill();
        await _process?.exitCode;
        //if (_dir != null) new Directory(_dir).deleteSync(recursive: true);
      });
}
