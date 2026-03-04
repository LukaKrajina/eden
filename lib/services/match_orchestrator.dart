import 'dart:async';
import 'dart:math';
import 'package:eden/misc/mod_config_mapper.dart';
import 'package:eden/services/game_runner.dart';
import 'package:eden/services/gsi_server.dart';
import 'package:eden/services/p2p_service.dart';

class MatchOrchestrator {
  final GameRunner gameRunner;
  final GsiServer gsiServer;
  final P2PService p2pService;
  
  Timer? _warmupTimer;

  MatchOrchestrator(this.gameRunner, this.gsiServer, this.p2pService);

  Future<void> hostMatch(String gamePath,String gameVersion,String virtualIP,GameMode mode, String mapName, List<String> roster) async {
    final config = modeConfigurations[mode]!;
    final matchPassword = _generateRandomPassword();
    final matchID = "match_${DateTime.now().millisecondsSinceEpoch}";

    await gameRunner.startServer(
      gamePath, 
      gameVersion, 
      virtualIP,
      mapName, 
      config.gameType, 
      config.gameMode, 
      config.maxPlayers, 
      config.friendlyFire, 
      true, 
      27015,
      serverPassword: matchPassword
    );

    await p2pService.startHostedMatch(matchID, roster);

    _enforceWarmupDeadline(int.parse(config.maxPlayers));
  }

  void _enforceWarmupDeadline(int requiredPlayers) {
    _warmupTimer = Timer(const Duration(minutes: 5), () {
      print("[Orchestrator] Warmup time expired. Evaluating lobby...");
      
      if (gsiServer.currentPhase == "warmup" && gsiServer.currentLobbySize < requiredPlayers) {
        print("[Orchestrator] Lobby not full (${gsiServer.currentLobbySize}/$requiredPlayers). Aborting Match.");
        
        gameRunner.stopServer();
        
        // TODO: Broadcast an "ABORT_MATCH" transaction via P2PService here
      } else {
        print("[Orchestrator] Lobby full. Match proceeding to LIVE.");
      }
    });
  }

  String _generateRandomPassword() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random();
    return String.fromCharCodes(Iterable.generate(
        10, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }
}