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
  OwsServer? build() => null;

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
