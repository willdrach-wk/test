// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:collection/collection.dart';
import 'package:package_resolver/package_resolver.dart';

/// Converts [packageResolver] into a JSON-safe object that can be converted
/// back using [deserializePackageResolver].
Object serializePackageResolver(SyncPackageResolver packageResolver) => {
      'packageConfigMap': packageResolver.packageConfigMap == null
          ? null
          : mapMap(packageResolver.packageConfigMap,
              value: (_, value) => value.toString()),
      'packageRoot': packageResolver.packageRoot?.toString()
    };

/// Converts an object produced by [serializePackageResolver] back into a
/// [SyncPackageResolver].
SyncPackageResolver deserializePackageResolver(Object serialized) {
  var map = serialized as Map;
  var packageRoot = map['packageRoot'] as String;
  return packageRoot == null
      ? new SyncPackageResolver.config(mapMap(map['packageConfigMap'],
          value: (_, value) => Uri.parse(value)))
      : new SyncPackageResolver.root(Uri.parse(map['packageRoot']));
}
