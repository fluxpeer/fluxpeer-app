// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

import 'common/app_theme.dart';
import 'common/i18n.dart';
import 'home/home.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await GetStorage.init();
  Get.put(AppController()).applyThemeAtStartup();
  runApp(const FluxpeerApp());
}

class FluxpeerApp extends StatelessWidget {
  const FluxpeerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'fluxpeer',
      debugShowCheckedModeBanner: false,
      theme: buildFluxpeerTheme(),
      translations: AppMessages(),
      locale: Get.find<AppController>().startupLocale,
      fallbackLocale: const Locale('en'),
      home: const HomeShell(),
    );
  }
}
