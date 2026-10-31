import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

class WidgetCapabilities {
  const WidgetCapabilities({
    this.widgetSupported = false,
    this.detailSupported = false,
    this.pinSupported = false,
    this.installedCount = 0,
  });
  final bool widgetSupported, detailSupported, pinSupported;
  final int installedCount;
  bool get canOpenXiaomi => widgetSupported && detailSupported && pinSupported;
}

class WidgetSetupService {
  const WidgetSetupService();
  static const _channel = MethodChannel('slurm_monitor/widgets');
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<WidgetCapabilities> capabilities() async {
    if (!_android) return const WidgetCapabilities();
    final result = await _channel
        .invokeMapMethod<String, dynamic>('getCapabilities')
        .timeout(const Duration(seconds: 8));
    return WidgetCapabilities(
      widgetSupported: result?['widgetSupported'] == true,
      detailSupported: result?['detailSupported'] == true,
      pinSupported: result?['pinSupported'] == true,
      installedCount: result?['installedCount'] as int? ?? 0,
    );
  }

  Future<bool> openXiaomi() async =>
      _android &&
      await _channel
              .invokeMethod<bool>('requestXiaomiWidget')
              .timeout(const Duration(seconds: 8)) ==
          true;

  Future<bool> addDesktop() async {
    if (!_android || await HomeWidget.isRequestPinWidgetSupported() != true) {
      return false;
    }
    await HomeWidget.requestPinWidget(
      androidName: 'SlurmMonitorWidgetProvider',
    );
    return true;
  }
}
