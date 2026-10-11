import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../services/location_service.dart';

class LocationState {
  const LocationState({this.status = LocationStatus.unknown, this.fix});
  final LocationStatus status;
  final UserFix? fix;

  bool get hasFix => fix != null;
  LocationState copyWith({LocationStatus? status, UserFix? fix}) => LocationState(status: status ?? this.status, fix: fix ?? this.fix);
}

/// Tracks the phone's real GPS position so every tab can show the "you are here" marker.
class LocationCubit extends Cubit<LocationState> {
  LocationCubit({LocationService? service, this.background = false}) : _service = service ?? LocationService(), super(const LocationState());

  /// Keep reporting while the app is in the background (drivers). Changing it restarts the stream.
  bool background;

  Future<void> setBackground(bool value) async {
    if (background == value) return;
    background = value;
    if (state.status == LocationStatus.ready) await start(request: false);
  }

  final LocationService _service;
  StreamSubscription<UserFix>? _sub;

  Future<void> start({bool request = true}) async {
    try {
      final status = await _service.ensurePermission(request: request);
      emit(state.copyWith(status: status));
      if (status != LocationStatus.ready) return;
      final first = await _service.current();
      if (first != null) emit(state.copyWith(fix: first));
      await _sub?.cancel();
      _sub = _service.stream(background: background).listen((f) => emit(state.copyWith(fix: f)), onError: (_) {});
    } catch (_) {
      emit(state.copyWith(status: LocationStatus.unknown)); // platform location unavailable (e.g. host tests)
    }
  }

  Future<void> openSettings() => state.status == LocationStatus.serviceOff ? _service.openLocationSettings() : _service.openSettings();

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
