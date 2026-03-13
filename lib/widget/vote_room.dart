/*
    Eden
    Copyright (C) 2026 LukaKrajina

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:eden/services/p2p_service.dart';

class VetoRoom extends StatefulWidget {
  final String matchID;
  final List<String> roster;
  final String myPeerID;
  final P2PService p2pService;
  final Function(String selectedMap) onVetoComplete;

  const VetoRoom({
    super.key,
    required this.matchID,
    required this.roster,
    required this.myPeerID,
    required this.p2pService,
    required this.onVetoComplete,
  });

  @override
  State<VetoRoom> createState() => _VetoRoomState();
}

class _VetoRoomState extends State<VetoRoom> {
  final List<String> _mapPool = [
    "de_dust2", "de_mirage", "de_inferno", "de_nuke", 
    "de_overpass", "de_vertigo", "de_ancient"
  ];
  
  List<String> _bannedMaps = [];
  Timer? _pollingTimer;
  bool _isLoadingCaptains = true;
  late String _captainA;
  late String _captainB;

  @override
  void initState() {
    super.initState();
    _captainA = widget.roster.first;
    _captainB = widget.roster.last;
    
    _assignCaptains();
    _startPolling();
  }

  Future<void> _assignCaptains() async {
    List<Map<String, dynamic>> stats = [];
    for (String p in widget.roster) {
      var profile = await widget.p2pService.getPeerProfile(p);
      stats.add({"id": p, "rating": profile["rating"] ?? 1000.0});
    }

    int half = widget.roster.length ~/ 2;
    List<Map<String, dynamic>> teamA = stats.sublist(0, half);
    List<Map<String, dynamic>> teamB = stats.sublist(half);

    teamA.sort((a, b) => b["rating"].compareTo(a["rating"]));
    teamB.sort((a, b) => b["rating"].compareTo(a["rating"]));

    setState(() {
      _captainA = teamA.first["id"];
      _captainB = teamB.first["id"];
      _isLoadingCaptains = false;
    });
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final bans = await widget.p2pService.getMatchVetoes(widget.matchID);
      
      if (mounted && bans.length != _bannedMaps.length) {
        setState(() => _bannedMaps = bans);

        if (_bannedMaps.length == _mapPool.length - 1) {
          timer.cancel();
          String finalMap = _mapPool.firstWhere((m) => !_bannedMaps.contains(m));
          
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              Navigator.pop(context);
              widget.onVetoComplete(finalMap);
            }
          });
        }
      }
    });
  }

  void _handleMapTap(String mapName) {
    if (_bannedMaps.contains(mapName)) return;

    int currentTurn = _bannedMaps.length;
    String activeCaptain = (currentTurn % 2 == 0) ? _captainA : _captainB;

    if (widget.myPeerID == activeCaptain) {
      widget.p2pService.broadcastMapVeto(widget.matchID, mapName);
      setState(() => _bannedMaps.add(mapName));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("It is not your turn to ban!"), backgroundColor: Colors.red),
      );
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    int currentTurn = _bannedMaps.length;
    bool isFinished = currentTurn == _mapPool.length - 1;
    String activeCaptain = (currentTurn % 2 == 0) ? _captainA : _captainB;
    bool isMyTurn = widget.myPeerID == activeCaptain && !isFinished;

    return Dialog(
      backgroundColor: const Color(0xFF121212),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFFF6600), width: 2),
      ),
      child: SizedBox(
        width: 900, height: 600,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              color: const Color(0xFF1F1F1F),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("MAP VETO PHASE", style: TextStyle(color: Colors.white, fontSize: 24, fontFamily: "Oswald", fontWeight: FontWeight.bold)),
                  Text(
                    isFinished ? "MAP SELECTED!" : (isMyTurn ? "YOUR TURN TO BAN" : "WAITING FOR CAPTAIN..."),
                    style: TextStyle(
                      color: isFinished ? Colors.green : (isMyTurn ? const Color(0xFFFF6600) : Colors.grey),
                      fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4, childAspectRatio: 1.5,
                    crossAxisSpacing: 16, mainAxisSpacing: 16,
                  ),
                  itemCount: _mapPool.length,
                  itemBuilder: (ctx, i) {
                    final mapName = _mapPool[i];
                    final isBanned = _bannedMaps.contains(mapName);
                    final isFinalMap = isFinished && !isBanned;

                    return GestureDetector(
                      onTap: () => _handleMapTap(mapName),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isBanned ? Colors.black54 : const Color(0xFF1F1F1F),
                          border: Border.all(
                            color: isFinalMap ? Colors.green : (isBanned ? Colors.red.withValues(alpha: 0.5) : const Color(0xFF333333)),
                            width: isFinalMap ? 4 : 1,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Text(
                              mapName.replaceAll("de_", "").toUpperCase(),
                              style: TextStyle(
                                color: isBanned ? Colors.grey : Colors.white,
                                fontSize: 20, fontFamily: "Oswald", fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (isBanned)
                              const Icon(Icons.block, color: Colors.red, size: 64),
                            if (isFinalMap)
                              const Icon(Icons.check_circle, color: Colors.green, size: 64),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}