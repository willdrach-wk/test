// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'live_suite_controller.dart';
import 'package:dwds/src/debugging/sources.dart';
import 'package:dwds/src/debugging/webkit_debugger.dart';

Future<WebkitDebugger> startCoverage(LiveSuiteController controller) => throw UnsupportedError('Coverage is only supported through the test runner');

Future<void> gatherCoverage(String coverage, LiveSuiteController controller, {WebkitDebugger debugger, Sources sources}) =>
    throw UnsupportedError(
        'Coverage is only supported through the test runner.');
