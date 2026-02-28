import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class GameRunner {
  Process? _serverProcess;
  Process? _clientProcess;

  Future<void> startServer(
      String cs2Path,
      String virtualIP,
      String mapName,
      String gameType,
      String gameMode,
      String maxPlayers,
      String friendlyFire,
      bool recordDemo,
      int port) async {
    
    final serverExe = p.join(cs2Path, 'game', 'bin', 'win64', 'cs2.exe');
    
    final args = [
      '-dedicated',
      '-usercon',
      '-console',
      '+ip', virtualIP,
      '-port', port.toString(),
      '+map', mapName,
      '+game_type', gameType,
      '+game_mode', gameMode,
      '+maxplayers', maxPlayers,
      '+mp_friendlyfire', friendlyFire,
      '+sv_lan', '1', 
      '-nojoy'
    ];

    if (recordDemo) {
      args.addAll([
        '+tv_enable', '1',
        '+tv_autorecord', '1', 
        '+tv_delay', '0', 
      ]);
    }

    if (int.parse(maxPlayers) > 10) {
      args.addAll(['+sv_coaching_enabled', '1']);
    }

    print("[GameRunner] Starting Server at $virtualIP:$port");

    try {
      _serverProcess = await Process.start(
          serverExe, 
          args, 
          workingDirectory: p.dirname(serverExe),
          runInShell: true
      );

      // Listen to output for debugging
      if (kDebugMode) {
        _serverProcess!.stdout.transform(utf8.decoder).listen((data) {
           // Filter noisy logs if needed
           if (data.contains("SV:  Spawned End-of-Tick Server")) {
             print("[GameRunner] SERVER READY!");
           }
        });
      }
    } catch (e) {
      print("[GameRunner] Error: $e");
    }
  }

  Future<void> startClient(String cs2Path, String hostIP, String playerName) async {
    final clientExe = p.join(cs2Path, 'game', 'bin', 'win64', 'cs2.exe');
    
    final args = ['-console','-lowlatency', '-nojoy', '+connect', hostIP, '+name', playerName]; 

    print("[GameRunner] Connecting Client as $playerName to $hostIP...");
    
    // Windows Manual IP copy
    try {
      final clipProcess = await Process.start('clip', []);
      clipProcess.stdin.write(hostIP);
      await clipProcess.stdin.close();
      print("[GameRunner] Host IP ($hostIP) copied to clipboard.");
    } catch (e) {
    print("[GameRunner] Failed to copy to clipboard: $e");
  }

    try {
      _clientProcess = await Process.start(
        clientExe, 
        args, 
        workingDirectory: p.dirname(clientExe)
      );
    } catch (e) {
      print("[GameRunner] Client Error: $e");
    }
  }

  void stopServer() {
    if (_serverProcess != null) {
      print("[GameRunner] Stopping Server...");
      _serverProcess!.kill();
      // Force kill Windows process just in case
      Process.run('taskkill', ['/F', '/T', '/PID', '${_serverProcess!.pid}']);
      _serverProcess = null;
    }
  }

  void stopClient() {
    if (_clientProcess != null) {
      _clientProcess!.kill();
      _clientProcess = null;
    }
  }
}