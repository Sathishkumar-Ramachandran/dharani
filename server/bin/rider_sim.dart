import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dharani_protocol/dharani_protocol.dart';

/// A scriptable rider for testing a real driver phone without a second phone.
///   dart run bin/rider_sim.dart --server http://127.0.0.1:8080 --lang hi --mode auto \
///       --pickup 12.9756,77.6068 --drop 12.9352,77.6245 --call --say "नमस्ते" --seconds 90
Future<void> main(List<String> args) async {
  String opt(String n, String d) {
    final i = args.indexOf('--$n');
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : d;
  }

  final server = opt('server', 'http://127.0.0.1:8080');
  final lang = opt('lang', 'hi');
  final mode = opt('mode', 'auto');
  final pickup = opt('pickup', '12.9756,77.6068').split(',').map(double.parse).toList();
  final drop = opt('drop', '12.9352,77.6245').split(',').map(double.parse).toList();
  final seconds = int.parse(opt('seconds', '90'));
  final wantCall = args.contains('--call');
  final say = opt('say', '');
  final sayTranslated = opt('say-translated', '');
  final peerLang = opt('peer-lang', 'ta');

  void log(String s) => stdout.writeln('[${DateTime.now().toIso8601String().substring(11, 19)}] $s');

  final http = HttpClient();
  final req = await http.postUrl(Uri.parse('$server/v1/register'));
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode({'name': 'Mac Rider', 'role': 'rider', 'lang': lang}));
  final reg = jsonDecode(await utf8.decoder.bind(await req.close()).join()) as Map<String, dynamic>;
  final wsUrl = Uri.parse(server).replace(scheme: server.startsWith('https') ? 'wss' : 'ws', path: '/v1/ws', queryParameters: {'token': reg['token']});
  final ws = await WebSocket.connect(wsUrl.toString());
  void send(Json m) => ws.add(jsonEncode(m));
  send({'t': T.hello, 'protocol': protocolVersion, 'name': 'Mac Rider', 'lang': lang});

  String? rideId;
  var audioIn = 0;
  var sentSay = false;
  ws.listen((d) {
    if (d is List<int>) {
      audioIn++;
      if (audioIn == 1 || audioIn % 100 == 0) log('audio frames received: $audioIn');
      return;
    }
    final m = jsonDecode(d as String) as Map<String, dynamic>;
    switch (m['t']) {
      case T.welcome:
        log('connected as ${m['userId']}');
        send({
          't': T.rideRequest,
          'pickup': {'name': 'MG Road', 'lat': pickup[0], 'lon': pickup[1]},
          'drop': {'name': 'Koramangala', 'lat': drop[0], 'lon': drop[1]},
          'mode': mode,
          'fareRupees': 180,
        });
        log('ride requested ($mode) — accept it on the phone');
      case T.rideUpdate:
        final r = m['ride'] as Map<String, dynamic>;
        rideId = r['id'] as String;
        log('ride ${r['state']} ${r['driver'] != null ? 'driver=${(r['driver'] as Map)['name']} lang=${(r['driver'] as Map)['lang']}' : ''} otp=${r['otp']}');
        if (r['state'] == 'ASSIGNED' && wantCall) {
          Timer(const Duration(seconds: 2), () {
            log('calling the driver…');
            send({'t': T.callStart, 'rideId': rideId});
          });
        }
      case T.callState:
        log('call: ${m['state']} ${m['reason'] ?? ''}');
        if (m['state'] == 'active' && say.isNotEmpty && !sentSay) {
          sentSay = true;
          Timer(const Duration(seconds: 2), () {
            log('sending utterance: $say');
            send({'t': T.chatUtterance, 'rideId': rideId, 'text': say, 'translated': sayTranslated, 'srcLang': lang, 'tgtLang': peerLang, 'seq': 1});
          });
        }
      case T.chatUtterance:
        log('UTTERANCE from ${m['fromRole']} [${m['srcLang']}→${m['tgtLang']}]: "${m['text']}"  =>  "${m['translated']}"');
      case T.error:
        log('ERROR ${m['code']}: ${m['message']}');
      case T.offerCancelled:
      case T.peerLocation:
        break;
      default:
        log('${m['t']}');
    }
  }, onDone: () => log('socket closed'));

  await Future<void>.delayed(Duration(seconds: seconds));
  if (rideId != null) {
    send({'t': T.callEnd, 'rideId': rideId});
    send({'t': T.rideCancel, 'rideId': rideId});
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  log('done. audio frames received from the phone: $audioIn');
  await ws.close();
  http.close(force: true);
  exit(0);
}
