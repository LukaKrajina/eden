import 'dart:async';
import 'package:eden/services/p2p_service.dart';
import 'package:flutter/material.dart';

class MatchReadyRoom extends StatefulWidget {
  final String matchID;
  final String modeTitle;
  final int requiredPlayers;
  final Function() onAllReady;
  final Function() onTimeout;
  final P2PService p2pService;

  const MatchReadyRoom({
    super.key,
    required this.matchID,
    required this.modeTitle,
    required this.requiredPlayers,
    required this.onAllReady,
    required this.onTimeout,
    required this.p2pService,
  });

  @override
  State<MatchReadyRoom> createState() => _MatchReadyRoomState();
}

class _MatchReadyRoomState extends State<MatchReadyRoom> {
  int _timeLeft = 120;
  Timer? _timer;
  bool _iAmReady = false;
  
  // Simulated roster for the UI. In a real scenario, you'd populate this 
  // by polling widget.p2pService.getMatchRoster(widget.matchID)
  List<Map<String, dynamic>> _roster = [];

  @override
  void initState() {
    super.initState();
    _initRoster();
    _startTimer();
    _pollNetworkReadiness();
  }

  void _initRoster() {
    for (int i = 0; i < widget.requiredPlayers; i++) {
      _roster.add({
        "id": "player_$i",
        "name": i == 0 ? "You" : "Waiting...",
        "isReady": false,
        "team": i < (widget.requiredPlayers / 2) ? "CT" : "T"
      });
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_timeLeft > 0) {
        setState(() => _timeLeft--);
      } else {
        timer.cancel();
        Navigator.pop(context);
        widget.onTimeout();
      }
    });
  }

  void _pollNetworkReadiness() {
    // Poll the blockchain/P2P layer every second to see who clicked ready
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _timeLeft <= 0) {
        timer.cancel();
        return;
      }
      // TODO: Fetch real-time ready states from the P2P network
      // Map<String, bool> readyStates = await widget.p2pService.getReadyStates(widget.matchID);
      
      // If everyone is ready:
      bool allReady = _roster.every((p) => p['isReady'] == true);
      if (allReady) {
        timer.cancel();
        Navigator.pop(context);
        widget.onAllReady();
      }
    });
  }

  void _markReady() {
    setState(() {
      _iAmReady = true;
      _roster[0]['isReady'] = true; // Mark self as ready visually
    });
    // Broadcast to the network
    // widget.p2pService.broadcastMatchReady(widget.matchID);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> teamCT = _roster.where((p) => p['team'] == 'CT').toList();
    List<Map<String, dynamic>> teamT = _roster.where((p) => p['team'] == 'T').toList();

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 900,
        height: 600,
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          border: Border.all(color: const Color(0xFFFF6600), width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              color: const Color(0xFF1F1F1F),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("MATCH FOUND - ${widget.modeTitle}", style: const TextStyle(color: Colors.white, fontSize: 24, fontFamily: "Oswald", fontWeight: FontWeight.bold)),
                  Text("0${_timeLeft ~/ 60}:${(_timeLeft % 60).toString().padLeft(2, '0')}", style: const TextStyle(color: Colors.redAccent, fontSize: 28, fontFamily: "monospace", fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            
            // Grid
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Row(
                  children: [
                    Expanded(child: _buildTeamColumn(teamCT, Colors.blueAccent)),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 40),
                      child: Text("VS", style: TextStyle(color: Colors.grey, fontSize: 32, fontFamily: "Oswald", fontStyle: FontStyle.italic)),
                    ),
                    
                    Expanded(child: _buildTeamColumn(teamT, Colors.orangeAccent)),
                  ],
                ),
              ),
            ),

            // Accept Button
            Container(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: 300,
                height: 60,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _iAmReady ? Colors.green : const Color(0xFFFF6600),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  onPressed: _iAmReady ? null : _markReady,
                  child: Text(
                    _iAmReady ? "WAITING FOR OTHERS..." : "ACCEPT",
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2, color: Colors.white),
                  ),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildTeamColumn(List<Map<String, dynamic>> team, Color teamColor) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: team.map((player) {
        bool isReady = player['isReady'];
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F1F),
            border: Border(left: BorderSide(color: isReady ? Colors.green : teamColor, width: 4)),
            boxShadow: isReady ? [const BoxShadow(color: Colors.green, blurRadius: 10, spreadRadius: -5)] : [],
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: isReady ? Colors.green.withOpacity(0.2) : Colors.grey[800],
                child: Icon(Icons.headset_mic, color: isReady ? Colors.green : Colors.white),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(player['name'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(
                      isReady ? "READY" : "CONNECTING...", 
                      style: TextStyle(color: isReady ? Colors.green : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}