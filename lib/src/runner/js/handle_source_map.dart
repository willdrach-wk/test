// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "dart:async";

import "../../util/serialize.dart";
import "../../util/stack_trace_mapper.dart";
import "../plugin/remote_platform_helpers.dart";
import "lazy_mapping.dart";

/// Connects to the test runner and sets up source mapping according to the
/// message it sends.
Future handleSourceMap() async {
  var command = await suiteChannel("test.js.sourceMap").stream.first;
  if (command == null) return;

  if (command["type"] == "ddc") {
    setStackTraceMapper(new StackTraceMapper.parsed(
        new LazyMapping(command["mapDirUrl"]),
        packageResolver:
            deserializePackageResolver(command["packageResolver"])));
  } else {
    assert(command["type"] == "mapper");
    setStackTraceMapper(StackTraceMapper.deserialize(command["mapper"]));
  }
}
