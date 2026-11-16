// 手环互联业务桥接：把 8 个 HTTP 端点映射到 dsh-Go 已有的能力。
//
// 设计原则：这里不做新的 AI / REMOTE 逻辑，只做适配。
//   • 发指令 → client.prompt() → session/prompt
//   • 会话列表 → sessionsProvider（SessionSummary 的 title 在 projections 里）
//   • 切换会话 → currentSessionProvider.select()（无主机 RPC）
//   • 停止 → client.cancel()
//   • 语音 → client.transcribe(WAV) → 再走 prompt
import 'dart:collection';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/sessions_state.dart';
import 'ows_pairing.dart';

class OwsResult {
  const OwsResult(this.ok, this.data, [this.error = '']);

  final bool ok;
  final Map<String, Object?> data;
  final String error;

  Map<String, Object?> toJson() => ok
      ? <String, Object?>{'ok': true, ...data}
      : <String, Object?>{
          'ok': false,
          'error': error,
          if (data.isNotEmpty) ...data,
        };

  static const noHost = OwsResult(false, <String, Object?>{}, 'no-host');
  static const notPaired = OwsResult(false, <String, Object?>{}, 'not-paired');
}

/// 手环上传的是 16kHz / mono / 16-bit 裸 PCM，而 dsh-Go 的
/// `client.transcribe()` 只收 WAV。这里在手机端补 44 字节 RIFF 头，
/// 避免在只有几 MB 内存的手环侧做 DataView 拼接。
Uint8List _pcmToWav(Uint8List pcm) {
  const sampleRate = 16000;
  const channels = 1;
  const bitsPerSample = 16;
  const blockAlign = channels * bitsPerSample ~/ 8;
  const byteRate = sampleRate * blockAlign;

  final header = ByteData(44);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      header.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // fmt chunk 长度
  header.setUint16(20, 1, Endian.little); // 1 = PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);

  return Uint8List.fromList(<int>[...header.buffer.asUint8List(), ...pcm]);
}

/// 手环看到的会话摘要。字段名严格对齐 PHONE_SPEC.md。
Map<String, Object?> _sessionJson(dynamic s) {
  final id = s.sessionId as String;
  return <String, Object?>{
    'sessionId': id,
    'title': s.title,
    'running': s.running,
    'blank': s.blank,
    'sessionStats': null, // 宿主没有 messageCount，不造字段
  };
}

class OwsBridge {
  OwsBridge(this._ref, this._pairing);

  /// 用 Ref（Notifier/Provider 都可用）；不绑定 Widget 生命周期。
  final Ref _ref;
  final OwsPairing _pairing;

  String? _lastText;
  String? _lastReply;
  String? _lastHost;

  bool _authorized(String token) => _pairing.validToken(token);

  DshClient? get _client {
    final conn = _ref.read(activeConnectionProvider).value;
    return conn?.client;
  }

  String? get _sessionId => _ref.read(currentSessionProvider);

  /// 配对：6 位码换 token，成功后 token 进入已授权集合。
  OwsResult pair(String code) {
    final session = _pairing.redeem(code);
    if (session == null) return const OwsResult(false, {}, 'pair-failed');
    _pairing.remember(session);
    return OwsResult(true, <String, Object?>{
      'token': session.token,
      'host': _lastHost ?? '',
    });
  }

  /// 状态快照：连接态 + 当前会话 + 会话列表 + 最近结果。
  Future<OwsResult> state(String token) async {
    if (!_authorized(token)) return OwsResult.notPaired;
    final conn = _ref.read(activeConnectionProvider).value;
    final client = conn?.client;
    final host = conn?.label ?? '';
    if (host.isNotEmpty) _lastHost = host;

    // 5 态 HostLinkPhase 在 UI 层；这里用能否拿到 client 推导 3 态
    final phase = client == null ? 'idle' : 'connected';
    final sessionId = _sessionId;

    final sessions = <Map<String, Object?>>[];
    final list = _ref.read(sessionsProvider).value;
    if (list != null) {
      for (final s in list) {
        if (s.isSubagent) continue;
        sessions.add(_sessionJson(s));
      }
    }

    return OwsResult(true, <String, Object?>{
      'online': client != null,
      'host': host,
      'linkPhase': phase,
      'canTranscribe': client?.canTranscribe ?? false,
      'busy': false,
      'currentSessionId': sessionId,
      'currentSessionTitle': _titleOf(sessionId, list),
      'running': _runningOf(sessionId, list),
      'sessions': sessions,
      if (_lastText != null) 'lastText': _lastText,
      if (_lastReply != null) 'lastReply': _lastReply,
    });
  }

  String? _titleOf(String? id, List<dynamic>? list) {
    if (id == null || list == null) return null;
    for (final s in list) {
      if (s.sessionId == id) return s.title;
    }
    return null;
  }

