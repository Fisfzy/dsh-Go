// 手环互联：配对码生成与校验。
//
// 规则对齐 dsh-watch 已在真机验证过的契约：6 位数字、一次性、10 分钟过期、
// 连续错误限速。这里不依赖任何第三方包，便于单元测试。
import 'dart:math';

class PairSession {
  PairSession(this.code, this.token, this.expiresAt);

  final String code;
  final String token;
  final DateTime expiresAt;

  bool get expired => DateTime.now().isAfter(expiresAt);
}

class OwsPairing {
  OwsPairing({Random? random, this._ttl = const Duration(minutes: 10)})
      : _random = random ?? Random.secure();

  final Random _random;
  final Duration _ttl;
  PairSession? _current;
  int _failures = 0;
  DateTime _windowStart = DateTime.now();

  /// 生成新配对码。旧的立即作废。
  PairSession renew() {
    final code = List.generate(6, (_) => _random.nextInt(10)).join();
    final token = List.generate(32, (_) => _random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    _current = PairSession(code, token, DateTime.now().add(_ttl));
    _failures = 0;
    _windowStart = DateTime.now();
    return _current!;
  }

  PairSession? get current => _current;

  /// 返回 null 表示失败（码错/过期/被限速），成功时返回会话并立刻作废该码。
  PairSession? redeem(String code) {
    final session = _current;
    if (session == null || session.expired) return null;
    if (_rateLimited()) return null;
    if (code.trim() != session.code) {
      _failures++;
      return null;
    }
    _current = null; // 一次性
    _failures = 0;
    return session;
  }

  /// 常量时间比较，避免通过响应时间推测令牌。
  bool validToken(String token) {
    if (token.isEmpty) return false;
    var found = false;
    for (final issued in _pairedTokens) {
      if (issued.length != token.length) continue;
      var difference = 0;
      for (var i = 0; i < issued.length; i++) {
        difference |= issued.codeUnitAt(i) ^ token.codeUnitAt(i);
      }
      if (difference == 0) found = true;
    }
    return found;
  }

  final Set<String> _pairedTokens = <String>{};

  void remember(PairSession session) => _pairedTokens.add(session.token);

  void forget(String token) => _pairedTokens.remove(token);

  /// App 冷启动后从 SharedPreferences 恢复已授权令牌，
  /// 否则手环每次都要重新输 6 位码配对。
  void restore(Iterable<String> tokens) => _pairedTokens.addAll(tokens);

  /// 供 OwsController 持久化。
  List<String> get tokens => List<String>.unmodifiable(_pairedTokens);

  bool _rateLimited() {
    final now = DateTime.now();
    if (now.difference(_windowStart).inMinutes >= 1) {
      _windowStart = now;
      _failures = 0;
    }
    return _failures >= 8;
  }
}
