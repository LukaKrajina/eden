import 'dart:async';
import 'package:flutter/material.dart';
import 'package:eden/services/p2p_service.dart';
import 'package:eden/localization/lgpkg.dart';

class MatchRosterDialog extends StatefulWidget {
  final String matchID;
  final String selectedModeTitle;
  final List<String> matchRoster;
  final String myPeerID;
  final Lgpkg lgpkgService;
  final P2PService p2pService;

  const MatchRosterDialog({
    super.key,
    required this.matchID,
    required this.selectedModeTitle,
    required this.matchRoster,
    required this.myPeerID,
    required this.lgpkgService,
    required this.p2pService,
  });

  @override
  State<MatchRosterDialog> createState() => _MatchRosterDialogState();
}

class _MatchRosterDialogState extends State<MatchRosterDialog> {
  int _scoreCT = 0;
  int _scoreT = 0;
  bool _hasMinedThisMatch = false;
  String _matchPhase = "";
  Timer? _gsiTimer;

  @override
  void initState() {
    super.initState();
    _startGsiPolling();
  }

  void _startGsiPolling() {
    _gsiTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final liveMatches = await widget.p2pService.getLiveMatches();
      
      for (var match in liveMatches) {
        if (match['match_id'] == widget.matchID) {
          if (mounted) {
            setState(() {
              _scoreCT = match['score_ct'] ?? 0;
              _scoreT = match['score_t'] ?? 0;
              
              String rawPhase = match['phase'] ?? "";
              if (rawPhase == "live") {
                _matchPhase = "MATCH LIVE";
              }
              else if (rawPhase == 'warmup') {
                _matchPhase = widget.lgpkgService.get("Warmup");
              }
              else if (rawPhase == 'intermission') {
                _matchPhase = widget.lgpkgService.get("HalfTime");
              } 
              else if (rawPhase == "gameover") {
                _matchPhase = "MATCH FINISHED";
                if (!_hasMinedThisMatch) {
                  _hasMinedThisMatch = true; 
                  
                  int duration = 1800; 
                  int players = widget.matchRoster.length;
                  widget.p2pService.submitMatchReward(duration, players);
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(widget.lgpkgService.get("MatchEndedMining")))
                  );
                }
              }
            });
          }
          break;
        }
      }
    });
  }

  @override
  void dispose() {
    _gsiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF121212),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFFF6600), width: 2),
      ),
      child: Container(
        width: 1000,
        height: 650,
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              "$_matchPhase - ${widget.selectedModeTitle}", 
              style: TextStyle(
                color: _matchPhase == "MATCH LIVE" ? Colors.green : Colors.white, 
                fontSize: 24, 
                fontFamily: "Oswald", 
                fontWeight: FontWeight.bold
              )
            ),
            const SizedBox(height: 24),
            Expanded(child: _buildDynamicPlayerGrid()),
            if (_matchPhase == "MATCH FINISHED") ...[
              const SizedBox(height: 24),
              SizedBox(
                width: 350,
                height: 60,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6600), 
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4)
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: Text(
                    "ReturnToLobby", 
                    style: const TextStyle(
                      fontSize: 18, 
                      fontWeight: FontWeight.bold, 
                      letterSpacing: 2, 
                      color: Colors.white
                    ),
                  ),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildDynamicPlayerGrid() {
    if (widget.selectedModeTitle == "DEATHMATCH") {
      return GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5, childAspectRatio: 2.5, crossAxisSpacing: 10, mainAxisSpacing: 10),
        itemCount: 16, 
        itemBuilder: (ctx, i) => _buildPlayerRow(i, true, compact: true),
      );
    } else if (widget.selectedModeTitle == "1V1 HUBS") {
      return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 200, child: _buildPlayerRow(0, true, scale: 1.2)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40), 
            child: Text(widget.lgpkgService.get("VS"), style: const TextStyle(fontSize: 40, color: Color(0xFFFF6600), fontFamily: "Oswald"))
          ),
          SizedBox(width: 200, child: _buildPlayerRow(1, false, scale: 1.2)),
      ]);
    } else if (widget.selectedModeTitle == "TOURNAMENTS") {
        return Row(children: [
            Expanded(child: Column(children: List.generate(6, (i) => _buildPlayerRow(i, true)))),
            const SizedBox(width: 24),
            Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(widget.lgpkgService.get("VS"), style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                "$_scoreCT  -  $_scoreT", 
                style: const TextStyle(color: Color(0xFFFF6600), fontSize: 32, fontWeight: FontWeight.bold)
              ),
            ]),
            const SizedBox(width: 24),
            Expanded(child: Column(children: List.generate(6, (i) => _buildPlayerRow(i, false)))),
        ]);
    } else {
      return Row(children: [
          Expanded(child: Column(children: List.generate(5, (i) => _buildPlayerRow(i, true)))),
          const SizedBox(width: 24),
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(widget.lgpkgService.get("VS"), style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(
              "$_scoreCT  -  $_scoreT", 
              style: const TextStyle(color: Color(0xFFFF6600), fontSize: 32, fontWeight: FontWeight.bold)
            ),
          ]),
          const SizedBox(width: 24),
          Expanded(child: Column(children: List.generate(5, (i) => _buildPlayerRow(i, false)))),
      ]);
    }
  }

  Widget _buildPlayerRow(int index, bool isMyTeam, {bool compact = false, double scale = 1.0}) {
    int rosterIndex = isMyTeam ? index : index + 5; 
    String playerID = rosterIndex < widget.matchRoster.length ? widget.matchRoster[rosterIndex] : "";
    bool isMe = playerID == widget.myPeerID;
    bool isOccupied = playerID.isNotEmpty;

    Widget content = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F), 
        border: Border(left: BorderSide(color: isMe ? const Color(0xFFFF6600) : Colors.transparent, width: 3))
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16, 
            backgroundColor: Colors.grey[800], 
            child: (!isOccupied) ? const Icon(Icons.person, size: 16, color: Colors.white30) : null
          ),
          const SizedBox(width: 12),
          if (!compact) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start, 
              mainAxisAlignment: MainAxisAlignment.center, 
              children: [
                Text(
                  isOccupied ? (isMe ? "You" : "Player ${playerID.substring(playerID.length - 4)}") : widget.lgpkgService.get("EmptySlot"), 
                  style: TextStyle(color: isOccupied ? Colors.white : Colors.white30, fontWeight: FontWeight.bold)
                ), 
              ]
            ),
            const Spacer(), 
            if (isOccupied) const Icon(Icons.videogame_asset, color: Colors.green, size: 16),
          ]
        ],
      ),
    );
    if (scale != 1.0) return Transform.scale(scale: scale, child: content);
    return content;
  }
}