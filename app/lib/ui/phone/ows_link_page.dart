// 设置 → 互联 → 手环/手表互联。
// 开关服务、展示配对码与连接地址、管理已配对设备。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../service/ows/ows_server_controller.dart';
import '../../state/ows_state.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../settings/settings_widgets.dart';

class OwsLinkPage extends ConsumerWidget {
  const OwsLinkPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final s = ref.watch(owsStateProvider).value ?? const OwsState();
    final notifier = ref.read(owsStateProvider.notifier);
    final server = ref.read(owsServerProvider.notifier);
    final errorColor = Theme.of(context).colorScheme.error;
    final statusLabel = switch (s.status) {
      OwsServiceStatus.off => l10n.owsLinkStatusOff,
      OwsServiceStatus.listening => l10n.owsLinkStatusOn,
      OwsServiceStatus.error => l10n.owsLinkStatusError,
    };

    return AppPage.list(
      title: l10n.owsLinkTitle,
      children: [
        SettingsSection(
          footer: Text(l10n.owsLinkSubtitle),
          children: [
            SettingsSwitchTile(
              key: const ValueKey('ows-link-enable'),
              icon: AppIcons.wearableLink,
              title: l10n.owsLinkEnable,
              subtitle: l10n.owsLinkEnableHint,
              value: s.enabled,
              onChanged: (next) => unawaited(next ? server.start() : server.stop()),
            ),
            InfoRow(label: l10n.owsLinkEnable, value: statusLabel, mono: true),
          ],
        ),
        SettingsSection(
          title: l10n.owsLinkPairCode,
          footer: Text(l10n.owsLinkPairCodeHint),
          children: [
            SettingsTile(
              key: const ValueKey('ows-link-code'),
              icon: AppIcons.link,
              title: s.code.isEmpty ? '——' : s.code,
              subtitle: l10n.owsLinkRefreshCode,
              onTap: notifier.renewCode,
            ),
          ],
        ),
        SettingsSection(
          title: l10n.owsLinkAddress,
          footer: Text(l10n.owsLinkAddressHint),
          children: [
            InfoRow(
              label: l10n.owsLinkAddress,
              value: s.address.isEmpty ? l10n.owsLinkNoAddress : s.address,
              mono: true,
            ),
          ],
        ),
        SettingsSection(
          title: l10n.owsLinkPairedDevices,
          footer: Text(l10n.owsLinkHowTo),
          children: [
            if (s.devices.isEmpty)
              InfoRow(label: l10n.owsLinkPairedDevices, value: l10n.owsLinkNoDevices)
            else
              for (final device in s.devices)
                SettingsTile(
                  key: ValueKey('ows-device-$device'),
                  icon: AppIcons.wearableLink,
                  title: device,
                  subtitle: l10n.owsLinkForget,
                  onTap: () => notifier.forgetDevice(device),
                ),
          ],
        ),
        if (s.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(s.error, style: TextStyle(color: errorColor)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Text(l10n.owsLinkSecurity),
        ),
      ],
    );
  }
}
