// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:async/async.dart';
import 'package:http_multi_server/http_multi_server.dart';
import 'package:package_resolver/package_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:shelf_packages_handler/shelf_packages_handler.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:yaml/yaml.dart';

import '../../backend/compiler.dart';
import '../../backend/runtime.dart';
import '../../backend/suite_platform.dart';
import '../../util/io.dart';
import '../../util/one_off_handler.dart';
import '../../util/path_handler.dart';
import '../../util/serialize.dart';
import '../../util/stack_trace_mapper.dart';
import '../../utils.dart';
import '../configuration.dart';
import '../configuration/suite.dart';
import '../js/dart2js_pool.dart';
import '../js/ddc_runner.dart';
import '../js/executable_settings.dart';
import '../load_exception.dart';
import '../plugin/customizable_platform.dart';
import '../plugin/platform.dart';
import '../runner_suite.dart';
import 'browser_manager.dart';
import 'default_settings.dart';
import 'polymer.dart';

class BrowserPlatform extends PlatformPlugin
    implements CustomizablePlatform<ExecutableSettings> {
  /// Starts the server.
  ///
  /// [root] is the root directory that the server should serve. It defaults to
  /// the working directory.
  static Future<BrowserPlatform> start({String root}) async {
    var server = new shelf_io.IOServer(await HttpMultiServer.loopback(0));
    return new BrowserPlatform._(
        server,
        Configuration.current,
        p.fromUri(await Isolate.resolvePackageUri(
            Uri.parse('package:test/src/runner/browser/static/favicon.ico'))),
        root: root);
  }

  /// The test runner configuration.
  final Configuration _config;

  /// The underlying server.
  final shelf.Server _server;

  /// A randomly-generated secret.
  ///
  /// This is used to ensure that other users on the same system can't snoop
  /// on data being served through this server.
  final _secret = Uri.encodeComponent(randomBase64(24));

  /// The URL for this server.
  Uri get url => _server.url.resolve(_secret + "/");

  /// A [OneOffHandler] for servicing WebSocket connections for
  /// [BrowserManager]s.
  ///
  /// This is one-off because each [BrowserManager] can only connect to a single
  /// WebSocket,
  final _webSocketHandler = new OneOffHandler();

  /// A [PathHandler] used to serve compiled JS.
  final _jsHandler = new PathHandler();

  /// The [Dart2jsPool] managing active instances of `dart2js`.
  final _dart2js = new Dart2jsPool();

  /// The [DdcRunner] managing instances of `dartdevc`.
  DdcRunner get _ddc {
    __ddc ??= new DdcRunner();
    return __ddc;
  }

  DdcRunner __ddc;

  /// The temporary directory in which compiled JS is emitted.
  final String _compiledDir;

  /// The root directory served statically by this server.
  final String _root;

  /// The pool of active `pub serve` compilations.
  ///
  /// Pub itself ensures that only one compilation runs at a time; we just use
  /// this pool to make sure that the output is nice and linear.
  final _pubServePool = new Pool(1);

  /// The HTTP client to use when caching JS files in `pub serve`.
  final HttpClient _http;

  /// Whether [close] has been called.
  bool get _closed => _closeMemo.hasRun;

  /// A map from browser identifiers to futures that will complete to the
  /// [BrowserManager]s for those browsers, or `null` if they failed to load.
  ///
  /// This should only be accessed through [_browserManagerFor].
  final _browserManagers = <Runtime, Future<BrowserManager>>{};

  /// Settings for invoking each browser.
  ///
  /// This starts out with the default settings, which may be overridden by user settings.
  final _browserSettings =
      new Map<Runtime, ExecutableSettings>.from(defaultSettings);

  /// A cascade of handlers for suites' precompiled paths.
  ///
  /// This is `null` if there are no precompiled suites yet.
  shelf.Cascade _precompiledCascade;

  /// The precompiled paths that have handlers in [_precompiledHandler].
  final _precompiledPaths = new Set<String>();

  /// A map from test suite paths to Futures that will complete once those
  /// suites are finished compiling.
  ///
  /// This is used to make sure that a given test suite is only compiled once
  /// per run, rather than once per browser per run.
  final _compileFutures = new Map<Pair<String, Compiler>, Future>();

  /// Mappers for Dartifying stack traces, indexed by test path and compiler.
  final _mappers = new Map<Pair<String, Compiler>, StackTraceMapper>();

  BrowserPlatform._(this._server, Configuration config, String faviconPath,
      {String root})
      : _config = config,
        _root = root == null ? p.current : root,
        _compiledDir = config.pubServeUrl == null ? createTempDir() : null,
        _http = config.pubServeUrl == null ? null : new HttpClient() {
    var cascade = new shelf.Cascade().add(_webSocketHandler.handler);

    if (_config.pubServeUrl == null) {
      cascade = cascade
          .add(packagesDirHandler())
          .add(_jsHandler.handler)
          .add(createStaticHandler(_root))
          .add(_createDdcHandler())
          .add(PathHandler.nestedIn(r'packages/$sdk')(
              createStaticHandler(p.join(sdkDir, 'lib'))))

          // Add this before the wrapper handler so that its HTML takes
          // precedence over the test runner's.
          .add((request) =>
              _precompiledCascade?.handler(request) ??
              new shelf.Response.notFound(null))
          .add(_wrapperHandler);
    }

    var pipeline = new shelf.Pipeline()
        .addMiddleware(PathHandler.nestedIn(_secret))
        .addHandler(cascade.handler);

    _server.mount(new shelf.Cascade()
        .add(createFileHandler(faviconPath))
        .add(pipeline)
        .handler);
  }

  /// Creates a handler that serves files from [_ddc.dir].
  ///
  /// This lazily initializes the static handler to avoid creating a temporary
  /// directory unnecessarily when DDC isn't in use.
  shelf.Handler _createDdcHandler() {
    shelf.Handler inner;
    return (request) {
      if (!request.url.path.endsWith(".ddc.js") &&
          !request.url.path.endsWith(".ddc.js.map")) {
        return new shelf.Response.notFound('Not found.');
      }

      inner ??= createStaticHandler(_ddc.dir);
      return inner(request);
    };
  }

  /// A handler that serves wrapper files used to bootstrap tests.
  Future<shelf.Response> _wrapperHandler(shelf.Request request) async {
    var path = p.fromUri(request.url);

    if (path.endsWith(".browser_test.dart")) {
      var testPath = p.basename(trimSuffix(path, ".browser_test.dart"));
      return new shelf.Response.ok('''
        import "package:stream_channel/stream_channel.dart";

        import "package:test/src/runner/plugin/remote_platform_helpers.dart";
        import "package:test/src/runner/browser/post_message_channel.dart";

        import "$testPath" as test;

        void main() {
          var channel = serializeSuite(() => test.main, hidePrints: false);
          postMessageChannel().pipe(channel);
        }
      ''', headers: {'Content-Type': 'application/dart'});
    }

    if (path.endsWith(".ddc.browser_test.js")) {
      var moduleName = trimSuffix(request.url.path, ".browser_test.js");

      var requires = [
        moduleName,
        "packages/test/src/bootstrap/browser.ddc",
        "dart_sdk"
      ];
      var moduleIdentifier = p.url
          .split(p.withoutExtension(moduleName))
          .join('__')
          .replaceAll('.', '\$46');

      return new shelf.Response.ok('''
        (function() {
          var oldOnError = requirejs.onError;
          requirejs.onError = function(e) {
            if (e.originalError && e.originalError.srcElement) {
              var xhr = new XMLHttpRequest();
              xhr.onreadystatechange = function() {
                if (this.readyState == 4 && this.status == 200) {
                  console.error(this.responseText);
                  window.parent.postMessage({
                    "href": window.location.href,
                    "data": [
                      0,
                      {"type": "loadException", "message": this.responseText}
                    ]
                  }, window.location.origin);
                }
              };
              xhr.open("GET", e.originalError.srcElement.src + ".errors", true);
              xhr.send();
            }

            // Also handle errors the normal way.
            if (oldOnError) oldOnError(e);
          };

          require.config({
            baseUrl: ${JSON.encode(url.toString())},
            waitSeconds: 0,
            paths: {"dart_sdk": "packages/\$sdk/dev_compiler/amd/dart_sdk"}
          });

          require(${JSON.encode(requires)}, function(app, bootstrap, dart_sdk) {
            dart_sdk._isolate_helper.startRootIsolate(() => {}, []);
            dart_sdk._debugger.registerDevtoolsFormatter();
            window.\$dartTestGetSourceMap = dart_sdk.dart.getSourceMap;
            window.postMessage({type: "DDC_STATE_CHANGE", state: "start"}, "*");

            bootstrap.src__bootstrap__browser.internalBootstrapBrowserTest(
                function() {
              return app.$moduleIdentifier.main;
            });
          });
        })();
      ''', headers: {'Content-Type': 'application/javascript'});
    }

    if (path.endsWith(".html")) {
      String testPath;
      String scriptTags;
      if (path.endsWith(".ddc.html")) {
        testPath = trimSuffix(path, ".ddc.html") + ".dart";
        var module = HTML_ESCAPE.convert(
            p.url.basename(trimSuffix(path, ".html")) + ".browser_test.js");
        var requireUrl = HTML_ESCAPE
            .convert("/$_secret/packages/\$sdk/dev_compiler/amd/require.js");
        scriptTags =
            '<script data-main="$module" src="$requireUrl" defer></script>';
      } else {
        testPath = trimSuffix(path, ".html") + '.dart';
        var scriptBase = HTML_ESCAPE
            .convert(p.url.basename(testPath) + ".browser_test.dart");
        // Link to the Dart wrapper on Dartium and the compiled JS version
        // elsewhere.
        var script = request.headers['user-agent'].contains('(Dart)')
            ? 'type="application/dart" src="$scriptBase"'
            : 'src="$scriptBase.js"';
        scriptTags = "<script $script></script>";
      }

      return new shelf.Response.ok('''
          <!DOCTYPE html>
          <html>
          <head>
            <title>${HTML_ESCAPE.convert(testPath)} Test</title>
            $scriptTags
          </head>
          </html>
        ''', headers: {'Content-Type': 'text/html'});
    }

    return new shelf.Response.notFound('Not found.');
  }

  ExecutableSettings parsePlatformSettings(YamlMap settings) =>
      new ExecutableSettings.parse(settings);

  ExecutableSettings mergePlatformSettings(
          ExecutableSettings settings1, ExecutableSettings settings2) =>
      settings1.merge(settings2);

  void customizePlatform(Runtime runtime, ExecutableSettings settings) {
    var oldSettings =
        _browserSettings[runtime] ?? _browserSettings[runtime.root];
    if (oldSettings != null) settings = oldSettings.merge(settings);
    _browserSettings[runtime] = settings;
  }

  /// Loads the test suite at [path] on the platform [platform].
  ///
  /// This will start a browser to load the suite if one isn't already running.
  /// Throws an [ArgumentError] if `platform.platform` isn't a browser.
  Future<RunnerSuite> load(String path, SuitePlatform platform,
      SuiteConfiguration suiteConfig, Object message) async {
    var browser = platform.runtime;
    assert(suiteConfig.runtimes.contains(browser.identifier));

    if (!browser.isBrowser) {
      throw new ArgumentError("$browser is not a browser.");
    }

    var htmlPath = p.withoutExtension(path) + '.html';
    if (new File(htmlPath).existsSync() &&
        !new File(htmlPath)
            .readAsStringSync()
            .contains('packages/test/dart.js')) {
      throw new LoadException(
          path,
          '"${htmlPath}" must contain <script src="packages/test/dart.js">'
          '</script>.');
    }

    var suiteUrl;
    if (_config.pubServeUrl != null) {
      var suitePrefix = p
          .toUri(
              p.withoutExtension(p.relative(path, from: p.join(_root, 'test'))))
          .path;

      var dartUrl;
      // Polymer generates a bootstrap entrypoint that wraps the entrypoint we
      // see on disk, and modifies the HTML file to point to the bootstrap
      // instead. To make sure we get the right source maps and wait for the
      // right file to compile, we have some Polymer-specific logic here to load
      // the boostrap instead of the unwrapped file.
      if (isPolymerEntrypoint(path)) {
        dartUrl = _config.pubServeUrl.resolve(
            "$suitePrefix.html.polymer.bootstrap.dart.browser_test.dart");
      } else {
        dartUrl =
            _config.pubServeUrl.resolve('$suitePrefix.dart.browser_test.dart');
      }

      await _pubServeSuite(path, dartUrl, browser, suiteConfig);
      suiteUrl = _config.pubServeUrl.resolveUri(p.toUri('$suitePrefix.html'));
    } else {
      var extension = ".html";
      if (browser.isJS) {
        if (_precompiled(suiteConfig, path)) {
          if (_precompiledPaths.add(suiteConfig.precompiledPath)) {
            if (!suiteConfig.jsTrace) {
              var jsPath = p.join(suiteConfig.precompiledPath,
                  p.relative(path + ".browser_test.dart.js", from: _root));

              var sourceMapPath = '${jsPath}.map';
              if (new File(sourceMapPath).existsSync()) {
                _mappers[new Pair(path, platform.compiler)] =
                    new StackTraceMapper(
                        new File(sourceMapPath).readAsStringSync(),
                        mapUrl: p.toUri(sourceMapPath),
                        packageResolver: await PackageResolver.current.asSync,
                        sdkRoot: p.toUri(sdkDir));
              }
            }
            _precompiledCascade ??= new shelf.Cascade();
            _precompiledCascade = _precompiledCascade
                .add(createStaticHandler(suiteConfig.precompiledPath));
          }
        } else {
          await _compileFutures.putIfAbsent(new Pair(path, platform.compiler),
              () async {
            if (platform.compiler == Compiler.dart2js) {
              await _compileSuiteWithDart2js(path, suiteConfig);
            } else {
              await _ddc.compile("package:test/src/bootstrap/browser.dart");
              await _ddc.compile(p.toUri(path));
            }
          });

          if (platform.compiler == Compiler.ddc) extension = ".ddc.html";
        }
      }

      if (_closed) return null;
      suiteUrl = url.resolveUri(p.toUri(
          p.withoutExtension(p.relative(path, from: _root)) + extension));
    }

    if (_closed) return null;

    // TODO(nweiz): Don't start the browser until all the suites are compiled.
    var browserManager = await _browserManagerFor(browser);
    if (_closed || browserManager == null) return null;

    Object sourceMapCommand;
    if (browser.isJS && !suiteConfig.jsTrace) {
      var mapper = _mappers[new Pair(path, platform.compiler)];
      if (mapper != null) {
        sourceMapCommand = {"type": "mapper", "mapper": mapper.serialize()};
      } else if (platform.compiler == Compiler.ddc) {
        sourceMapCommand = await _ddcSourceMapCommand;
      }
    }

    var suite = await browserManager.load(path, suiteUrl, suiteConfig, message,
        sourceMapCommand: sourceMapCommand);
    if (_closed) return null;
    return suite;
  }

  /// Returns the command to send to the worker to tell it to load source maps
  /// from DDC.
  Future<Object> get _ddcSourceMapCommand =>
      _ddcSourceMapCommandMemo.runOnce(() async {
        return {
          "type": "ddc",
          "packageResolver":
              serializePackageResolver(await PackageResolver.current.asSync),
          "mapDirUrl": p.toUri(_ddc.dir).toString()
        };
      });

  final _ddcSourceMapCommandMemo = new AsyncMemoizer<Object>();

  /// Returns whether the test at [path] has precompiled HTML available
  /// underneath [suiteConfig.precompiledPath].
  bool _precompiled(SuiteConfiguration suiteConfig, String path) {
    if (suiteConfig.precompiledPath == null) return false;
    var htmlPath = p.join(suiteConfig.precompiledPath,
        p.relative(p.withoutExtension(path) + ".html", from: _root));
    return new File(htmlPath).existsSync();
  }

  StreamChannel loadChannel(String path, SuitePlatform platform) =>
      throw new UnimplementedError();

  /// Loads a test suite at [path] from the `pub serve` URL [dartUrl].
  ///
  /// This ensures that only one suite is loaded at a time, and that any errors
  /// are exposed as [LoadException]s.
  Future _pubServeSuite(String path, Uri dartUrl, Runtime browser,
      SuiteConfiguration suiteConfig) {
    return _pubServePool.withResource(() async {
      var timer = new Timer(new Duration(seconds: 1), () {
        print('"pub serve" is compiling $path...');
      });

      // For browsers that run Dart compiled to JavaScript, get the source map
      // instead of the Dart code for two reasons. We want to verify that the
      // server's dart2js compiler is running on the Dart code, and also load
      // the StackTraceMapper.
      var getSourceMap = browser.isJS;

      var url = getSourceMap
          ? dartUrl.replace(path: dartUrl.path + '.js.map')
          : dartUrl;

      HttpClientResponse response;
      try {
        var request = await _http.getUrl(url);
        response = await request.close();

        if (response.statusCode != 200) {
          // We don't care about the response body, but we have to drain it or
          // else the process can't exit.
          response.listen((_) {});

          throw new LoadException(
              path,
              "Error getting $url: ${response.statusCode} "
              "${response.reasonPhrase}\n"
              'Make sure "pub serve" is serving the test/ directory.');
        }

        if (getSourceMap && !suiteConfig.jsTrace) {
          _mappers[new Pair(path, Compiler.dart2js)] = new StackTraceMapper(
              await UTF8.decodeStream(response),
              mapUrl: url,
              packageResolver: new SyncPackageResolver.root('packages'),
              sdkRoot: p.toUri('packages/\$sdk'));
          return;
        }

        // Drain the response stream.
        response.listen((_) {});
      } on IOException catch (error) {
        var message = getErrorMessage(error);
        if (error is SocketException) {
          message = "${error.osError.message} "
              "(errno ${error.osError.errorCode})";
        }

        throw new LoadException(
            path,
            "Error getting $url: $message\n"
            'Make sure "pub serve" is running.');
      } finally {
        timer.cancel();
      }
    });
  }

  /// Compile the test suite at [dartPath] to JavaScript.
  ///
  /// Once the suite has been compiled, it's added to [_jsHandler] so it can be
  /// served.
  Future _compileSuiteWithDart2js(
      String dartPath, SuiteConfiguration suiteConfig) async {
    var dir = new Directory(_compiledDir).createTempSync('test_').path;
    var jsPath = p.join(dir, p.basename(dartPath) + ".browser_test.dart.js");

    await _dart2js.compile('''
        import "package:test/src/bootstrap/browser.dart";

        import "${p.toUri(p.absolute(dartPath))}" as test;

        void main() {
          internalBootstrapBrowserTest(() => test.main);
        }
      ''', jsPath, suiteConfig);
    if (_closed) return;

    var jsUrl = p.toUri(p.relative(dartPath, from: _root)).path +
        '.browser_test.dart.js';
    _jsHandler.add(jsUrl, (request) {
      return new shelf.Response.ok(new File(jsPath).readAsStringSync(),
          headers: {'Content-Type': 'application/javascript'});
    });

    var mapUrl = p.toUri(p.relative(dartPath, from: _root)).path +
        '.browser_test.dart.js.map';
    _jsHandler.add(mapUrl, (request) {
      return new shelf.Response.ok(new File(jsPath + '.map').readAsStringSync(),
          headers: {'Content-Type': 'application/json'});
    });

    if (suiteConfig.jsTrace) return;
    var mapPath = jsPath + '.map';
    _mappers[new Pair(dartPath, Compiler.dart2js)] = new StackTraceMapper(
        new File(mapPath).readAsStringSync(),
        mapUrl: p.toUri(mapPath),
        packageResolver: await PackageResolver.current.asSync,
        sdkRoot: p.toUri(sdkDir));
  }

  /// Returns the [BrowserManager] for [runtime], which should be a browser.
  ///
  /// If no browser manager is running yet, starts one.
  Future<BrowserManager> _browserManagerFor(Runtime browser) {
    var managerFuture = _browserManagers[browser];
    if (managerFuture != null) return managerFuture;

    var completer = new Completer<WebSocketChannel>.sync();
    var path = _webSocketHandler.create(webSocketHandler(completer.complete));
    var webSocketUrl = url.replace(scheme: 'ws').resolve(path);
    var hostUrl = (_config.pubServeUrl == null ? url : _config.pubServeUrl)
        .resolve('packages/test/src/runner/browser/static/index.html')
        .replace(queryParameters: {
      'managerUrl': webSocketUrl.toString(),
      'debug': _config.pauseAfterLoad.toString()
    });

    var future = BrowserManager.start(
        browser, hostUrl, completer.future, _browserSettings[browser],
        debug: _config.pauseAfterLoad);

    // Store null values for browsers that error out so we know not to load them
    // again.
    _browserManagers[browser] = future.catchError((_) => null);

    return future;
  }

  /// Close all the browsers that the server currently has open.
  ///
  /// Note that this doesn't close the server itself. Browser tests can still be
  /// loaded, they'll just spawn new browsers.
  Future closeEphemeral() {
    var managers = _browserManagers.values.toList();
    _browserManagers.clear();
    return Future.wait(managers.map((manager) async {
      var result = await manager;
      if (result == null) return;
      await result.close();
    }));
  }

  /// Closes the server and releases all its resources.
  ///
  /// Returns a [Future] that completes once the server is closed and its
  /// resources have been fully released.
  Future close() => _closeMemo.runOnce(() async {
        var futures =
            _browserManagers.values.map<Future<dynamic>>((future) async {
          var result = await future;
          if (result == null) return;

          await result.close();
        }).toList();

        futures.add(_server.close());
        futures.add(_dart2js.close());
        if (__ddc != null) futures.add(__ddc.close());

        await Future.wait(futures);

        if (_config.pubServeUrl == null) {
          //new Directory(_compiledDir).deleteSync(recursive: true);
        } else {
          _http.close();
        }
      });
  final _closeMemo = new AsyncMemoizer();
}
