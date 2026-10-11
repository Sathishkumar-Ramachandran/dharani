import 'dart:io';

import 'package:flutter/services.dart';

class DeviceInfo {
  const DeviceInfo({this.model = '', this.socManufacturer = '', this.socModel = '', this.sdk = 0});

  final String model, socManufacturer, socModel;
  final int sdk;

  static const _channel = MethodChannel('dharani/device');

  static Future<DeviceInfo> read() async {
    if (!Platform.isAndroid) return const DeviceInfo();
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('info');
      if (m == null) return const DeviceInfo();
      return DeviceInfo(
        model: m['model'] as String? ?? '',
        socManufacturer: m['socManufacturer'] as String? ?? '',
        socModel: m['socModel'] as String? ?? '',
        sdk: (m['sdk'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException {
      return const DeviceInfo();
    } on MissingPluginException {
      return const DeviceInfo();
    }
  }

  bool get isQualcomm => socManufacturer.toUpperCase() == 'QTI' || socManufacturer.toLowerCase().contains('qualcomm');

  /// Marketing name for the Snapdragon parts relevant to QAIRT/HTP.
  String get chipName => switch (socModel.toUpperCase()) {
        'SM8850' => 'Snapdragon 8 Elite Gen 5',
        'SM8750' => 'Snapdragon 8 Elite',
        'SM8650' => 'Snapdragon 8 Gen 3',
        'SM8550' => 'Snapdragon 8 Gen 2',
        '' => 'Unknown chip',
        _ => socModel,
      };

  /// QAIRT's HTP (Hexagon) backend needs a Snapdragon part.
  bool get supportsHexagon => isQualcomm;
}
