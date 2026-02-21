import 'dart:async';
import 'package:flutter/material.dart';

// --- Data Model ---
class ProPlayer {
  final String name;
  final String team;
  final String imageUrl;
  final String role;
  // Config Data
  final String crosshairCode;
  final double sensitivity;
  final int dpi;
  final String resolution;
  final String scaling;
  final String monitorHz;
  final String viewmodel;

  ProPlayer({
    required this.name,
    required this.team,
    required this.imageUrl,
    required this.role,
    required this.crosshairCode,
    required this.sensitivity,
    required this.dpi,
    required this.resolution,
    required this.scaling,
    required this.monitorHz,
    required this.viewmodel,
  });

  // Generates a mock config file content based on real stats
  String get configContent => """
// $name CS2 Config (Auto-Generated from Cloud)
// Team: $team | Role: $role

unbindall
bind "w" "+forward"
bind "a" "+left"
bind "s" "+back"
bind "d" "+right"

// --- MOUSE SETTINGS ---
sensitivity "$sensitivity"
zoom_sensitivity_ratio "1.0"
m_yaw "0.022"
m_pitch "0.022"
// DPI: $dpi (Hardware set)

// --- VIDEO & HUD ---
// Res: $resolution ($scaling)
fps_max "999"
r_fullscreen_gamma "2.2"
cl_hud_color "1"
cl_showloadout "1"

// --- CROSSHAIR ---
apply_crosshair_code "$crosshairCode"

// --- VIEWMODEL ---
$viewmodel

// --- NETWORK ---
rate "786432"
cl_interp_ratio "1"
cl_interp "0.015625"

host_writeconfig
echo "Loaded $name Config Successfully"
""";
}

// --- Live Database (Synced 2026) ---
final List<ProPlayer> kProPlayers = [
  ProPlayer(
    name: "s1mple",
    team: "BC.Game",
    role: "AWPer",
    imageUrl: "https://prosettings.net/wp-content/uploads/s1mple-200x200-2x-fitcontain-q99-gb283-s1.webp",
    crosshairCode: "CSGO-E8xcE-27Lmw-2ipNt-3HZvp-pevvE", //
    sensitivity: 3.09, //
    dpi: 400, //
    resolution: "1280x960", //
    scaling: "Stretched",
    monitorHz: "540Hz",
    viewmodel: "viewmodel_fov 68; viewmodel_offset_x 2.5; viewmodel_offset_y 0; viewmodel_offset_z -1.5; viewmodel_presetpos 2;", //
  ),
  ProPlayer(
    name: "ZywOo",
    team: "Vitality",
    role: "AWPer",
    imageUrl: "https://prosettings.net/wp-content/uploads/zywoo-200x200-2x-fitcontain-q99-gb283-s1.webp",
    crosshairCode: "CSGO-Qzpx5-BRLw8-xFPCS-hTns4-GHDhP", //
    sensitivity: 2.00, //
    dpi: 400, //
    resolution: "1280x960", //
    scaling: "Stretched",
    monitorHz: "360Hz",
    viewmodel: "viewmodel_fov 68; viewmodel_offset_x 2.5; viewmodel_offset_y 0; viewmodel_offset_z -1.5; viewmodel_presetpos 2;",
  ),
  ProPlayer(
    name: "m0NESY",
    team: "Falcons",
    role: "AWPer",
    imageUrl: "https://prosettings.net/wp-content/uploads/m0nesy-200x200-2x-fitcontain-q99-gb283-s1.webp",
    crosshairCode: "CSGO-wAD3c-ykt5L-zvZ98-vBisR-6sWPA", //
    sensitivity: 2.30, //
    dpi: 400, //
    resolution: "1280x960", //
    scaling: "Stretched",
    monitorHz: "600Hz",
    viewmodel: "viewmodel_fov 68; viewmodel_offset_x 2.5; viewmodel_offset_y 0; viewmodel_offset_z -1.5; viewmodel_presetpos 3;",
  ),
  ProPlayer(
    name: "NiKo",
    team: "Falcons",
    role: "Rifler",
    imageUrl: "https://prosettings.net/wp-content/uploads/niko-200x200-2x-fitcontain-q99-gb283-s1.webp",
    crosshairCode: "CSGO-LfYUV-BtxVq-iAmCV-DpFQZ-5eRqJ", //
    sensitivity: 0.20, //
    dpi: 1600, //
    resolution: "1280x960", //
    scaling: "Stretched",
    monitorHz: "500Hz",
    viewmodel: "viewmodel_fov 68; viewmodel_offset_x 2; viewmodel_offset_y 0; viewmodel_offset_z -1.5; viewmodel_presetpos 0;",
  ),
  ProPlayer(
    name: "donk",
    team: "Spirit",
    role: "Rifler",
    imageUrl: "https://prosettings.net/wp-content/uploads/donk-200x200-2x-fitcontain-q99-gb283-s1.webp",
    crosshairCode: "CSGO-NmcdV-ORLFj-vKC4W-LV6zW-4fWjM", //
    sensitivity: 1.25, //
    dpi: 800, //
    resolution: "1280x960", //
    scaling: "Stretched",
    monitorHz: "600Hz",
    viewmodel: "viewmodel_fov 68; viewmodel_offset_x 2.5; viewmodel_offset_y 0; viewmodel_offset_z -1.5; viewmodel_presetpos 2;",
  ),
  ProPlayer(
    name: "ropz",
    team: "Vitality",
    role: "Lurker",
    imageUrl: "https://prosettings.net/wp-content/uploads/ropz-200x200-2x-fitcontain-q99-gb283-s1.webp",
    crosshairCode: "CSGO-MMQuh-Hs3Sj-Qv9zd-VaCmc-3QqNO", //
    sensitivity: 1.77, //
    dpi: 400, //
    resolution: "1920x1080", //
    scaling: "Native",
    monitorHz: "360Hz",
    viewmodel: "viewmodel_fov 68; viewmodel_offset_x 2.5; viewmodel_offset_y 0; viewmodel_offset_z -1.5; viewmodel_presetpos 2;",
  ),
];

