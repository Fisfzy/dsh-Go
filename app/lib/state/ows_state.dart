// 手环互联的 UI 状态：开关、配对码、服务状态、已配对设备。
// 不持有 HttpServer（那是 OwsServer 的事），只保存可展示的数据。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_state.dart';
import '../service/ows/ows_pairing.dart';

enum OwsServiceStatus { off, listening, error }

class OwsState {
  const OwsState({
    this.enabled = false,
    this.status = OwsServiceStatus.off,
    this.code = '',
    this.token = '',
    this.address = '',
    this.error = '',
    this.devices = const <String>[],
  });

  final bool enabled;
  final OwsServiceStatus status;
  final String code;
  final String token;
  final String address;
  final String error;
  final List<String> devices;

  OwsState copyWith({
    bool? enabled,
    OwsServiceStatus? status,
    String? code,
    String? token,
    String? address,
    String? error,
    List<String>? devices,
  }) =>
      OwsState(
        enabled: enabled ?? this.enabled,
        status: status ?? this.status,
        code: code ?? this.code,
        token: token ?? this.token,
        address: address ?? this.address,
        error: error ?? this.error,
        devices: devices ?? this.devices,
      );
}

final owsPairingProvider = Provider<OwsPairing>((ref) => OwsPairing());

final owsStateProvider =
    AsyncNotifierProvider<OwsController, OwsState>(OwsController.new);

class OwsController extends AsyncNotifier<OwsState> {
  static const _kEnabled = 'ows.link.enabled';
  static const _kDevices = 'ows.link.devices';

  @override
  Future<OwsState> build() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kEnabled) ?? false;
    final devices = prefs.getStringList(_kDevices) ?? <String>[];
    final pairing = ref.read(owsPairingProvider);
    final session = pairing.renew();
    return OwsState(
      enabled: enabled,
      code: session.code,
      token: session.token,
      devices: devices,
    );
  }

  OwsState get _s => state.value ?? const OwsState();

  void _update(OwsState next) => state = AsyncData(next);

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, _s.enabled);
    await prefs.setStringList(_kDevices, _s.devices);
  }

  /// 刷新配对码：旧码立即作废，已配对令牌保留。
  void renewCode() {
    final session = ref.read(owsPairingProvider).renew();
    _update(_s.copyWith(
      code: session.code,
      token: session.token,
      error: '',
    ));
  }

  void setListening(String address) {
    _update(_s.copyWith(
      enabled: true,
      status: OwsServiceStatus.listening,
      address: address,
      error: '',
    ));
    unawaited(_persist());
  }

  void setStopped() {
    _update(_s.copyWith(
      enabled: false,
      status: OwsServiceStatus.off,
      address: '',
      error: '',
    ));
    unawaited(_persist());
  }

  void setError(String message) {
    _update(_s.copyWith(
      status: OwsServiceStatus.error,
      error: message,
      enabled: false,
    ));
    unawaited(_persist());
  }

  void rememberDevice(String label) {
    if (label.isEmpty || _s.devices.contains(label)) return;
    _update(_s.copyWith(devices: <String>[..._s.devices, label]));
    unawaited(_persist());
  }

  void forgetDevice(String label) {
    _update(_s.copyWith(
        devices: _s.devices.where((d) => d != label).toList(growable: false)));
    unawaited(_persist());
  }
}

/// 当前连接（本机或远程）的简明标签，供手环 state 端点展示。
final owsHostLabelProvider = Provider<String>((ref) {
  final conn = ref.watch(activeConnectionProvider);
  return conn.when(
    data: (c) => c?.label ?? '',
    loading: () => '',
    error: (_, __) => '',
  );
});
