// 手环互联的局域网 HTTP 服务：8766 端口，8 个端点。
//
// 安全模型（与 companion_server.dart 同一套）：
//   • 仅在用户打开开关时 bind anyIPv4:8766，关闭即 close(force: true)
//   • 除 pair 外所有端点必须带 ?token= 或 x-dshgo-token
//   • token 比较用常量时间，避免时序侧信道
//   • 语音 body 上限 8 MiB；JSON body 上限 64 KiB
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import '../../state/ows_state.dart';
import 'ows_bridge.dart';

const int owsPort = 8766;
const int _maxJsonBytes = 64 * 1024;
const int _maxAudioBytes = 8 * 1024 * 1024;

class OwsServer {
  OwsServer._(this._server, this._bridge, this._controller);

  static Future<OwsServer> start(
    OwsBridge bridge,
    OwsController controller,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, owsPort);
    return OwsServer._(server, bridge, controller).._listen();
  }

  final HttpServer _server;
  final OwsBridge _bridge;
  final OwsController _controller;
  Future<void>? _closing;
  final Set<Future<void>> _pending = <Future<void>>{};

  int get port => _server.port;

  /// 供 UI 展示：第一个非回环 IPv4 地址。
  /// `NetworkInterface.list()` 是异步 API，Dart 没有同步版本。
  Future<String> lanAddress() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final nic in interfaces) {
        for (final addr in nic.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return '${addr.address}:$port';
          }
        }
      }
    } catch (_) {
      // 某些 ROM 上枚举网卡会抛 SocketException，回落到回环地址。
    }
    return '127.0.0.1:$port';
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await _server.close(force: true);
    await Future.wait(List.of(_pending));
  }

  void _listen() {
    _server.listen((request) {
      late final Future<void> pending;
      pending = _handle(request).catchError((Object _) {
        // 客户端断开是常态，不向上抛。
      }).whenComplete(() => _pending.remove(pending));
      _pending.add(pending);
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      final token = request.uri.queryParameters['token'] ??
          request.headers.value('x-dshgo-token') ??
          '';
      developer.log(
        '[OWS] --> ${request.method} $path tokenLen=${token.length} '
        'ct=${request.headers.contentType?.mimeType ?? '-'} '
        'len=${request.headers.contentLength}',
        name: 'ows',
      );

      Object? body;
      if (path == '/api/ows/voice') {
        body = await _readBytes(request, _maxAudioBytes);
      } else if (request.method == 'POST') {
        final bytes = await _readBytes(request, _maxJsonBytes);
        if (bytes.isEmpty) {
          body = <String, Object?>{};
        } else {
          body = jsonDecode(utf8.decode(bytes));
        }
      }

      OwsResult result;
      switch (path) {
        case '/api/ows/pair' when request.method == 'POST':
          final code = (body as Map?)?['code']?.toString() ?? '';
          result = _bridge.pair(code);
          if (result.ok) {
            final label = request.connectionInfo?.remoteAddress.address ?? '手环';
            _controller.rememberDevice(label);
          }
          break;
        case '/api/ows/state' when request.method == 'GET':
          result = await _bridge.state(token);
          break;
        case '/api/ows/sessions' when request.method == 'GET':
          result = await _bridge.sessions(token);
          break;
        case '/api/ows/voice' when request.method == 'POST':
          // body 是 16kHz / mono / 16-bit 裸 PCM；WAV 头由 OwsBridge 补。
          result = await _bridge.voice(token, body as Uint8List);
          break;
        case '/api/ows/prompt' when request.method == 'POST':
          result = await _bridge.prompt(token, (body as Map?)?['text']?.toString() ?? '');
          break;
        case '/api/ows/session/new' when request.method == 'POST':
          result = await _bridge.newSession(token);
          break;
        case '/api/ows/session/select' when request.method == 'POST':
          final id = (body as Map?)?['sessionId']?.toString();
          result = await _bridge.selectSession(token, id);
          break;
        case '/api/ows/cancel' when request.method == 'POST':
          result = await _bridge.cancel(token, (body as Map?)?['sessionId']?.toString());
          break;
        default:
          result = const OwsResult(false, {}, 'not-found');
      }

      developer.log(
        '[OWS] <-- $path ${result.ok ? 'OK' : 'ERR:${result.error}'} '
        '${jsonEncode(result.toJson())}',
        name: 'ows',
      );
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(result.toJson()));
    } on _TooLarge {
      response.statusCode = HttpStatus.requestEntityTooLarge;
      response.write(jsonEncode(<String, Object?>{'ok': false, 'error': 'too-large'}));
    } catch (e) {
      developer.log('[OWS] !! exception ${request.uri.path} $e', name: 'ows', error: e);
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode(<String, Object?>{'ok': false, 'error': 'internal'}));
    } finally {
      await response.close();
    }
  }

  Future<Uint8List> _readBytes(HttpRequest request, int max) async {
    final chunks = <List<int>>[];
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > max) throw _TooLarge();
      chunks.add(chunk);
    }
    return Uint8List.fromList(chunks.expand((c) => c).toList());
  }
}

class _TooLarge implements Exception {}

// 令牌的常量时间比较在 OwsPairing.validToken() 中实现，此处不重复。