// --- UI Widget ---
class ProSettingsGrid extends StatelessWidget {
  const ProSettingsGrid({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1000,
      height: 700,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text("PRO INTELLIGENCE", style: TextStyle(color: Colors.white, fontFamily: "Oswald", fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                  SizedBox(height: 8),
                  Text("Live Configuration Database • Season 2026", style: TextStyle(color: Colors.grey, fontSize: 14)),
                ],
              ),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 32),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.85,
                crossAxisSpacing: 24,
                mainAxisSpacing: 24,
              ),
              itemCount: kProPlayers.length,
              itemBuilder: (ctx, index) => _ProPlayerCard(player: kProPlayers[index]),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProPlayerCard extends StatefulWidget {
  final ProPlayer player;
  const _ProPlayerCard({required this.player});

  @override
  State<_ProPlayerCard> createState() => _ProPlayerCardState();
}

class _ProPlayerCardState extends State<_ProPlayerCard> {
  bool _isDownloading = false;

  void _triggerSecureView() async {
    setState(() => _isDownloading = true);

    // 1. Simulate Background Download
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;
    setState(() => _isDownloading = false);

    // 2. Open Ephemeral Pop-up
    _showConfigDialog();
  }

  void _showConfigDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        // Auto-close timer logic
        Timer(const Duration(seconds: 5), () {
          if (Navigator.canPop(ctx)) {
            Navigator.pop(ctx);
            // 4. "Delete" simulation log
            debugPrint("SECURE_VIEWER: Temporary file for ${widget.player.name} deleted.");
          }
        });

        return Dialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: Container(
            width: 500,
            height: 600,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock_clock, color: Color(0xFFFF5500), size: 20),
                    const SizedBox(width: 10),
                    const Text("SECURE CONFIG VIEWER", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    const Text("Auto-deleting in 5s...", style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ],
                ),
                const Divider(color: Color(0xFF333333), height: 30),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    color: Colors.black54,
                    child: SingleChildScrollView(
                      child: Text(
                        widget.player.configContent,
                        style: const TextStyle(color: Colors.greenAccent, fontFamily: "monospace", fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Avatar Section
          Expanded(
            flex: 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(widget.player.imageUrl, fit: BoxFit.cover, alignment: Alignment.topCenter),
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xFF1F1F1F)],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 10,
                  left: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.player.name, style: const TextStyle(color: Colors.white, fontSize: 28, fontFamily: "Oswald", fontWeight: FontWeight.bold)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        color: const Color(0xFFFF5500),
                        child: Text(widget.player.team, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Stats Section
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [_stat("DPI", "${widget.player.dpi}"), _stat("SENS", "${widget.player.sensitivity}")]),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [_stat("RES", widget.player.resolution), _stat("HZ", widget.player.monitorHz)]),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: ElevatedButton.icon(
                      icon: _isDownloading 
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.file_download, size: 16),
                      label: Text(_isDownloading ? "DOWNLOADING..." : "VIEW DETAILS", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF333333), foregroundColor: Colors.white),
                      onPressed: _isDownloading ? null : _triggerSecureView,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
        Text(value, style: const TextStyle(color: Color(0xFFFF5500), fontSize: 14, fontFamily: "Oswald")),
      ],
    );
  }
}