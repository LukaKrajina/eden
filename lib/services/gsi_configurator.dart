import 'dart:io';
import 'package:eden/services/p2p_service.dart';
import 'package:path/path.dart' as p;

class GsiConfigurator {
static const String _gsiContent = '''
"EdenGSI"
{
 "uri" "http://127.0.0.1:3000/gsi"
 "timeout" "1.1"
 "buffer"  "0.1"
 "throttle" "0.5"
 "heartbeat" "30.0"
 "auth"
  {
    "token" "%s"
  }
 "data"
 {
   "provider"            "1"
   "map"                 "1"
   "round"               "1"
   "player_id"           "1"
   "player_state"        "1"
   "allplayers_id"       "1"     
   "allplayers_state"    "1"
   "allplayers_match_stats"  "1"
 }
}
''';

  Future<bool> setupGsi(String cs2Path,P2PService _p2p) async {
    if (cs2Path.isEmpty) return false;

    String token = await _p2p.getGsiToken();

    if (token.isEmpty || token == "Offline" || token.startsWith("Error")) {
      print("[Config] Error: Could not fetch valid GSI Token.");
      return false;
    }

    final finalConfigContent = _gsiContent.replaceFirst('%s', token);

    final cfgDir = Directory(p.join(cs2Path, 'game', 'csgo', 'cfg'));
    if (!await cfgDir.exists()) {
      print("[Config] Error: CFG directory not found.");
      return false;
    }

    try {
      final file = File(p.join(cfgDir.path, "gamestate_integration_eden.cfg"));
      await file.writeAsString(finalConfigContent);
      print("[Config] GSI Installed.");
      return true;
    } catch (e) {
      print("[Config] Write Error: $e");
      return false;
    }
  }
}