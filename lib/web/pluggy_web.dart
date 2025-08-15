// ignore_for_file: avoid_web_libraries_in_flutter
@JS()
library pluggy_web;

import 'dart:async';
import 'dart:html';
import 'package:js/js.dart';
import 'package:js/js_util.dart' as js_util;

@JS('PluggyConnect')
class _PluggyConnectJS {
  external factory _PluggyConnectJS(_PluggyOptions options);
  external dynamic init();
  external dynamic open();
  external void destroy();
}

@JS()
@anonymous
class _PluggyOptions {
  external String get connectToken;
  external bool? get includeSandbox;
  external Function(dynamic)? get onSuccess;
  external Function(dynamic)? get onError;
  external Function()? get onClose;

  external factory _PluggyOptions({
    required String connectToken,
    bool? includeSandbox,
    Function(dynamic)? onSuccess,
    Function(dynamic)? onError,
    Function()? onClose,
  });
}

bool _isSdkLoaded() => js_util.getProperty<Object?>(window, 'PluggyConnect') != null;

Future<void> _ensureScriptLoaded() async {
  if (_isSdkLoaded()) return;
  final Node? target = document.head ?? document.body ?? document.documentElement;
  if (target == null) throw Exception('Não foi possível injetar o script do Pluggy.');

  final urls = <String>[
    'https://cdn.pluggy.ai/pluggy-connect/latest/pluggy-connect.js',
    'https://static-cdn.pluggy.ai/pluggy-connect/latest/pluggy-connect.js',
  ];

  Object? lastError;
  for (final url in urls) {
    final c = Completer<void>();
    final script = ScriptElement()..src = url..type = 'text/javascript'..defer = true;
    script.onLoad.listen((_) => c.complete());
    script.onError.listen((_) => c.completeError(Exception('Falha ao carregar $url')));
    target.append(script);
    try {
      await c.future;
      if (_isSdkLoaded()) return;
    } catch (e) {
      lastError = e;
    }
  }
  throw Exception('Não foi possível carregar o Pluggy Web. Último erro: $lastError');
}

Future<void> preloadPluggyConnectScript() => _ensureScriptLoaded();

Future<String?> openPluggyConnectWeb(String connectToken) async {
  await _ensureScriptLoaded();

  final completer = Completer<String?>();
  late _PluggyConnectJS instance;

  void completeOnce(String? v) { if (!completer.isCompleted) completer.complete(v); }
  void safeDestroy() { try { instance.destroy(); } catch (_) {} }

  void onSuccess(dynamic data) {
    try {
      String? id;
      final item = js_util.getProperty<Object?>(data, 'item');
      if (item != null) {
        id = js_util.getProperty<Object?>(item, 'id')?.toString();
      }
      id ??= js_util.getProperty<Object?>(data, 'id')?.toString();
      id ??= js_util.getProperty<Object?>(data, 'itemId')?.toString();
      completeOnce(id);
    } catch (_) {
      completeOnce(null);
    } finally {
      safeDestroy();
    }
  }

  void onError(dynamic _) { completeOnce(null); safeDestroy(); }
  void onClose() { completeOnce(null); safeDestroy(); }

  instance = _PluggyConnectJS(_PluggyOptions(
    connectToken: connectToken,
    includeSandbox: false,
    onSuccess: allowInterop(onSuccess),
    onError: allowInterop(onError),
    onClose: allowInterop(onClose),
  ));

  dynamic result;
  try {
    if (js_util.hasProperty(instance, 'init')) {
      result = instance.init();
    } else if (js_util.hasProperty(instance, 'open')) {
      result = instance.open();
    }
  } catch (_) {}

  try {
    if (result != null && js_util.hasProperty(result, 'then')) {
      await js_util.promiseToFuture(result);
    }
  } catch (_) {}

  return completer.future;
}
