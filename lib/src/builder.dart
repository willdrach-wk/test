// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:build_modules/build_modules.dart';

Builder bootstrapBuilder(_) => const _BootstrapBuilder();

/// A [Builder] that ensure that test's bootstrap files and all their
/// dependencies are compiled to JS with DDC.
class _BootstrapBuilder implements Builder {
  const _BootstrapBuilder();

  Future build(BuildStep buildStep) async {
    var moduleId = buildStep.inputId.changeExtension(moduleExtension);
    var module = new Module.fromJson(
        JSON.decode(await buildStep.readAsString(moduleId))
            as Map<String, dynamic>);
    await _ensureTransitiveModules(module, buildStep);
  }

  /// Ensures that all transitive js modules for [module] are available and built.
  Future _ensureTransitiveModules(Module module, AssetReader reader) async {
    // Collect all the modules this module depends on, plus this module.
    var transitiveDeps = await module.computeTransitiveDependencies(reader);
    var jsModules = transitiveDeps
        .map((module) => module.jsId('.ddc.js'))
        .toList()
          ..add(module.jsId('.ddc.js'));
    // Check that each module is readable, and warn otherwise.
    await Future.wait(jsModules.map((jsId) async {
      if (await reader.canRead(jsId)) return;
      log.warning(
          'Unable to read $jsId, check your console for compilation errors.');
    }));
  }

  Map<String, List<String>> get buildExtensions => const {
        '.dart': const ['._test']
      };
}
