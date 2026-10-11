import 'package:flutter_bloc/flutter_bloc.dart';

import '../services/engine_host.dart';
import '../services/overpass_service.dart';

class RegionState {
  const RegionState({this.info, this.busy = false, this.stage, this.error});
  final RegionInfo? info;
  final bool busy;
  final String? stage, error;

  bool covers(double lat, double lon) => info != null && info!.bounds.contains(lat, lon);
}

/// Offline road coverage: shows what is installed and downloads new regions from OpenStreetMap.
class RegionCubit extends Cubit<RegionState> {
  RegionCubit(this.host, {OverpassService? overpass})
      : _overpass = overpass ?? OverpassService(),
        super(RegionState(info: host.region));

  final EngineHost host;
  final OverpassService _overpass;

  Future<void> refresh() async => emit(RegionState(info: host.region));

  Future<void> download(double lat, double lon, {double radiusKm = 8}) async {
    if (state.busy) return;
    if (host.activeOwner != null) {
      emit(RegionState(info: state.info, error: 'Finish the active trip before changing the road region.'));
      return;
    }
    emit(RegionState(info: state.info, busy: true, stage: 'Starting…'));
    try {
      await _overpass.downloadRegion(RegionBounds.around(lat, lon, radiusKm), host.dir,
          onStage: (s) => emit(RegionState(info: state.info, busy: true, stage: s)));
      await host.reloadGraph();
      emit(RegionState(info: host.region));
    } on OverpassException catch (e) {
      emit(RegionState(info: state.info, error: e.message));
    } catch (e) {
      emit(RegionState(info: state.info, error: 'Could not install the region: $e'));
    }
  }

  Future<void> useDemoCorridor() async {
    if (host.activeOwner != null) return;
    await host.installDemoGraph();
    emit(RegionState(info: host.region));
  }
}
