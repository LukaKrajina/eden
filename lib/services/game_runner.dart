import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class GameRunner {
  Process? _serverProcess;

  Future<void> startServer(
      String gamePath,
      String gameVersion,
      String virtualIP,
      String mapName,
      String gameType,
      String gameMode,
      String maxPlayers,
      String friendlyFire,
      bool recordDemo,
      int port,
      {String? serverPassword}
    ) async {
    
    String serverExe;
    if (gameVersion == "CS2") {
      serverExe = p.join(gamePath, 'game', 'bin', 'win64', 'cs2.exe');
    } else {
      serverExe = p.join(gamePath, 'srcds.exe');
    }
    
    final args = [
      if (gameVersion != "CS2") ...['-game', 'csgo'],
      '-dedicated',
      '-insecure',
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
      '-nojoy',
      '+mp_warmuptime', '300',
      '+mp_join_grace_time', '0'
    ];

    if (recordDemo) {
      args.addAll([
        '+tv_enable', '1',
        '+tv_autorecord', '1', 
        '+tv_delay', '0', 
      ]);
    }

    if (serverPassword != null && serverPassword.isNotEmpty) {
      args.addAll(['+sv_password', serverPassword]);
    }
    
    if (int.parse(maxPlayers) > 10 && int.parse(maxPlayers) <= 12) {
      args.addAll(['+sv_coaching_enabled', '1']);
    }

    print("[GameRunner] Starting $gameVersion Server at $virtualIP:$port");

    try {
      _serverProcess = await Process.start(
          serverExe, 
          args, 
          workingDirectory: p.dirname(serverExe),
          runInShell: true
      );

      if (kDebugMode) {
        _serverProcess!.stdout.transform(utf8.decoder).listen((data) {
           if (data.contains("SV:  Spawned End-of-Tick Server")) {
             print("[GameRunner] SERVER READY!");
           }
        });
      }
    } catch (e) {
      print("[GameRunner] Error: $e");
    }
  }

  Future<void> startClient(String gamePath, 
    String gameVersion, 
    String hostIP, 
    String playerName,  
    {String? serverPassword}
  ) async {
    String clientExe;
    if (gameVersion == "CS2") {
      clientExe = "730";
    } else {
      clientExe = "745";
    }


    String steamUri = 'steam://run/$clientExe//-console -lowlatency -nojoy +connect $hostIP +name "$playerName"';

    String sanitizedPassword = serverPassword!.replaceAll('"', '');
    if (sanitizedPassword.isNotEmpty) {
      steamUri += ' +password "$sanitizedPassword"';
    }

    print("[GameRunner] Connecting $gameVersion Client as $playerName to $hostIP...");
    
    try {
      final clipProcess = await Process.start('clip', []);
      clipProcess.stdin.write(hostIP);
      await clipProcess.stdin.close();
      print("[GameRunner] Host IP ($hostIP) copied to clipboard.");
    } catch (e) {
    print("[GameRunner] Failed to copy to clipboard: $e");
  }

    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', steamUri]);
      } else {
        await Process.run('xdg-open', [steamUri]); 
      }
    } catch (e) {
      print("[GameRunner] Client Error: $e");
    }
  }

  void stopServer() {
    if (_serverProcess != null) {
      print("[GameRunner] Stopping Server...");
      _serverProcess!.kill();
      Process.run('taskkill', ['/F', '/T', '/PID', '${_serverProcess!.pid}']);
      _serverProcess = null;
    }
  }

  void stopClient(String gameVersion) {
    if (Platform.isWindows) {
      if (gameVersion == "CS2") {
        Process.run('taskkill', ['/F', '/T', '/IM', 'cs2.exe']);
      } else {
        Process.run('taskkill', ['/F', '/T', '/IM', 'csgo.exe']);
      }
    }
  }
}