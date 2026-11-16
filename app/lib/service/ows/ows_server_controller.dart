// 手环互联服务的生命周期：持有 OwsServer 实例，供设置页开关调用。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/ows_state.dart';
import 'ows_bridge.dart';
import 'ows_server.dart';

final owsServerProvider =
    NotifierProvider<OwsServerController, OwsServer?>(OwsServerController.new);

class OwsServerController extends Notifier<OwsServer?> {
  @override
  OwsServer? build() {
    // App 冷启动后，若用户上次开着开关，自动恢复 8766 服务。
    // owsStateProvider 是异步的（要读 SharedPreferences），加载完成后
    // listen 会再回调一次；start() 内部有 state != null 的防重入。
    ref.listen(owsStateProvider, (prev, next) {
      final enabled = next.value?.enabled ?? false;
      if (enabled) Future.microtask(start);
    }, fireImmediately: true);
    return null;
  }

  Future<void> start() async {
    if (state != null) return;
    final notifier = ref.read(owsStateProvider.notifier);
    try {
      final bridge = OwsBridge(ref, ref.read(owsPairingProvider));
      final server = await OwsServer.start(bridge, notifier);
      state = server;
      notifier.setListening(await server.lanAddress());
    } on SocketException catch (_) {
      notifier.setError(appL10n.owsLinkPortBusy);
    } catch (_) {
      notifier.setError('start-failed');
    }
  }

  Future<void> stop() async {
    final server = state;
    state = null;
    await server?.close();
    ref.read(owsStateProvider.notifier).setStopped();
  }
}
