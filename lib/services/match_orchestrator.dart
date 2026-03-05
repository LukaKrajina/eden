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

  Future<void> hostMatch(String gamePath,
      String gameVersion,
      String virtualIP,
      GameMode mode, 
      String mapName, 
      List<String> roster,  
      bool recordDemo,
      int port
    ) async {
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
      recordDemo, 
      port,
      serverPassword: matchPassword
    );

    await p2pService.startHostedMatch(matchID, roster, matchPassword);

    _enforceWarmupDeadline(int.parse(config.maxPlayers), matchID);
  }

  void _enforceWarmupDeadline(int requiredPlayers, String matchID) {
    _warmupTimer = Timer(const Duration(minutes: 5), () async {
      print("[Orchestrator] Warmup time expired. Evaluating lobby...");
      
      if (gsiServer.currentPhase == "warmup" && gsiServer.currentLobbySize < requiredPlayers) {
        print("[Orchestrator] Lobby not full (${gsiServer.currentLobbySize}/$requiredPlayers). Aborting Match.");
        
        gameRunner.stopServer();
        
        await p2pService.abortMatch(matchID);

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

  Future<void> joinMatch(String gamePath, 
      String gameVersion,
      String matchID, 
      String hostPeerID, 
      String playerName
    ) async {
    print("[Match] Attempting to join match: $matchID");

    final password = await p2pService.getMatchPassword(matchID);

    if (password.isEmpty || password.startsWith("Error")) {
      print("[Match] Failed to retrieve or decrypt password. Are you on the roster?");
      return;
    }

    final hostIP = p2pService.getVirtualIPForPeer(hostPeerID);
    
    if (hostIP.isEmpty) {
      print("[Match] Could not resolve Host IP.");
      return;
    }

    await gameRunner.startClient(
      gamePath,
      gameVersion,
      hostIP,
      playerName,
      serverPassword: password
    );
    
    print("[Match] Client launched successfully.");
  }
}