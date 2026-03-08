import 'dart:async';
import 'package:eden/services/p2p_service.dart';
import 'package:flutter/material.dart';

class MatchReadyRoom extends StatefulWidget {
  final String matchID;
  final String modeTitle;
  final int requiredPlayers;
  final List<String> rosterPeerIDs;
  final String myPeerID;
  final Function() onAllReady;
  final Function() onTimeout;
  final P2PService p2pService;

  const MatchReadyRoom({
    super.key,
    required this.matchID,
    required this.modeTitle,
    required this.requiredPlayers,
    required this.rosterPeerIDs,
    required this.myPeerID,
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
  List<Map<String, dynamic>> _rosterUI = [];

  @override
  void initState() {
    super.initState();
    _initRoster();
    _startTimer();
    _pollNetworkReadiness();
  }

  void _initRoster() {
    for (int i = 0; i < widget.requiredPlayers; i++) {
      String peerID = i < widget.rosterPeerIDs.length ? widget.rosterPeerIDs[i] : "slot_$i";
      bool isMe = peerID == widget.myPeerID;
      
      _rosterUI.add({
        "id": peerID,
        "name": isMe ? "You" : (peerID.startsWith("slot_") ? "Waiting..." : "Player ${peerID.substring(peerID.length - 4)}"),
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
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      Map<String, bool> readyStates = await widget.p2pService.getMatchReadyStates(widget.matchID);

      if (!mounted) {
        timer.cancel();
        return;
      }
      
      setState(() {
        for (var player in _rosterUI) {
          if (readyStates.containsKey(player['id']) && readyStates[player['id']] == true) {
            player['isReady'] = true;
          }
        }
      });

      bool allReady = _rosterUI.every((p) => p['isReady'] == true);
      if (_timeLeft <= 0 && !allReady) {
        timer.cancel();
        Navigator.pop(context);
        for (var p in _rosterUI) {
          if (p['isReady'] == false) {
            widget.p2pService.submitDodgePenalty(widget.matchID, p['id']);
            print("[Leaver Buster] Player failed to ready up. Submitting penalty for: ${p['id']}");
          }
        }

        widget.onTimeout();
        return;
      }

      if (allReady) {
        timer.cancel();
        Navigator.pop(context);
        widget.onAllReady();
      }
    });
  }

  void _markReady() {
    setState(() => _iAmReady = true);
    widget.p2pService.broadcastMatchReady(widget.matchID);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> teamCT = _rosterUI.where((p) => p['team'] == 'CT').toList();
    List<Map<String, dynamic>> teamT = _rosterUI.where((p) => p['team'] == 'T').toList();

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 1000,
        height: 650,
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          border: Border.all(color: const Color(0xFFFF6600), width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              color: const Color(0xFF1F1F1F),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("MATCH FOUND - ${widget.modeTitle}", style: const TextStyle(color: Colors.white, fontSize: 24, fontFamily: "Oswald", fontWeight: FontWeight.bold)),
                  Text("0${_timeLeft ~/ 60}:${(_timeLeft % 60).toString().padLeft(2, '0')}", style: const TextStyle(color: Colors.redAccent, fontSize: 32, fontFamily: "monospace", fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            
            // Player Cards Grid
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(30.0),
                child: Row(
                  children: [
                    Expanded(child: _buildTeamColumn(teamCT, const Color(0xFF5D79AE))),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 40),
                      child: Text("VS", style: TextStyle(color: Colors.grey, fontSize: 40, fontFamily: "Oswald", fontStyle: FontStyle.italic)),
                    ),
                    Expanded(child: _buildTeamColumn(teamT, const Color(0xFFDE9B35))),
                  ],
                ),
              ),
            ),

            // Accept Button Bottom Bar
            Container(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: 350,
                height: 70,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _iAmReady ? Colors.green : const Color(0xFFFF6600),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  onPressed: _iAmReady ? null : _markReady,
                  child: Text(
                    _iAmReady ? "WAITING FOR PLAYERS..." : "ACCEPT",
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 2, color: Colors.white),
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
                backgroundColor: isReady ? Colors.green.withValues(alpha: 0.2) : Colors.grey[800],
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
                      isReady ? "READY" : "WAITING", 
                      style: TextStyle(color: isReady ? Colors.green : Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                    ),
                  ],
                ),
              ),
              if (isReady) const Icon(Icons.check_circle, color: Colors.green),
            ],
          ),
        );
      }).toList(),
    );
  }
}