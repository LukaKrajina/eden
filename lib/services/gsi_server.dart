import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'p2p_service.dart';

class GsiServer {
  String _currentPhase = "unknown";
  Function(Map<String, dynamic>)? onDataReceived;
  HttpServer? _server;
  DateTime? _matchStart;
  final Set<String> _uniquePlayers = {};
  bool _isMatchLive = false;
  final P2PService _p2p = P2PService();
  Function()? onMatchLive;

  Future<void> startServer() async {
    if (_server != null) await _server!.close(force: true);

    final app = Router();
    app.post('/gsi', (Request req) async {
      final payload = await req.readAsString();
      if (payload.isEmpty) return Response.ok('Empty');

      final data = jsonDecode(payload);
      onDataReceived?.call(data);
      _processGameData(data);
      
      return Response.ok('OK');
    });

    _server = await shelf_io.serve(app, InternetAddress.loopbackIPv4, 3000);
    print('[GSI] Listening on port 3000');
  }

  int get currentLobbySize => _uniquePlayers.length;
  String get currentPhase => _currentPhase;

  void _processGameData(Map<String, dynamic> data) {
    if (!data.containsKey('map')) return;

    final phase = data['map']['phase']?.toString() ?? 'unknown';
    _currentPhase = phase;

    if (phase == 'warmup' || phase == 'unknown') {
      if (_isMatchLive) {
        print("[GSI] Match aborted or restarted. Canceling current mining session.");
        _isMatchLive = false;
        _uniquePlayers.clear();
      }
      return;
    }

    if (phase == 'live' && !_isMatchLive) {
      print("[GSI] Match Started - Tracking for Mining...");
      _matchStart = DateTime.now();
      _isMatchLive = true;
      onMatchLive?.call();
    }

    if (_isMatchLive && data.containsKey('allplayers')) {
      _uniquePlayers.clear();
      (data['allplayers'] as Map).forEach((key, _) {
        _uniquePlayers.add(key);
      });
    }

    if (phase == 'gameover' && _isMatchLive) {
      _isMatchLive = false;
      
      final duration = DateTime.now().difference(_matchStart!).inSeconds;
      
      print("[GSI] Match Ended. Duration: ${duration}s. Witnesses: ${_uniquePlayers.length}");
      
      if (duration > 60) {
        _p2p.submitMatchReward(duration, _uniquePlayers.length).then((hash) {
           print("[Mining] Block Mined! Hash: $hash");
        });
      }
    }
  }
}