  bool _runningOf(String? id, List<dynamic>? list) {
    if (id == null || list == null) return false;
    for (final s in list) {
      if (s.sessionId == id) return s.running;
    }
    return false;
  }

  Future<OwsResult> sessions(String token) async {
    if (!_authorized(token)) return OwsResult.notPaired;
    final list = await _ref.read(sessionsProvider.future);
    final items = <Map<String, Object?>>[];
    for (final s in list) {
      if (s.isSubagent) continue;
      items.add(_sessionJson(s));
    }
    return OwsResult(true, <String, Object?>{
      'currentSessionId': _sessionId,
      'sessions': items,
    });
  }

  /// 发文本指令。新会话时先创建再发，避免 5001。
  Future<OwsResult> prompt(String token, String text) async {
    if (!_authorized(token)) return OwsResult.notPaired;
    final client = _client;
    if (client == null) return OwsResult.noHost;
    if (text.trim().isEmpty) return const OwsResult(false, {}, 'empty-text');

    var sessionId = _sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      try {
        sessionId = await _ref.read(sessionsProvider.notifier).create();
        _ref.read(currentSessionProvider.notifier).select(sessionId);
      } catch (e) {
        return OwsResult(false, {}, 'session-create-failed');
      }
    }

    try {
      await client.prompt(sessionId, text.trim());
      _lastText = text.trim();
      _lastReply = null;
      return OwsResult(true, <String, Object?>{'text': _lastText});
    } catch (e) {
      return OwsResult(false, {}, 'prompt-failed');
    }
  }

  /// 语音：body 是 16kHz / mono / 16-bit 裸 PCM，封成 WAV 后喂给
  /// dsh-Go 的 transcribe。识别出的文本走与文本指令相同的路径。
  Future<OwsResult> voice(String token, Uint8List pcm) async {
    if (!_authorized(token)) return OwsResult.notPaired;
    final client = _client;
    if (client == null) return OwsResult.noHost;
    if (pcm.length < 320) return const OwsResult(false, {}, 'bad-audio');
    const maxBytes = 8 * 1024 * 1024;
    if (pcm.length > maxBytes) return const OwsResult(false, {}, 'audio-too-large');

    try {
      // 不指定 providerId/language：让当前引擎用服务端默认值，
      // 避免在桥接层复制语音设置的复杂度。
      final transcript = await client.transcribe(_pcmToWav(pcm));
      if (transcript.text.isEmpty) {
        return const OwsResult(false, {}, 'not-heard');
      }
      final sent = await prompt(token, transcript.text);
      if (!sent.ok) return sent;
      return OwsResult(true, <String, Object?>{'text': transcript.text});
    } catch (e) {
      // 本机引擎通常没有 speech/* 能力（要单独准备 ASR 模型），
      // 区分这两种失败，手环才能给出可操作的提示。
      final unavailable = !client.canTranscribe;
      return OwsResult(false, <String, Object?>{'detail': e.toString()},
          unavailable ? 'asr-unavailable' : 'asr-failed');
    }
  }

  Future<OwsResult> newSession(String token) async {
    if (!_authorized(token)) return OwsResult.notPaired;
    if (_client == null) return OwsResult.noHost;
    try {
      final id = await _ref.read(sessionsProvider.notifier).create();
      _ref.read(currentSessionProvider.notifier).select(id);
      _lastText = null;
      _lastReply = null;
      return OwsResult(true, <String, Object?>{
        'sessionId': id,
        'currentSessionId': id,
      });
    } catch (e) {
      return OwsResult(false, {}, 'session-create-failed');
    }
  }

  Future<OwsResult> selectSession(String token, String? sessionId) async {
    if (!_authorized(token)) return OwsResult.notPaired;
    if (_client == null) return OwsResult.noHost;
    final list = await _ref.read(sessionsProvider.future);
    if (sessionId != null) {
      final found = list.where((s) => s.sessionId == sessionId).firstOrNull;
      if (found == null || found.blank || found.isSubagent) {
        return const OwsResult(false, {}, 'session-not-found');
      }
    }
    // dsh-Go 没有主机 RPC：这是纯本地状态，client.watch 会自动重订阅。
    _ref.read(currentSessionProvider.notifier).select(sessionId);
    _lastText = null;
    _lastReply = null;
    return OwsResult(true, <String, Object?>{'currentSessionId': sessionId});
  }

  Future<OwsResult> cancel(String token, String? sessionId) async {
    if (!_authorized(token)) return OwsResult.notPaired;
    final client = _client;
    if (client == null) return OwsResult.noHost;
    final id = sessionId ?? _sessionId;
    if (id == null || id.isEmpty) {
      return const OwsResult(true, {}); // 空闲也成功
    }
    try {
      await client.cancel(id);
      return const OwsResult(true, {});
    } catch (e) {
      return const OwsResult(false, {}, 'cancel-failed');
    }
  }
}
