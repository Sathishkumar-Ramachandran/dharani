import 'device_info.dart';
import 'model_manager.dart';
import 'npu_asr.dart';

/// Whether speech recognition can run on the Snapdragon NPU on this phone.
class QairtStatus {
  const QairtStatus({required this.available, required this.reasons, this.missingModels = const []});
  final bool available;
  final List<String> reasons; // human-readable blockers
  final List<ModelSpec> missingModels;
}

/// Qualcomm AI Runtime backend (ONNX Runtime + QNN HTP). Needs:
///   1. a Snapdragon SoC the models were compiled for,
///   2. the QNN/ONNX Runtime libraries (packaged in the APK),
///   3. the Whisper model + tokenizer downloaded through [ModelManager].
class QairtBackend {
  QairtBackend({required this.models, required this.device, required this.npu});
  final ModelManager models;
  final DeviceInfo device;
  final NpuAsr npu;

  /// Manifest entries that apply to this phone's SoC.
  Future<List<ModelSpec>> applicable() async {
    final manifest = await models.loadManifest();
    return [for (final m in manifest) if (m.socModels.isEmpty || m.socModels.contains(device.socModel.toUpperCase())) m];
  }

  Future<QairtStatus> probe() async {
    final reasons = <String>[];
    if (!device.supportsHexagon) {
      reasons.add('This phone has no Qualcomm Snapdragon chip (found ${device.socManufacturer.isEmpty ? 'unknown' : device.socManufacturer} ${device.socModel}).');
    }
    final mine = await applicable();
    if (device.supportsHexagon && mine.isEmpty) {
      reasons.add('No NPU speech model is published for ${device.chipName} (${device.socModel}).');
    }
    if (!await npu.runtimeBundled()) {
      reasons.add('The QNN runtime libraries are not part of this build.');
    }
    final missing = <ModelSpec>[];
    for (final m in mine) {
      if (!await models.isInstalled(m)) missing.add(m);
    }
    if (missing.isNotEmpty) reasons.add('${missing.length} model file(s) not downloaded yet.');
    return QairtStatus(available: reasons.isEmpty, reasons: reasons, missingModels: missing);
  }
}
