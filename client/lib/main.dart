import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'app.dart';
import 'shared/utils/file_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FileLogger.init(); // start file logging before anything else
  await SodiumInit.init(); // pre-warm libsodium
  runApp(const ProviderScope(child: HubCoreApp()));
}
