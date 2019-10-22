// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:dwds/src/debugging/profiler.dart';
import 'package:dwds/src/debugging/sources.dart';
import 'package:dwds/src/debugging/webkit_debugger.dart';
import 'package:dwds/asset_handler.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_proxy/shelf_proxy.dart';
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

import 'live_suite_controller.dart';
import 'runner_suite.dart';

class TestAssetHandler implements AssetHandler {
  final Uri _assetPrefix;

  Handler _handler;

  TestAssetHandler(this._assetPrefix);

  @override
  Handler get handler =>
      _handler ??= proxyHandler(this._assetPrefix.toString());

  @override
  Future<Response> getRelativeAsset(String path) async => handler(
      Request('GET', Uri.parse('${this._assetPrefix.toString()}/$path'), url: Uri.parse(path.substring(1))));
}

Future<WebkitDebugger> getDebugConnection(String debuggerUrl) async {
  final response = await http.get(debuggerUrl.toString() + '/json');
  final url = jsonDecode(response.body)[0]['webSocketDebuggerUrl'] as String;

  final wipConnection = await WipConnection.connect(url);
  return WebkitDebugger(WipDebugger(wipConnection));
}

Future<WebkitDebugger> startCoverage(LiveSuiteController controller) async {
  final RunnerSuite suite = controller.liveSuite.suite;
  if (suite.platform.runtime.isBrowser &&
        suite.environment.supportsDebugging &&
        suite.environment.remoteDebuggerUrl != null) {
    final debugger = await getDebugConnection(suite.environment.remoteDebuggerUrl.toString());
    final profiler = Profiler(debugger);
    await profiler.startPreciseCoverage();
    final first =  debugger.onScriptParsed.first;
    await debugger.enable();
    await first;
    print('script parsed dang');
    return debugger;
  }
  return null;
}

/// Collects coverage and outputs to the [coverage] path.
Future<void> gatherCoverage(
    String coverage, LiveSuiteController controller, {WebkitDebugger debugger}) async {
  final RunnerSuite suite = controller.liveSuite.suite;

  if (debugger != null) {
    // set up debugger connection
    final sources = Sources(TestAssetHandler(suite.config.baseUrl), debugger, (_, __) {}, '');

    debugger.onScriptParsed.listen(sources.scriptParsed);

    final profiler = Profiler(debugger);

    final cov = (await profiler.takePreciseCoverage()).result;

    final script1 = Uri.parse(cov['result'][0]['url'] as String);
    final table = sources.tokenPosTableFor(script1.path);
    print(table);
  } else if (suite.platform.runtime.isDartVM) {
    final String isolateId =
        Uri.parse(suite.environment.observatoryUrl.fragment)
            .queryParameters['isolateId'];

    final cov = await collect(
        suite.environment.observatoryUrl, false, false, false, Set(),
        isolateIds: {isolateId});

    final outfile = File(p.join('$coverage', '${suite.path}.vm.json'))
      ..createSync(recursive: true);
    final IOSink out = outfile.openWrite();
    out.write(json.encode(cov));
    await out.flush();
    await out.close();
  }
}
