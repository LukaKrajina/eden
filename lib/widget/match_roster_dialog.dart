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
import 'package:eden/localization/lgpkg.dart';

class MatchRosterDialog extends StatefulWidget {
  final String matchID;
  final String selectedModeTitle;
  final List<String> matchRoster;
  final String myPeerID;
  final Lgpkg lgpkgService;
  final P2PService p2pService;
  final VoidCallback onReturnToLobby;

  const MatchRosterDialog({
    super.key,
    required this.matchID,
    required this.selectedModeTitle,
    required this.matchRoster,
    required this.myPeerID,
    required this.lgpkgService,
    required this.p2pService,
    required this.onReturnToLobby,
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

  Map<String, dynamic> _postMatchStats = {};
  Map<String, Map<String, dynamic>> _initialProfiles = {};
  Map<String, Map<String, dynamic>> _finalProfiles = {};

  @override
  void initState() {
    super.initState();
    _fetchInitialProfiles();
    _startGsiPolling();
  }

  Future<void> _fetchInitialProfiles() async {
    for (String peer in widget.matchRoster) {
      if (peer.isNotEmpty) {
        _initialProfiles[peer] = await widget.p2pService.getPeerProfile(peer);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _fetchFinalStats() async {
    await Future.delayed(const Duration(seconds: 5));
    
    _postMatchStats = await widget.p2pService.getMatchStats(widget.matchID);
    
    for (String peer in widget.matchRoster) {
      if (peer.isNotEmpty) {
        _finalProfiles[peer] = await widget.p2pService.getPeerProfile(peer);
      }
    }
    if (mounted) setState(() {});
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
                  _fetchFinalStats();
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
    bool isFinished = _matchPhase == "MATCH FINISHED";

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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (isFinished)
                  InkWell(
                    onTap: () {
                      widget.onReturnToLobby();
                      Navigator.pop(context);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F1F1F),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFFFF6600)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.arrow_back, color: Color(0xFFFF6600), size: 16),
                          const SizedBox(width: 8),
                          Text(
                            "RETURN", 
                            style: const TextStyle(color: Color(0xFFFF6600), fontWeight: FontWeight.bold)
                          ),
                        ],
                      ),
                    ),
                  )
                else 
                  const SizedBox(width: 120),

                Text(
                  "$_matchPhase - ${widget.selectedModeTitle}", 
                  style: TextStyle(
                    color: isFinished ? Colors.green : Colors.white, 
                    fontSize: 24, 
                    fontFamily: "Oswald", 
                    fontWeight: FontWeight.bold
                  )
                ),

                if (isFinished)
                   Container(
                     width: 120, 
                     padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                     decoration: BoxDecoration(
                       color: Colors.green.withValues(alpha: 0.1),
                       borderRadius: BorderRadius.circular(4),
                       border: Border.all(color: Colors.green)
                     ),
                     child: const Center(
                       child: Text("+ Mining EDN", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12)),
                     ),
                   )
                else 
                  const SizedBox(width: 120),
              ],
            ),
            
            const SizedBox(height: 24),
            
            Expanded(
              child: isFinished 
                  ? _buildPostMatchSummary()
                  : _buildDynamicPlayerGrid(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPostMatchSummary() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: const Color(0xFF1F1F1F),
          child: Row(
            children: [
              Expanded(flex: 3, child: Text(widget.lgpkgService.get("HeaderPlayer") ?? "PLAYER", style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text(widget.lgpkgService.get("HeaderKills") ?? "K", style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text(widget.lgpkgService.get("HeaderAssists") ?? "A", style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text(widget.lgpkgService.get("HeaderDeaths") ?? "D", style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text(widget.lgpkgService.get("HeaderRating") ?? "+/- RATING", style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              const Expanded(child: Text("XP GAIN", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.matchRoster.length,
            itemBuilder: (ctx, i) {
              String playerID = widget.matchRoster[i];
              if (playerID.isEmpty) return const SizedBox.shrink();
              
              bool isMe = playerID == widget.myPeerID;
              
              int kills = _postMatchStats[playerID]?['kills'] ?? 0;
              int assists = _postMatchStats[playerID]?['assists'] ?? 0;
              int deaths = _postMatchStats[playerID]?['deaths'] ?? 0;

              double initialRating = _initialProfiles[playerID]?['rating'] ?? 1500.0;
              double finalRating = _finalProfiles[playerID]?['rating'] ?? initialRating;
              double ratingChange = finalRating - initialRating;

              double initialXP = _initialProfiles[playerID]?['xp'] ?? 0.0;
              double finalXP = _finalProfiles[playerID]?['xp'] ?? initialXP;
              int xpGain = (finalXP - initialXP).round();
              
              bool ratingPositive = ratingChange > 0;

              return Container(
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF333333)))),
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3, 
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 12, 
                            backgroundColor: Colors.grey[800], 
                            child: const Icon(Icons.person, size: 12, color: Colors.white)
                          ),
                          const SizedBox(width: 10),
                          Text(
                            isMe ? "You" : "Player ${playerID.substring(playerID.length - 4)}", 
                            style: TextStyle(fontWeight: FontWeight.bold, color: isMe ? const Color(0xFFFF6600) : Colors.white)
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: Text("$kills", style: const TextStyle(color: Colors.white))),
                    Expanded(child: Text("$assists", style: const TextStyle(color: Colors.white))),
                    Expanded(child: Text("$deaths", style: const TextStyle(color: Colors.white))),
                    Expanded(
                      child: Text(
                        "${ratingPositive ? '+' : ''}${ratingChange.toStringAsFixed(1)}", 
                        style: TextStyle(
                          color: ratingPositive ? Colors.green : Colors.red, 
                          fontWeight: FontWeight.bold
                        )
                      )
                    ),
                    Expanded(
                      child: Text(
                        "+$xpGain XP", 
                        style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)
                      )
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
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