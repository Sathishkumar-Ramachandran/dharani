import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/telemetry_node.dart';

class MeshState {
  const MeshState({
    this.path = NetworkPath.offline,
    this.uplinkAvailable = false,
    this.peers = 0,
    this.meshRunning = false,
    this.queuedProofs = 0,
    this.outageSimulated = false,
    this.error,
  });

  final NetworkPath path;
  final bool uplinkAvailable;
  final int peers;
  final bool meshRunning;
  final int queuedProofs;
  final bool outageSimulated;
  final String? error;

  /// 5G/LTE/Wi-Fi uplink -> sidelink mesh (peers heard) -> satellite NTN store-and-forward.
  static NetworkPath resolve({required bool uplink, required int peers, required bool ntnArmed}) {
    if (uplink) return NetworkPath.fiveG;
    if (peers > 0) return NetworkPath.sidelinkMesh;
    return ntnArmed ? NetworkPath.satelliteNtn : NetworkPath.offline;
  }

  MeshState copyWith({
    bool? uplinkAvailable,
    int? peers,
    bool? meshRunning,
    int? queuedProofs,
    bool? outageSimulated,
    NetworkPath? path,
    String? error,
    bool clearError = false,
  }) =>
      MeshState(
        path: path ?? this.path,
        uplinkAvailable: uplinkAvailable ?? this.uplinkAvailable,
        peers: peers ?? this.peers,
        meshRunning: meshRunning ?? this.meshRunning,
        queuedProofs: queuedProofs ?? this.queuedProofs,
        outageSimulated: outageSimulated ?? this.outageSimulated,
        error: clearError ? null : (error ?? this.error),
      );
}

class MeshMonitorCubit extends Cubit<MeshState> {
  MeshMonitorCubit() : super(const MeshState());

  int _offlineSamples = 0;

  void setMeshRunning(bool running, {String? error}) =>
      emit(state.copyWith(meshRunning: running, error: error, clearError: error == null));

  void setUplink(bool available) => _recompute(uplink: available);

  void setPeers(int peers) => _recompute(peers: peers);

  void setOutageSimulated(bool value) {
    emit(state.copyWith(outageSimulated: value));
    _recompute();
  }

  /// Called once per telemetry sample. While there is no uplink every signed proof is queued for
  /// the next satellite (NTN) burst; the queue drains as soon as the uplink returns.
  void onProof() {
    final effectiveUplink = state.uplinkAvailable && !state.outageSimulated;
    if (effectiveUplink) {
      _offlineSamples = 0;
      if (state.queuedProofs != 0) emit(state.copyWith(queuedProofs: 0));
    } else {
      _offlineSamples++;
      emit(state.copyWith(queuedProofs: state.queuedProofs + 1));
    }
    _recompute();
  }

  void _recompute({bool? uplink, int? peers}) {
    final up = uplink ?? state.uplinkAvailable;
    final pc = peers ?? state.peers;
    final path = MeshState.resolve(
      uplink: up && !state.outageSimulated,
      peers: pc,
      ntnArmed: _offlineSamples >= 5,
    );
    emit(state.copyWith(uplinkAvailable: up, peers: pc, path: path));
  }
}
