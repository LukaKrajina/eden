import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'misc/pro_player_grid.dart';
import 'package:eden/services/gsi_configurator.dart';
import 'localization/lgpkg.dart';
import 'services/steam_service.dart';
import 'services/game_runner.dart';
import 'services/gsi_server.dart';
import 'services/p2p_service.dart';

const Color kFaceitDarkBg = Color(0xFF121212);
const Color kFaceitSurface = Color(0xFF1F1F1F);
const Color kFaceitOrange = Color(0xFFFF5500);
const Color kFaceitText = Color(0xFFEEEEEE);
const Color kFaceitTextDim = Color(0xFFAAAAAA);
const Color kFaceitBorder = Color(0xFF333333);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final steam = SteamService();
  await steam.init();

  final p2p = P2PService();
  final gsi = GsiServer();
  gsi.startServer();

  runApp(MyApp(
    steam: steam, 
    gsiServer: gsi,
    p2pService: p2p,
  ));
}

class MyApp extends StatelessWidget {
  final SteamService steam;
  final GsiServer gsiServer;
  final P2PService p2pService;

  const MyApp({
    super.key, 
    required this.steam, 
    required this.gsiServer,
    required this.p2pService, 
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EDEN Client',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kFaceitDarkBg,
        primaryColor: kFaceitOrange,
        cardColor: kFaceitSurface,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: kFaceitText, fontFamily: 'Roboto'),
          titleLarge: TextStyle(color: kFaceitText, fontFamily: 'Oswald', fontWeight: FontWeight.bold),
        ),
        colorScheme: const ColorScheme.dark(
          primary: kFaceitOrange,
          surface: kFaceitSurface,
        ),
      ),
      home: ServerControlPanel(
        steam: steam, 
        gsiServer: gsiServer, 
        p2pService: p2pService, 
      ),
    );
  }
}

// --- Data Models ---
class Friend {
  final String name;
  final String peerID;
  final String level;
  final int skillScore;
  double edn; 
  
  Friend({required this.name, required this.peerID, this.level = "1", this.skillScore = 1000, this.edn = 0.0});
}

class ServerControlPanel extends StatefulWidget {
  final SteamService steam;
  final GsiServer gsiServer;
  final P2PService p2pService;

  const ServerControlPanel({
    super.key,
    required this.steam, 
    required this.gsiServer, 
    required this.p2pService, 
  });

  @override
  State<ServerControlPanel> createState() => _ServerControlPanelState();
}

class _ServerControlPanelState extends State<ServerControlPanel> {
  final Lgpkg _lgpkg = Lgpkg();
  final GameRunner _runner = GameRunner();
  final GsiConfigurator _configurator = GsiConfigurator();

  // Controllers
  final TextEditingController _joinController = TextEditingController();
  final TextEditingController _cs2PathController = TextEditingController();
  final TextEditingController _friendCodeController = TextEditingController();
  late TextEditingController _nameController;

  // State
  Timer? _refreshTimer;
  Timer? _scoreTimer;
  String _myPeerID = "";
  String _cs2Path = ""; 
  String _status = "WAITING FOR ACTION";
  String _level = "10";
  String _score = "CT 0 - 0 T";
  
  bool _isSearching = false;
  bool _isEngineRunning = false;
  bool _isCompanionVisible = false;
  int _currentView = 0;
  bool _hasMinedThisMatch = false;
  
  // Game Config State
  String _selectedModeTitle = "MATCHMAKING"; 
  String _selectedGameType = "0";
  String _selectedGameMode = "1";
  String _maxPlayers = "10";
  String _isFriendlyFire = '0';
  bool _recordDemo = true;
  
  String _selectedMap = "de_dust2";
  File? _avatarImage;

  // Friends Data
  final List<Friend> _friends = [];

  final List<String> _maps = [
    "de_dust2", "de_mirage", "de_inferno", "de_nuke", 
    "de_overpass", "de_vertigo", "de_ancient", "de_anubis"
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.steam.getPlayerName());

    _scoreAcquirer();
    _scoreTimer = Timer.periodic(const Duration(seconds: 1), (_) => _scoreAcquirer());

    _setGameMode("MATCHMAKING");

