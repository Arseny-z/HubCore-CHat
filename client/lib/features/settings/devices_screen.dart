import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'dart:async';

import '../../application/events/app_events.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/providers/messaging_providers.dart' show messageRouterProvider;
import '../../shared/providers/storage_providers.dart' show eventBusProvider;
import '../../shared/widgets/hubcore_app_bar.dart';
import '../../storage/dao/my_devices_dao.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  List<MyDevice> _devices = [];
  bool _loading = true;
  StreamSubscription<dynamic>? _pairingSub;

  @override
  void initState() {
    super.initState();
    _load();
    // Reload when pairing completes on Device A or ack received on Device B.
    final bus = ref.read(eventBusProvider);
    _pairingSub = bus.on<DevicePairingCompleteEvent>().listen((_) => _load());
    bus.on<DevicePairingAckEvent>().listen((_) => _load());
  }

  @override
  void dispose() {
    _pairingSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final list = await storage.myDevices.all();
    if (mounted) setState(() { _devices = list; _loading = false; });
  }

  Future<void> _deactivate(MyDevice d) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить устройство?'),
        content: Text(
            'Устройство ${d.deviceId.substring(0, 12)}… будет удалено. '
            'Оно больше не сможет получать сообщения.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final storage = ref.read(storageProvider);
    await storage.myDevices.deactivate(d.deviceId);
    // Broadcast updated device list so contacts remove this device
    ref.read(messageRouterProvider)?.broadcastHello();
    await _load();
  }

  String _osLabel(String os) {
    switch (os) {
      case 'android': return '📱 Android';
      case 'ios':     return '📱 iOS';
      case 'web':     return '🌐 Web';
      case 'linux':   return '🐧 Linux';
      default:        return '📱 $os';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: HubCoreAppBar(title: const Text('Мои устройства')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/pair-device'),
        tooltip: 'Добавить устройство',
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _devices.isEmpty
              ? const Center(
                  child: Text('Нет зарегистрированных устройств',
                      style: TextStyle(color: Colors.white38)),
                )
              : ListView.separated(
                  itemCount: _devices.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final d = _devices[i];
                    final isThisDevice = d.isActive && i == 0;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: d.isMaster
                            ? const Color(0xFFFFB300)
                            : const Color(0xFF2AABEE),
                        child: Icon(
                          d.isMaster ? Icons.star : Icons.devices,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                      title: Row(
                        children: [
                          Text(
                            '${_osLabel(d.deviceOs)}  '
                            '${d.deviceId.substring(0, 8)}…',
                            style: TextStyle(
                              color: d.isActive ? Colors.white : Colors.white38,
                            ),
                          ),
                          if (d.isMaster) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange.withAlpha(40),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('Главное',
                                  style: TextStyle(
                                      color: Colors.orange, fontSize: 11)),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        d.isActive
                            ? 'Активно'
                            : 'Отключено',
                        style: TextStyle(
                          color: d.isActive ? Colors.green : Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                      trailing: (!d.isMaster && d.isActive)
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red, size: 20),
                              onPressed: () => _deactivate(d),
                            )
                          : null,
                    );
                  },
                ),
    );
  }
}