    _friends.add(Friend(name: "TestPlayer", peerID: "QmHashTest123", level: "8", skillScore: 2100, edn: 50.0));
  }

  @override
  void dispose() {
    _scoreTimer?.cancel();
    if(_refreshTimer!.isActive){
      _refreshTimer?.cancel();
    }
    _joinController.dispose();
    _cs2PathController.dispose();
    _friendCodeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _scoreAcquirer() async {
    widget.gsiServer.onDataReceived = (data) {
      if (!mounted) return;

      if (data.containsKey('map')) {
        final mapData = data['map'];
        
        int ctScore = 0;
        int tScore = 0;
        String phase = mapData['phase'] ?? 'unknown';

        if (mapData['team_ct'] != null && mapData['team_ct']['score'] != null) {
          ctScore = mapData['team_ct']['score'];
        }

        if (mapData['team_t'] != null && mapData['team_t']['score'] != null) {
          tScore = mapData['team_t']['score'];
        }

        setState(() {
          if (phase == 'warmup') {
            _score = "WARMUP";
          } else if (phase == 'intermission') {
            _score = "HALF TIME";
          } else if (phase == 'gameover') {
            _score = "FINAL: CT $ctScore - $tScore T";
            if (!_hasMinedThisMatch) {
               _hasMinedThisMatch = true; 
               
               int duration = 1800; 
               int players = int.parse(_maxPlayers);
               
               widget.p2pService.submitMatchReward(duration, players);
               
               ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Match Ended. Mining Block..."))
               );
            }
          } else {
            _score = "CT $ctScore - $tScore T";
          }
        });
      }
    };
  }

  Future<void> _fetchPeerID() async {
    if (_myPeerID.isEmpty || _myPeerID == "Offline") {
      String id = await widget.p2pService.getMyID();
      setState(() => _myPeerID = id);
    }
  }

  // --- Friend & Trade Logic ---

  void _addFriend() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: kFaceitSurface,
      title: const Text("ADD FRIEND", style: TextStyle(color: kFaceitOrange, fontFamily: "Oswald")),
      content: TextField(
        controller: _friendCodeController,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(labelText: "Enter Friend Code / Peer ID", hintText: "Qm..."),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCEL")),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
          onPressed: () {
            if (_friendCodeController.text.isNotEmpty) {
              setState(() {
                _friends.add(Friend(
                  name: "New Friend", 
                  peerID: _friendCodeController.text,
                  level: "1"
                ));
              });
              _friendCodeController.clear();
              Navigator.pop(ctx);
            }
          }, 
          child: const Text("ADD")
        ),
      ],
    ));
  }

  void _inviteFriend(Friend f) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("Invited ${f.name} to Lobby"),
      backgroundColor: Colors.green,
    ));
  }

  void _openTradeInterface(Friend f) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => TradeOverlay(
        me: _nameController.text,
        myPeerID: _myPeerID,
        myAvatar: _avatarImage,
        friend: f,
        p2pService: widget.p2pService,
      )
    );
  }

  // --- Profile & Wallet Logic ---

  String _getFriendCode() {
    if (_myPeerID.length < 6) return "LOADING";
    return _myPeerID.substring(_myPeerID.length - 6).toUpperCase();
  }

  Future<bool> _deductFunds(double amount, String actionName) async {
    double balance = await widget.p2pService.getBalance(_myPeerID);
    if (balance < amount) {
      _showErrorDialog("INSUFFICIENT FUNDS", "You need $amount EDN to $actionName. Current: ${balance.toStringAsFixed(2)} EDN");
      return false;
    }
    
    // Simple burn for MVP
    bool success = await widget.p2pService.sendEdenCoin(_myPeerID, "SYSTEM_BURN_ADDRESS", amount);
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$amount EDN deducted for $actionName"), backgroundColor: kFaceitOrange));
      setState(() {}); 
    } else {
      _showErrorDialog("TRANSACTION FAILED", "Could not process deduction.");
    }
    return success;
  }

  Future<void> _editProfileName() async {
    TextEditingController tempController = TextEditingController(text: _nameController.text);
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: kFaceitSurface,
      title: const Text("CHANGE IDENTITY", style: TextStyle(color: kFaceitOrange, fontFamily: "Oswald")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Changing your platform alias costs 10 EDN.", style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 10),
          TextField(controller: tempController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: "New Alias")),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCEL")),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
          onPressed: () async {
            if (await _deductFunds(10.0, "Change Name")) {
              setState(() => _nameController.text = tempController.text);
              Navigator.pop(ctx);
            }
          }, 
          child: const Text("PAY 10 EDN")
        ),
      ],
    ));
  }

  Future<void> _pickAvatar() async {
    if (await _deductFunds(10.0, "Change Avatar")) {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.gallery);
      if (pickedFile != null) setState(() => _avatarImage = File(pickedFile.path));
    }
  }

  void _showProfileCard() {
     showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 350,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: kFaceitSurface,
              border: Border.all(color: kFaceitOrange, width: 2),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [BoxShadow(color: kFaceitOrange.withOpacity(0.2), blurRadius: 20)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () { Navigator.pop(ctx); _pickAvatar(); },
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircleAvatar(
                        radius: 50,
                        backgroundColor: Colors.grey[800],
                        backgroundImage: _avatarImage != null ? FileImage(_avatarImage!) : null,
                        child: _avatarImage == null ? const Icon(Icons.person, size: 50, color: Colors.white) : null,
                      ),
                      Container(
                        width: 100, height: 100,
                        alignment: Alignment.bottomCenter,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withOpacity(0.3)),
                        child: const Padding(padding: EdgeInsets.only(bottom: 10), child: Icon(Icons.edit, color: Colors.white70, size: 20)),
                      )
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onDoubleTap: () { Navigator.pop(ctx); _editProfileName(); },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_nameController.text, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, fontFamily: "Oswald", color: Colors.white)),
                      const SizedBox(width: 8),
                      const Icon(Icons.edit, size: 14, color: Colors.grey),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: kFaceitOrange, borderRadius: BorderRadius.circular(4)),
                  child: Text("LEVEL $_level", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white)),
                ),
                const Divider(color: kFaceitBorder, height: 30),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildProfileInfoItem("FRIEND CODE", _getFriendCode()),
                    _buildProfileInfoItem("PEER ID", _myPeerID.length > 8 ? "${_myPeerID.substring(0,8)}..." : _myPeerID),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.grey)),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("CLOSE", style: TextStyle(color: Colors.white)),
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileInfoItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: kFaceitTextDim, fontSize: 10, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        SelectableText(value, style: const TextStyle(color: kFaceitOrange, fontSize: 16, fontFamily: "monospace", fontWeight: FontWeight.bold)),
      ],
    );
  }

  // --- Game Config Logic ---

  void _setGameMode(String mode) {
    setState(() {
      _selectedModeTitle = mode;
      switch (mode) {
        case "MATCHMAKING":
          _selectedGameType = "0";
          _selectedGameMode = "1";
          _maxPlayers = "10";
          _isFriendlyFire = '0';
          _recordDemo = true;
          break;
        case "TOURNAMENTS":
          _selectedGameType = "0";
          _selectedGameMode = "1";
          _maxPlayers = "12";
          _isFriendlyFire = '1';
          _recordDemo = true;
          break;
        case "DEATHMATCH":
          _selectedGameType = "1";
          _selectedGameMode = "2";
          _maxPlayers = "16";
          _isFriendlyFire = '1';
          _recordDemo = false;
          break;
        case "1V1 HUBS":
          _selectedGameType = "0";
          _selectedGameMode = "0";
          _maxPlayers = "2";
          _isFriendlyFire = '0';
          _recordDemo = false;
          break;
      }
    });
  }

  // --- Core Engine Logic ---

  Future<void> _launchAntiCheatEngine() async {
    widget.p2pService.start();
    
    await Future.delayed(const Duration(seconds: 10));

    await _fetchPeerID();
    
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _fetchPeerID());
  }

  void _handleShieldClick() async {
    if (!_isEngineRunning) {
      setState(() => _status = "INITIALIZING AC...");
      await _launchAntiCheatEngine();
      setState(() {
        _isEngineRunning = true;
        _isCompanionVisible = true;
        _status = "ANTI-CHEAT ACTIVE";
      });
    } else {
      setState(() => _isCompanionVisible = !_isCompanionVisible);
    }
  }

  void _toggleMatching() {
    if (_isSearching) {
      setState(() {
        _isSearching = false;
        _status = "MATCH CANCELLED";
      });
      _runner.stopClient();
      _runner.stopServer();
    } else {
      _hostMatch();
    }
  }

  Future<void> _hostMatch() async {
    if (await _configurator.setupGsi(_cs2Path) == false) {
      _showErrorDialog("CONFIG ERROR", "Could not write GSI config.");
      return;
    }
    
    if (!_isEngineRunning) {
      _showErrorDialog("ANTI-CHEAT REQUIRED", "Active Shield required to host games.");
      return;
    }

    setState(() {
      _isSearching = true;
      _status = "SEARCHING FOR MATCH...";
    });

    String matchResult = await widget.p2pService.findMatch();
    
    if (!mounted || !_isSearching) return;

    if (matchResult.isNotEmpty && !matchResult.contains("Error")) {
       setState(() {
        _isSearching = false;
        _status = "MATCH FOUND!";
      });
      
      String hostIP = widget.p2pService.getVirtualIPForPeer(matchResult);
      widget.p2pService.connectToPeer(matchResult);
      await Future.delayed(const Duration(seconds: 3));
      await _runner.startClient(_cs2Path, hostIP, _nameController.text);
    }
  }

  void _createMatch() async {
    if (!_isSearching) {
      if (await _configurator.setupGsi(_cs2Path) == false) return;
      if (!_isEngineRunning) {
        _showErrorDialog("ANTI-CHEAT REQUIRED", "You must enable the Eden Anti-Cheat shield.");
        return;
      }

      setState(() => _status = "STARTING SERVER ($_selectedModeTitle)...");
      
      await _runner.startServer(
        _cs2Path, 
        "0.0.0.0", 
        _selectedMap, 
        _selectedGameType, 
        _selectedGameMode, 
        _maxPlayers, 
        _isFriendlyFire,
        _recordDemo,
        27015
      );
      
      setState(() => _status = "SERVER ONLINE (WAITING)");
    }
  }

  void _joinGame() async {
    String targetID = _joinController.text.trim();
    if (targetID.isEmpty) return;
    String hostIP = widget.p2pService.getVirtualIPForPeer(targetID);
    widget.p2pService.connectToPeer(targetID);
    await _runner.startClient(_cs2Path, hostIP, _nameController.text);
  }

  // --- UI Layout ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kFaceitDarkBg,
      body: Stack(
        children: [
          Row(
            children: [
              _buildSidebar(),
              Expanded(
                child: Column(
                  children: [
                    _buildTopHeader(),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: _currentView == 1
                          ? _buildFriendList()
                          : _currentView == 2
                              ? const ProSettingsGrid() 
                              : Row( 
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(flex: 3, child: _buildMatchLobby()),
                                    const SizedBox(width: 24),
                                    Expanded(flex: 1, child: _buildRightPanel()),
                                  ],
                                ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_isCompanionVisible)
            CompanionWindow(
              p2pService: widget.p2pService,
              onMinimize: () => setState(() => _isCompanionVisible = false),
            ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 70, color: kFaceitSurface,
      child: Column(
        children: [
          const SizedBox(height: 20),
          const Icon(Icons.shield_moon, color: kFaceitOrange, size: 32),
          const SizedBox(height: 30),
          _buildSideIcon(Icons.sports_esports, _currentView == 0, onTap: () => setState(() => _currentView = 0,)),
          _buildSideIcon(Icons.people, _currentView == 1, onTap: () => setState(() => _currentView = 1)),
          _buildSideIcon(Icons.bar_chart, false),
          _buildSideIcon(Icons.people, _currentView == 2, onTap: () => setState(() => _currentView = 2)),
          const Spacer(),
          _buildSideIcon(Icons.settings, false, onTap: _showSettingsWindow),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildSideIcon(IconData icon, bool isActive, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 60, width: 70,
        decoration: BoxDecoration(border: isActive ? const Border(left: BorderSide(color: kFaceitOrange, width: 3)) : null),
        child: Icon(icon, color: isActive ? kFaceitText : kFaceitTextDim, size: 24),
      ),
    );
  }

  Widget _buildTopHeader() {
    String title = "PLAY";
    if (_currentView == 0) title = "Play";
    if (_currentView == 1) title = "Social";
    if (_currentView == 2) title = "PRO Config";

    return Container(
      height: 80, padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(color: kFaceitSurface, border: Border(bottom: BorderSide(color: kFaceitBorder))),
      child: Row(
        children: [
          Text(title, style: const TextStyle(color: kFaceitText, fontSize: 20, fontWeight: FontWeight.bold, fontFamily: "Oswald")),
          const SizedBox(width: 40),
          
          if (_currentView == 0) ...[
            _buildHeaderTab("MATCHMAKING", _selectedModeTitle == "MATCHMAKING"),
            _buildHeaderTab("TOURNAMENTS", _selectedModeTitle == "TOURNAMENTS"),
            _buildHeaderTab("DEATHMATCH", _selectedModeTitle == "DEATHMATCH"),
            _buildHeaderTab("1V1 HUBS", _selectedModeTitle == "1V1 HUBS"),
          ],
          
          const Spacer(),
          
          InkWell(
            onTap: _handleShieldClick,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _isEngineRunning ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _isEngineRunning ? Colors.green : Colors.red),
              ),
              child: Row(
                children: [
                  Icon(Icons.verified_user, size: 16, color: _isEngineRunning ? Colors.green : Colors.red),
                  const SizedBox(width: 8),
                  Text("ANTI-CHEAT", style: TextStyle(color: _isEngineRunning ? Colors.green : Colors.red, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 15),
          
          // Updated Wallet Button
          IconButton(
            icon: const Icon(Icons.account_balance_wallet, color: kFaceitTextDim), 
            onPressed: () => showDialog(
              context: context, 
              builder: (ctx) => WalletWindow(p2pService: widget.p2pService, myPeerID: _myPeerID)
            ),
          ),
          const SizedBox(width: 15),
          
          InkWell(
            onTap: _showProfileCard,
            child: CircleAvatar(
              radius: 18, backgroundColor: Colors.grey[800],
              backgroundImage: _avatarImage != null ? FileImage(_avatarImage!) : null,
              child: _avatarImage == null ? const Icon(Icons.person, size: 18, color: kFaceitText) : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderTab(String title, bool isActive) {
    return InkWell(
      onTap: () => _setGameMode(title), 
      child: Container(
        margin: const EdgeInsets.only(right: 30),
        padding: const EdgeInsets.symmetric(vertical: 26),
        decoration: BoxDecoration(border: isActive ? const Border(bottom: BorderSide(color: kFaceitOrange, width: 3)) : null),
        child: Text(title, style: TextStyle(color: isActive ? kFaceitOrange : kFaceitTextDim, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
      ),
    );
  }

  Widget _buildFriendList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("FRIENDS LIST", style: TextStyle(color: kFaceitTextDim, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
              icon: const Icon(Icons.person_add),
              label: const Text("ADD FRIEND"),
              onPressed: _addFriend,
            )
          ],
        ),
        const SizedBox(height: 20),
        Expanded(
          child: _friends.isEmpty 
          ? Center(child: Text("No friends yet. Add one using their Peer ID.", style: TextStyle(color: kFaceitTextDim)))
          : ListView.builder(
              itemCount: _friends.length,
              itemBuilder: (ctx, i) {
                final friend = _friends[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: kFaceitSurface,
                    border: Border.all(color: kFaceitBorder),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(radius: 24, backgroundColor: Colors.grey[800], child: const Icon(Icons.person, color: Colors.white)),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(friend.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(color: kFaceitOrange, borderRadius: BorderRadius.circular(2)),
                                child: Text("LVL ${friend.level}", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                              ),
                              const SizedBox(width: 8),
                              Text("Skill: ${friend.skillScore}", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                              const SizedBox(width: 8),
                              Text("${friend.edn} EDN", style: const TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                            ],
                          )
                        ],
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () => _inviteFriend(friend),
                        child: const Text("INVITE"),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700]),
                        onPressed: () => _openTradeInterface(friend),
                        child: const Text("TRADE"),
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

  Widget _buildMatchLobby() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity, height: 180,
          decoration: BoxDecoration(
            image: const DecorationImage(
              image: NetworkImage("https://cdn.akamai.steamstatic.com/apps/csgo/images/csgo_react//cs2/header_ctt.png"),
              fit: BoxFit.cover,
              colorFilter: ColorFilter.mode(Colors.black54, BlendMode.darken),
            ),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: kFaceitBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), color: kFaceitOrange, child: Text(_isSearching ? "SEARCHING" : "LOBBY", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white))),
                const SizedBox(height: 8),
                Text(_selectedMap.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 40, fontFamily: "Oswald", fontWeight: FontWeight.bold)),
                Text(_status, style: const TextStyle(color: Colors.white70, letterSpacing: 1.5)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text("TEAM ROSTER", style: TextStyle(color: kFaceitTextDim, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 10),
        Expanded(child: _buildDynamicPlayerGrid()),
      ],
    );
  }

  Widget _buildDynamicPlayerGrid() {
    if (_selectedModeTitle == "DEATHMATCH") {
      return GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 5, childAspectRatio: 2.5, crossAxisSpacing: 10, mainAxisSpacing: 10),
        itemCount: 16, itemBuilder: (ctx, i) => _buildPlayerRow(i, true, compact: true),
      );
    } else if (_selectedModeTitle == "1V1 HUBS") {
      return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 200, child: _buildPlayerRow(0, true, scale: 1.2)),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 40), child: Text("VS", style: TextStyle(fontSize: 40, color: kFaceitOrange, fontFamily: "Oswald"))),
          SizedBox(width: 200, child: _buildPlayerRow(1, false, scale: 1.2)),
      ]);
    } else {
      return Row(children: [
          Expanded(child: Column(children: List.generate(5, (i) => _buildPlayerRow(i, true)))),
          const SizedBox(width: 24),
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text("VS", style: TextStyle(color: kFaceitTextDim.withOpacity(0.3), fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(_score, style: const TextStyle(color: kFaceitOrange, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(width: 24),
          Expanded(child: Column(children: List.generate(5, (i) => _buildPlayerRow(i, false)))),
      ]);
    }
  }

  Widget _buildPlayerRow(int index, bool isMyTeam, {bool compact = false, double scale = 1.0}) {
    bool isMe = isMyTeam && index == 0;
    Widget content = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: kFaceitSurface, border: Border(left: BorderSide(color: isMe ? kFaceitOrange : Colors.transparent, width: 3))),
      child: Row(
        children: [
          CircleAvatar(radius: 16, backgroundColor: Colors.grey[800], backgroundImage: (isMe && _avatarImage != null) ? FileImage(_avatarImage!) : null, child: (isMe && _avatarImage == null) ? const Icon(Icons.person, size: 16) : null),
          const SizedBox(width: 12),
          if (!compact) ...[
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [Text(isMe ? _nameController.text : "Empty Slot", style: TextStyle(color: isMe ? Colors.white : kFaceitTextDim, fontWeight: FontWeight.bold)), if (isMe) Text("Lvl $_level", style: const TextStyle(color: kFaceitOrange, fontSize: 10))]),
            const Spacer(), if (isMe) const Icon(Icons.check_circle, color: kFaceitOrange, size: 16),
          ]
        ],
      ),
    );
    if (scale != 1.0) return Transform.scale(scale: scale, child: content);
    return content;
  }

  Widget _buildRightPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggleMatching,
          child: Container(
            height: 60, alignment: Alignment.center,
            decoration: BoxDecoration(color: _isSearching ? Colors.red[900] : kFaceitOrange, borderRadius: BorderRadius.circular(4), boxShadow: [BoxShadow(color: (_isSearching ? Colors.red : kFaceitOrange).withOpacity(0.4), blurRadius: 15, spreadRadius: 1)]),
            child: Text(_isSearching ? "CANCEL SEARCH" : "PLAY", style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 1.5, fontFamily: "Oswald")),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _createMatch, style: OutlinedButton.styleFrom(side: const BorderSide(color: kFaceitBorder), padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))), child: const Text("CREATE CUSTOM LOBBY", style: TextStyle(color: kFaceitTextDim, fontWeight: FontWeight.bold))),
        const SizedBox(height: 30),
        const Text("MAP SELECTION", style: TextStyle(color: kFaceitTextDim, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Expanded(child: GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.5, crossAxisSpacing: 8, mainAxisSpacing: 8), itemCount: _maps.length, itemBuilder: (ctx, i) {
          bool isSelected = _selectedMap == _maps[i];
          return InkWell(onTap: () => setState(() => _selectedMap = _maps[i]), child: Container(decoration: BoxDecoration(color: isSelected ? kFaceitOrange : kFaceitSurface, borderRadius: BorderRadius.circular(4), border: Border.all(color: isSelected ? kFaceitOrange : kFaceitBorder)), alignment: Alignment.center, child: Text(_maps[i].replaceAll("de_", "").toUpperCase(), style: TextStyle(color: isSelected ? Colors.white : kFaceitTextDim, fontWeight: FontWeight.bold, fontSize: 12))));
        })),
        const SizedBox(height: 20),
        TextField(controller: _joinController, style: const TextStyle(color: kFaceitText), decoration: InputDecoration(hintText: "Paste Hub ID / IP", hintStyle: const TextStyle(color: Colors.grey), filled: true, fillColor: kFaceitSurface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none), suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward, color: kFaceitOrange), onPressed: _joinGame))),
      ],
    );
  }

  void _showErrorDialog(String title, String msg) {
    showDialog(context: context, builder: (ctx) => AlertDialog(backgroundColor: kFaceitSurface, title: Text(title, style: const TextStyle(color: kFaceitOrange)), content: Text(msg, style: const TextStyle(color: kFaceitText)), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))]));
  }
  
  void _showSettingsWindow() {
    showDialog(context: context, builder: (ctx) => Dialog(backgroundColor: kFaceitSurface, child: Container(width: 400, padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("SETTINGS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), const SizedBox(height: 20), const Text("CS2 Installation Path", style: TextStyle(color: Colors.grey)), TextField(controller: _cs2PathController, style: const TextStyle(color: Colors.white)), const SizedBox(height: 20), Align(alignment: Alignment.centerRight, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange), onPressed: (){ _cs2Path = _cs2PathController.text; Navigator.pop(ctx); }, child: const Text("SAVE")))]))));
  }
}

// --- New Wallet Window ---

class WalletWindow extends StatefulWidget {
  final P2PService p2pService;
  final String myPeerID;

  const WalletWindow({super.key, required this.p2pService, required this.myPeerID});

  @override
  State<WalletWindow> createState() => _WalletWindowState();
}

class _WalletWindowState extends State<WalletWindow> {
  double _balance = 0.0;
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    _fetchBalance();
    // Heartbeat to refresh balance every second
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) => _fetchBalance());
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    super.dispose();
  }

  Future<void> _fetchBalance() async {
    final b = await widget.p2pService.getBalance(widget.myPeerID);
    if(mounted) setState(() => _balance = b);
  }

  void _showSendDialog() {
    final recipientCtrl = TextEditingController();
    final amountCtrl = TextEditingController();

    showDialog(
      context: context, 
      builder: (ctx) => AlertDialog(
        backgroundColor: kFaceitSurface,
        title: const Text("SEND EDN", style: TextStyle(color: kFaceitOrange, fontFamily: "Oswald")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: recipientCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: "Receiver Peer ID", hintText: "Qm..."),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: "Amount", suffixText: "EDN"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCEL")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
            onPressed: () async {
              double amt = double.tryParse(amountCtrl.text) ?? 0.0;
              if (recipientCtrl.text.isNotEmpty && amt > 0) {
                Navigator.pop(ctx);
                bool success = await widget.p2pService.sendEdenCoin(widget.myPeerID, recipientCtrl.text, amt);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(success ? "Sent $amt EDN!" : "Transfer Failed."),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ));
                }
              }
            }, 
            child: const Text("SEND")
          )
        ],
      )
    );
  }

  void _showReceiveDialog() {
    showDialog(
      context: context, 
      builder: (ctx) => AlertDialog(
        backgroundColor: kFaceitSurface,
        title: const Text("RECEIVE EDN", style: TextStyle(color: Colors.greenAccent, fontFamily: "Oswald")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Share this Peer ID to receive funds:", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 15),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(4)),
              child: SelectableText(widget.myPeerID, style: const TextStyle(color: Colors.white, fontFamily: "monospace")),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.myPeerID));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Copied to Clipboard")));
              Navigator.pop(ctx);
            }, 
            child: const Text("COPY")
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CLOSE")),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 320, 
        height: 280, 
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: kFaceitSurface, 
          border: Border.all(color: kFaceitOrange), 
          borderRadius: BorderRadius.circular(4)
        ),
        child: Column(
          children: [
            const Text("EDEN WALLET", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            Text("${_balance.toStringAsFixed(2)} EDN", style: const TextStyle(color: kFaceitOrange, fontSize: 32, fontFamily: "Oswald")),
            const SizedBox(height: 8),
            const Text("Live Balance", style: TextStyle(color: Colors.grey, fontSize: 10)),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange, foregroundColor: Colors.white),
                    onPressed: _showSendDialog,
                    child: const Text("SEND"),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.greenAccent), foregroundColor: Colors.greenAccent),
                    onPressed: _showReceiveDialog,
                    child: const Text("RECEIVE"),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text("Mining rewards are deposited after every match.", style: TextStyle(color: Colors.grey, fontSize: 10), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

// --- Trade Interface Overlay ---

class TradeOverlay extends StatefulWidget {
  final String me;
  final String myPeerID;
  final File? myAvatar;
  final Friend friend;
  final P2PService p2pService;

  const TradeOverlay({super.key, required this.me, required this.myPeerID, this.myAvatar, required this.friend, required this.p2pService});

  @override
  State<TradeOverlay> createState() => _TradeOverlayState();
}

class _TradeOverlayState extends State<TradeOverlay> {
  final TextEditingController _amountController = TextEditingController(text: "10");
  double _myBalance = 0.0;
  double _timerValue = 1.0; 
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    _fetchBalance();
    _startTimer();
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _fetchBalance() async {
    double bal = await widget.p2pService.getBalance(widget.myPeerID);
    setState(() => _myBalance = bal);
  }

  void _startTimer() {
    _countdown = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      setState(() {
        _timerValue -= (0.1 / 30); 
        if (_timerValue <= 0) {
          timer.cancel();
          Navigator.pop(context); 
        }
      });
    });
  }

  Future<void> _executeTrade() async {
    double amount = double.tryParse(_amountController.text) ?? 0.0;
    if (amount <= 0 || amount > _myBalance) return;

    _countdown?.cancel(); 

    bool success = await widget.p2pService.sendEdenCoin(widget.myPeerID, widget.friend.peerID, amount);
    
    if (mounted) {
      Navigator.pop(context);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Trade Successful!"), backgroundColor: Colors.green));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Trade Failed."), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    double tradeAmount = double.tryParse(_amountController.text) ?? 0.0;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      child: Container(
        width: 800, height: 500,
        decoration: BoxDecoration(color: const Color(0xFF1E1E1E), border: Border.all(color: kFaceitBorder), borderRadius: BorderRadius.circular(8)),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(color: Color(0xFF121212), border: Border(bottom: BorderSide(color: kFaceitBorder))),
              child: const Center(child: Text("SECURE TRADE OFFER", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 2))),
            ),
            
            Expanded(
              child: Row(
                children: [
                  // Seller (Left)
                  Expanded(
                    child: Container(
                      color: const Color(0xFF252525),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircleAvatar(radius: 50, backgroundImage: widget.myAvatar != null ? FileImage(widget.myAvatar!) : null, child: widget.myAvatar == null ? const Icon(Icons.person, size: 50) : null),
                          const SizedBox(height: 16),
                          Text(widget.me, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                          const SizedBox(height: 8),
                          Text("Holdings: ${_myBalance.toStringAsFixed(2)} EDN", style: const TextStyle(color: Colors.grey)),
                          const SizedBox(height: 20),
                          const Text("Est. Remaining:", style: TextStyle(color: kFaceitTextDim, fontSize: 12)),
                          Text("${(_myBalance - tradeAmount).toStringAsFixed(2)} EDN", style: const TextStyle(color: Colors.redAccent, fontSize: 24, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),

                  // Center (Arrow & Input)
                  SizedBox(
                    width: 200,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Gradient Arrow
                        Container(
                          height: 40, width: 150,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Colors.red, Color(0xFFFFCDD2)]),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(Icons.arrow_forward, color: Colors.white, size: 30),
                        ),
                        const SizedBox(height: 20),
                        const Text("TRADING AMOUNT", style: TextStyle(color: kFaceitTextDim, fontSize: 10, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: _amountController,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                            decoration: const InputDecoration(
                              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitOrange)),
                              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitOrange, width: 2)),
                              suffixText: "EDN"
                            ),
                            onChanged: (v) => setState((){}),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Buyer (Right)
                  Expanded(
                    child: Container(
                      color: const Color(0xFF252525),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const CircleAvatar(radius: 50, child: Icon(Icons.person, size: 50)),
                          const SizedBox(height: 16),
                          Text(widget.friend.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                          const SizedBox(height: 8),
                          Text("Holdings: ${widget.friend.edn} EDN", style: const TextStyle(color: Colors.grey)),
                          const SizedBox(height: 20),
                          const Text("Est. Total:", style: TextStyle(color: kFaceitTextDim, fontSize: 12)),
                          Text("${(widget.friend.edn + tradeAmount).toStringAsFixed(2)} EDN", style: const TextStyle(color: Colors.greenAccent, fontSize: 24, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Footer Actions
            Container(
              padding: const EdgeInsets.all(24),
              color: const Color(0xFF121212),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox(
                          width: double.infinity, height: 50,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
                            onPressed: () => Navigator.pop(context),
                            child: const Text("CANCEL TRADE", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(value: _timerValue, color: Colors.red, backgroundColor: Colors.red.withOpacity(0.2)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox(
                          width: double.infinity, height: 50,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                            onPressed: _executeTrade,
                            child: const Text("CONFIRM & ACCEPT", style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(value: _timerValue, color: Colors.green, backgroundColor: Colors.green.withOpacity(0.2)),
                      ],
                    ),
                  ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}

// --- Companion Window ---
class CompanionWindow extends StatefulWidget {
  final VoidCallback onMinimize;
  final P2PService p2pService;
  const CompanionWindow({super.key, required this.onMinimize, required this.p2pService});
  @override
  State<CompanionWindow> createState() => _CompanionWindowState();
}

class _CompanionWindowState extends State<CompanionWindow> {
  Offset position = const Offset(50, 50);
  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx, top: position.dy,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() => position += d.delta),
        child: Container(
          width: 260, padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: kFaceitSurface.withOpacity(0.95), border: Border.all(color: kFaceitOrange), borderRadius: BorderRadius.circular(4), boxShadow: [const BoxShadow(color: Colors.black54, blurRadius: 10)]),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [const Icon(Icons.shield, color: kFaceitOrange, size: 16), const SizedBox(width: 8), const Text("EDEN AC ACTIVE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)), const Spacer(), InkWell(onTap: widget.onMinimize, child: const Icon(Icons.close, color: Colors.grey, size: 16))]),
              const SizedBox(height: 8),
              StreamBuilder(
                stream: Stream.periodic(const Duration(seconds: 1)),
                builder: (ctx, _) {
                  final info = widget.p2pService.getDashboardData();
                  return Row(
                    children: [
                      Text("TUNNEL: ${info.isMounted ? 'SECURED' : 'WAITING'} \nSESSION: ${widget.p2pService.isConnected() ? 'CONNECTED' : 'IDLE'}", style: const TextStyle(color: Colors.grey, fontSize: 10, fontFamily: "monospace")),
                      Spacer(),
                      Text(info.date)
                    ],
                  );
                }
              ),
            ],
          ),
        ),
      ),
    );
  }
}