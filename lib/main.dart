import 'dart:async';
import 'dart:io';
import 'dart:convert'; // Added for JSON
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'misc/pro_player_grid.dart';
import 'package:eden/services/gsi_configurator.dart';
import 'package:file_picker/file_picker.dart';
import 'localization/lgpkg.dart';
import 'services/steam_service.dart';
import 'services/game_runner.dart';
import 'services/gsi_server.dart';
import 'services/p2p_service.dart';
import 'services/demo/demo_service.dart';
import 'services/demo/api_service.dart';

const Color kFaceitDarkBg = Color(0xFF121212);
const Color kFaceitSurface = Color(0xFF1F1F1F);
const Color kFaceitOrange = Color(0xFFFF5500);
const Color kFaceitText = Color(0xFFEEEEEE);
const Color kFaceitTextDim = Color(0xFFAAAAAA);
const Color kFaceitBorder = Color(0xFF333333);

// --- Global Settings ---
String g_CS2Path = "";
String g_dbUser = "postgres";
String g_DbPassword = "password";
String g_steamIDKey = "";
String g_steamApiKey = "";
final ValueNotifier<String> appLanguageNotifier = ValueNotifier("English");
late DemoService demo;
final ApiServer apiServer = ApiServer();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load Settings on Start
  await _loadSettings();

  final steam = SteamService();
  await steam.init();

  final p2p = P2PService();
  final gsi = GsiServer();
  demo = DemoService();
  demo.setDatabaseUser(g_dbUser);
  demo.setDatabasePassword(g_DbPassword);
  
  if (g_steamApiKey.isNotEmpty) {
    p2p.updateSteamAPIKey(g_steamApiKey);
  }

  try{
    await apiServer.start(g_dbUser, g_DbPassword);
  } catch (e) {
    print("[Main] Warning: API Server failed to start: $e");
  }
  gsi.startServer();

  runApp(MyApp(
    steam: steam, 
    gsiServer: gsi,
    p2pService: p2p,
    demoService: demo,
  ));
}

// --- Persistence Helpers ---
Future<void> _loadSettings() async {
  try {
    final file = File('eden_config.json');
    if (await file.exists()) {
      final content = await file.readAsString();
      final map = jsonDecode(content);
      g_CS2Path = map['cs2_path'] ?? "";
      g_dbUser = map['db_user'] ?? "postgres";
      g_DbPassword = map['db_password'] ?? "password";
      g_steamIDKey = map['steam_id_key'] ?? "";
      g_steamApiKey = map['steam_api_key'] ?? "";
      appLanguageNotifier.value = map['language'] ?? "English";
    }
  } catch (e) {
    print("Error loading settings: $e");
  }
}

Future<void> _saveSettings() async {
  try {
    final file = File('eden_config.json');
    final map = {
      'cs2_path': g_CS2Path,
      'db_user': g_dbUser,
      'db_password': g_DbPassword,
      'steam_id_key': g_steamIDKey,
      'steam_api_key': g_steamApiKey,
      'language': appLanguageNotifier.value,
    };
    await file.writeAsString(jsonEncode(map));
  } catch (e) {
    print("Error saving settings: $e");
  }
}

class MyApp extends StatelessWidget {
  final SteamService steam;
  final GsiServer gsiServer;
  final P2PService p2pService;
  final DemoService demoService;
  final Lgpkg _lgpkg = Lgpkg(); 

  MyApp({
    super.key, 
    required this.steam, 
    required this.gsiServer,
    required this.p2pService, 
    required this.demoService, 
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: appLanguageNotifier,
      builder: (context, language, child) {
        _lgpkg.currentLanguage = language;
        
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: _lgpkg.get("AppTitle"),
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
            demoService: demoService,
          ),
        );
      },
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
  final DemoService demoService;

  const ServerControlPanel({
    super.key,
    required this.steam, 
    required this.gsiServer, 
    required this.p2pService, 
    required this.demoService,
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
  final TextEditingController _dbUserController = TextEditingController();
  final TextEditingController _dbPassController = TextEditingController();
  final TextEditingController _steamIDKeyController = TextEditingController();
  final TextEditingController _steamApiKeyController = TextEditingController();
  final TextEditingController _friendCodeController = TextEditingController();
  late TextEditingController _nameController;

  // State
  Timer? _refreshTimer;
  Timer? _scoreTimer;
  Timer? _steamIdTimer;
  Timer? _pollMatchesTimer;
  String _myPeerID = "";
  String _mySteamID = "";
  
  String _status = "WAITING FOR ACTION"; 
  String _level = "10";
  String _score = "CT 0 - 0 T";
  
  bool _isSearching = false;
  bool _isEngineRunning = false;
  bool _isCompanionVisible = false;
  int _currentView = 0;
  bool _hasMinedThisMatch = false;
  int _selectedShopTab = 0;

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

  // Auction Data
  List<dynamic> _realAuctions = [];

  // live Match Data
  List<dynamic> _liveMatches = [];

  final List<String> _maps = [
    "de_dust2", "de_mirage", "de_inferno", "de_nuke", 
    "de_overpass", "de_vertigo", "de_ancient", "de_anubis"
  ];

  List<dynamic> _matchHistory = [];
  List<dynamic> _selectedMatchStats = [];
  int? _selectedMatchId;
  bool _isLoadingStats = false;

  @override
  void initState() {
    super.initState();
    _lgpkg.currentLanguage = appLanguageNotifier.value;
    
    _status = _lgpkg.get("WaitingAction");
    _nameController = TextEditingController(text: widget.steam.getPlayerName());
    _cs2PathController.text = g_CS2Path;
    _dbUserController.text = g_dbUser;
    _dbPassController.text = g_DbPassword;
    _steamIDKeyController.text = g_steamIDKey;
    _steamApiKeyController.text = g_steamApiKey;

    _scoreAcquirer();
    _steamIdAcquirer();

    _scoreTimer = Timer.periodic(const Duration(seconds: 1), (_) => _scoreAcquirer());
    _steamIdTimer = Timer.periodic(const Duration(seconds: 2), (_) => _steamIdAcquirer());
    
    _pollLiveMatches();
    _pollMatchesTimer = Timer.periodic(const Duration(seconds: 10), (_) => _pollLiveMatches());

    _setGameMode("MATCHMAKING");

    _friends.add(Friend(name: "TestPlayer", peerID: "QmHashTest123", level: "8", skillScore: 2100, edn: 50.0));
  }

  @override
  void dispose() {
    _scoreTimer?.cancel();
    _steamIdTimer?.cancel();
    _pollMatchesTimer?.cancel();
    if(_refreshTimer != null && _refreshTimer!.isActive){
      _refreshTimer?.cancel();
    }
    _joinController.dispose();
    _cs2PathController.dispose();
    _dbUserController.dispose();
    _dbPassController.dispose();
    _steamApiKeyController.dispose();
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
            _score = _lgpkg.get("Warmup");
          } else if (phase == 'intermission') {
            _score = _lgpkg.get("HalfTime");
          } else if (phase == 'gameover') {
            _score = "${_lgpkg.get("Final")}: CT $ctScore - $tScore T";
            if (!_hasMinedThisMatch) {
               _hasMinedThisMatch = true; 
               
               int duration = 1800; 
               int players = int.parse(_maxPlayers);
               
               widget.p2pService.submitMatchReward(duration, players);
               
               ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_lgpkg.get("MatchEndedMining")))
               );
            }
          } else {
            _score = "CT $ctScore - $tScore T";
          }
        });
      }
    };
  }

  Future<void>_steamIdAcquirer() async {
    String steamID = g_steamIDKey;
    setState(() => _mySteamID = steamID);
  }

  Future<void> _fetchPeerID() async {
    if (_myPeerID.isEmpty || _myPeerID == "Offline") {
      String id = await widget.p2pService.getMyID();
      setState(() => _myPeerID = id);
    }
  }

  void _pollLiveMatches() {
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_currentView == 4 && _selectedShopTab == 1) { 
        final matches = await widget.p2pService.getLiveMatches();
        if (mounted) setState(() => _liveMatches = matches);
      }
    });
  }

  void _addFriend() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: kFaceitSurface,
      title: Text(_lgpkg.get("AddFriend"), style: const TextStyle(color: kFaceitOrange, fontFamily: "Oswald")),
      content: TextField(
        controller: _friendCodeController,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(labelText: _lgpkg.get("EnterFriendCode"), hintText: "Qm..."),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_lgpkg.get("Cancel"))),
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
      content: Text("${_lgpkg.get("InvitedMsg")} ${f.name}"),
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

  String _getFriendCode() {
    if (_myPeerID.length < 6) return _lgpkg.get("Loading");
    return _myPeerID.substring(_myPeerID.length - 6).toUpperCase();
  }

  Future<bool> _deductFunds(double amount, String actionName) async {
    double balance = await widget.p2pService.getBalance(_myPeerID);
    if (balance < amount) {
      _showErrorDialog(_lgpkg.get("InsufficientFunds"), "You need $amount EDN to $actionName. Current: ${balance.toStringAsFixed(2)} EDN");
      return false;
    }
    
    bool success = await widget.p2pService.sendEdenCoin(_myPeerID, "SYSTEM_BURN_ADDRESS", amount);
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$amount EDN deducted for $actionName"), backgroundColor: kFaceitOrange));
      setState(() {}); 
    } else {
      _showErrorDialog(_lgpkg.get("TransactionFailed"), _lgpkg.get("ProcessDeductionFailed"));
    }
    return success;
  }

  Future<void> _editProfileName() async {
    TextEditingController tempController = TextEditingController(text: _nameController.text);
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: kFaceitSurface,
      title: Text(_lgpkg.get("ChangeIdentity"), style: const TextStyle(color: kFaceitOrange, fontFamily: "Oswald")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_lgpkg.get("ChangeIdentityCost"), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 10),
          TextField(controller: tempController, style: const TextStyle(color: Colors.white), decoration: InputDecoration(labelText: _lgpkg.get("NewAlias"))),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_lgpkg.get("Cancel"))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
          onPressed: () async {
            if (await _deductFunds(10.0, "Change Name")) {
              setState(() => _nameController.text = tempController.text);
              Navigator.pop(ctx);
            }
          }, 
          child: Text(_lgpkg.get("Pay10EDN"))
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
                  child: Text("${_lgpkg.get("Level").toUpperCase()} $_level", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white)),
                ),
                const Divider(color: kFaceitBorder, height: 30),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildProfileInfoItem(_lgpkg.get("FriendCode"), _getFriendCode()),
                    _buildProfileInfoItem(_lgpkg.get("PeerID"), _myPeerID.length > 8 ? "${_myPeerID.substring(0,8)}..." : _myPeerID),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.grey)),
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(_lgpkg.get("Close"), style: const TextStyle(color: Colors.white)),
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

  Future<void> _uploadDemo() async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['dem'],
  );

  if (result != null) {
    String path = result.files.single.path!;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const Center(
          child: CircularProgressIndicator(
            color: kFaceitOrange,
            backgroundColor: Colors.black26,
          ),
        );
      },
    );

    try {
      final res = await demo.processDemo(path);

      if (mounted) {
        Navigator.of(context).pop(); 
      }

      if (res.success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.green,
              content: Text(
                "MATCH ANALYZED", 
                style: TextStyle(fontFamily: "Oswald", fontWeight: FontWeight.bold)
              ),
              duration: Duration(seconds: 2),
            )
          );
          setState(() {
            _currentView = 3;
          });
        }
      } else {
        if (mounted) {
          _showErrorDialog("Analysis Failed", res.error ?? "Unknown error");
        }
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      if (mounted) _showErrorDialog("Critical Error", e.toString());
    }
  }
}

  Future<void> _fetchMatches() async {
      try {
        final response = await http.get(Uri.parse('http://127.0.0.1:3000/recent-matches'));
        print("API Response: ${response.statusCode} - ${response.body}");
        if (response.statusCode == 200) {
          setState(() {
            _matchHistory = jsonDecode(response.body);
          });
        }
      } catch (e) {
        print("Error fetching matches: $e");
    }
  }

  Future<void> _fetchMatchDetails(int id) async {
    setState(() {
      _selectedMatchId = id;
      _isLoadingStats = true;
    });

    try {
      final response = await http.get(Uri.parse('http://127.0.0.1:3000/match/$id'));
      print("API Response: ${response.statusCode} - ${response.body}");
      if (response.statusCode == 200) {
        setState(() {
          _selectedMatchStats = jsonDecode(response.body);
        });
      }
    } catch (e) {
      print("Error fetching details: $e");
    } finally {
      setState(() => _isLoadingStats = false);
    }
  }


  Future<void> _launchAntiCheatEngine() async {
    widget.p2pService.start();
    
    await Future.delayed(const Duration(seconds: 10));

    await _fetchPeerID();
    
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _fetchPeerID());
  }

  void _handleShieldClick() async {
    if (!_isEngineRunning) {
      setState(() => _status = _lgpkg.get("InitializingAC"));
      await _launchAntiCheatEngine();
      setState(() {
        _isEngineRunning = true;
        _isCompanionVisible = true;
        _status = _lgpkg.get("ACActive");
      });
    } else {
      setState(() => _isCompanionVisible = !_isCompanionVisible);
    }
  }

  void _toggleMatching() {
    if (_isSearching) {
      setState(() {
        _isSearching = false;
        _status = _lgpkg.get("MatchCancelled");
      });
      _runner.stopClient();
      _runner.stopServer();
    } else {
      _hostMatch();
    }
  }

  Future<void> _hostMatch() async {
    if (await _configurator.setupGsi(g_CS2Path) == false) {
      _showErrorDialog(_lgpkg.get("ConfigError"), _lgpkg.get("ConfigWriteError"));
      return;
    }
    
    if (!_isEngineRunning) {
      _showErrorDialog(_lgpkg.get("ACRequired"), _lgpkg.get("ShieldRequiredMsg"));
      return;
    }

    setState(() {
      _isSearching = true;
      _status = _lgpkg.get("SearchingMsg");
    });

    String matchResult = await widget.p2pService.findMatch();
    
    if (!mounted || !_isSearching) return;

    if (matchResult.isNotEmpty && !matchResult.contains("Error")) {
       setState(() {
        _isSearching = false;
        _status = _lgpkg.get("MatchFound");
      });
      
      String hostIP = widget.p2pService.getVirtualIPForPeer(matchResult);
      widget.p2pService.connectToPeer(matchResult);
      await Future.delayed(const Duration(seconds: 3));
      await _runner.startClient(g_CS2Path, hostIP, _nameController.text);
    }
  }

  void _createMatch() async {
    if (!_isSearching) {
      if (await _configurator.setupGsi(g_CS2Path) == false) return;
      if (!_isEngineRunning) {
        _showErrorDialog(_lgpkg.get("ACRequired"), _lgpkg.get("EnableShieldMsg"));
        return;
      }

      setState(() => _status = "${_lgpkg.get("StartingServer")} (${_lgpkg.get(_selectedModeTitle)})...");
      
      await _runner.startServer(
        g_CS2Path, 
        "0.0.0.0", 
        _selectedMap, 
        _selectedGameType, 
        _selectedGameMode, 
        _maxPlayers, 
        _isFriendlyFire,
        _recordDemo,
        27015
      );
      
      setState(() => _status = _lgpkg.get("ServerOnline"));
    }
  }

  void _joinGame() async {
    String targetID = _joinController.text.trim();
    if (targetID.isEmpty) return;
    String hostIP = widget.p2pService.getVirtualIPForPeer(targetID);
    widget.p2pService.connectToPeer(targetID);
    await _runner.startClient(g_CS2Path, hostIP, _nameController.text);
  }

  Future<void> _refreshAuctions() async {
    final data = await widget.p2pService.getActiveAuctions();
    if (mounted) setState(() => _realAuctions = data);
  }

  @override
  Widget build(BuildContext context) {
    // Ensure this widget also rebuilds correctly when language changes
    _lgpkg.currentLanguage = appLanguageNotifier.value;

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
                        child: _buildMainContent(),
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

  Widget _buildMainContent() {
    switch (_currentView) {
      case 0:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: _buildMatchLobby()),
            const SizedBox(width: 24),
            Expanded(flex: 1, child: _buildRightPanel()),
          ],
        );
      case 1:
        return _buildFriendList();
      case 2:
        return const ProSettingsGrid();
      case 3:
        return _buildStatsView();
      case 4:
        return _buildShopView();
      default:
        return Container();
    }
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
          _buildSideIcon(Icons.people, _currentView == 2, onTap: () => setState(() => _currentView = 2)),
          _buildSideIcon(Icons.bar_chart, _currentView == 3, onTap: () {
            setState(() => _currentView = 3);
            _fetchMatches();
          }),
          _buildSideIcon(Icons.gavel, _currentView == 4, onTap: () => setState(() => _currentView = 4)), 
          const Spacer(),
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
    String title = _lgpkg.get("PlayTitle");
    if (_currentView == 0) title = _lgpkg.get("PlayTitle");
    if (_currentView == 1) title = _lgpkg.get("SocialTitle");
    if (_currentView == 2) title = _lgpkg.get("ProConfigTitle");
    if (_currentView == 4) title = "MARKETPLACE";

    return Container(
      height: 80, padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(color: kFaceitSurface, border: Border(bottom: BorderSide(color: kFaceitBorder))),
      child: Row(
        children: [
          Text(title, style: const TextStyle(color: kFaceitText, fontSize: 20, fontWeight: FontWeight.bold, fontFamily: "Oswald")),
          const SizedBox(width: 40),
          
          if (_currentView == 0) ...[
            _buildHeaderTab("Matchmaking", _selectedModeTitle == "MATCHMAKING"),
            _buildHeaderTab("Tournaments", _selectedModeTitle == "TOURNAMENTS"),
            _buildHeaderTab("Deathmatch", _selectedModeTitle == "DEATHMATCH"),
            _buildHeaderTab("1v1Hubs", _selectedModeTitle == "1V1 HUBS"),
          ],

          if (_currentView == 4) ...[
            _buildShopTab("AUCTION", 0),
            _buildShopTab("BET", 1),
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
                  Text(_lgpkg.get("AntiCheat"), style: TextStyle(color: _isEngineRunning ? Colors.green : Colors.red, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 15),
          
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

  Widget _buildHeaderTab(String key, bool isActive) {
    String internalMode = "";
    if (key == "Matchmaking") internalMode = "MATCHMAKING";
    if (key == "Tournaments") internalMode = "TOURNAMENTS";
    if (key == "Deathmatch") internalMode = "DEATHMATCH";
    if (key == "1v1Hubs") internalMode = "1V1 HUBS";

    return InkWell(
      onTap: () => _setGameMode(internalMode), 
      child: Container(
        margin: const EdgeInsets.only(right: 30),
        padding: const EdgeInsets.symmetric(vertical: 26),
        decoration: BoxDecoration(border: isActive ? const Border(bottom: BorderSide(color: kFaceitOrange, width: 3)) : null),
        child: Text(_lgpkg.get(key).toUpperCase(), style: TextStyle(color: isActive ? kFaceitOrange : kFaceitTextDim, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
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
            Text(_lgpkg.get("FriendsList"), style: const TextStyle(color: kFaceitTextDim, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
              icon: const Icon(Icons.person_add),
              label: Text(_lgpkg.get("AddFriend")),
              onPressed: _addFriend,
            )
          ],
        ),
        const SizedBox(height: 20),
        Expanded(
          child: _friends.isEmpty 
          ? Center(child: Text(_lgpkg.get("NoFriendsMsg"), style: const TextStyle(color: kFaceitTextDim)))
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
                                child: Text("${_lgpkg.get("Level").toUpperCase()} ${friend.level}", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                              ),
                              const SizedBox(width: 8),
                              Text("${_lgpkg.get("Skill")}: ${friend.skillScore}", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                              const SizedBox(width: 8),
                              Text("${friend.edn} EDN", style: const TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                            ],
                          )
                        ],
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () => _inviteFriend(friend),
                        child: Text(_lgpkg.get("Invite")),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700]),
                        onPressed: () => _openTradeInterface(friend),
                        child: Text(_lgpkg.get("Trade")),
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
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), color: kFaceitOrange, child: Text(_isSearching ? _lgpkg.get("Searching").toUpperCase() : _lgpkg.get("Lobby"), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white))),
                const SizedBox(height: 8),
                Text(_selectedMap.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 40, fontFamily: "Oswald", fontWeight: FontWeight.bold)),
                Text(_status, style: const TextStyle(color: Colors.white70, letterSpacing: 1.5)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(_lgpkg.get("TeamRoster"), style: const TextStyle(color: kFaceitTextDim, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
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
          Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: Text(_lgpkg.get("VS"), style: const TextStyle(fontSize: 40, color: kFaceitOrange, fontFamily: "Oswald"))),
          SizedBox(width: 200, child: _buildPlayerRow(1, false, scale: 1.2)),
      ]);
    } else {
      return Row(children: [
          Expanded(child: Column(children: List.generate(5, (i) => _buildPlayerRow(i, true)))),
          const SizedBox(width: 24),
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(_lgpkg.get("VS"), style: TextStyle(color: kFaceitTextDim.withOpacity(0.3), fontSize: 24, fontWeight: FontWeight.bold)),
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
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [Text(isMe ? _nameController.text : _lgpkg.get("EmptySlot"), style: TextStyle(color: isMe ? Colors.white : kFaceitTextDim, fontWeight: FontWeight.bold)), if (isMe) Text("Lvl $_level", style: const TextStyle(color: kFaceitOrange, fontSize: 10))]),
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
            child: Text(_isSearching ? _lgpkg.get("CancelSearch") : _lgpkg.get("Play"), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 1.5, fontFamily: "Oswald")),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _createMatch, style: OutlinedButton.styleFrom(side: const BorderSide(color: kFaceitBorder), padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))), child: Text(_lgpkg.get("CreateCustomLobby"), style: const TextStyle(color: kFaceitTextDim, fontWeight: FontWeight.bold))),
        const SizedBox(height: 30),
        Text(_lgpkg.get("MapSelection"), style: const TextStyle(color: kFaceitTextDim, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Expanded(child: GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.5, crossAxisSpacing: 8, mainAxisSpacing: 8), itemCount: _maps.length, itemBuilder: (ctx, i) {
          bool isSelected = _selectedMap == _maps[i];
          return InkWell(onTap: () => setState(() => _selectedMap = _maps[i]), child: Container(decoration: BoxDecoration(color: isSelected ? kFaceitOrange : kFaceitSurface, borderRadius: BorderRadius.circular(4), border: Border.all(color: isSelected ? kFaceitOrange : kFaceitBorder)), alignment: Alignment.center, child: Text(_maps[i].replaceAll("de_", "").toUpperCase(), style: TextStyle(color: isSelected ? Colors.white : kFaceitTextDim, fontWeight: FontWeight.bold, fontSize: 12))));
        })),
        const SizedBox(height: 20),
        TextField(controller: _joinController, style: const TextStyle(color: kFaceitText), decoration: InputDecoration(hintText: _lgpkg.get("PasteHubID"), hintStyle: const TextStyle(color: Colors.grey), filled: true, fillColor: kFaceitSurface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none), suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward, color: kFaceitOrange), onPressed: _joinGame))),
      ],
    );
  }

  void _showErrorDialog(String title, String msg) {
    showDialog(context: context, builder: (ctx) => AlertDialog(backgroundColor: kFaceitSurface, title: Text(title, style: const TextStyle(color: kFaceitOrange)), content: Text(msg, style: const TextStyle(color: kFaceitText)), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_lgpkg.get("OK")))]));
  }
  
  Widget _buildShopTab(String label, int index) {
    bool isActive = _selectedShopTab == index;
    return InkWell(
      onTap: () => setState(() => _selectedShopTab = index),
      child: Container(
        margin: const EdgeInsets.only(right: 30),
        padding: const EdgeInsets.symmetric(vertical: 26),
        decoration: BoxDecoration(border: isActive ? const Border(bottom: BorderSide(color: kFaceitOrange, width: 3)) : null),
        child: Text(label, style: TextStyle(color: isActive ? kFaceitOrange : kFaceitTextDim, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
      ),
    );
  }

  Widget _buildShopView() {
    return _selectedShopTab == 0 ? _buildAuctionContent() : _buildBettingContent();
  }

  void _showListingDialog() {
    List<dynamic> _inventory = [];
    bool _loading = true;
    int _selectedIndex = -1;
    final priceCtrl = TextEditingController();
    final durationCtrl = TextEditingController(text: "3600");


    widget.p2pService.getSteamInventory(_mySteamID).then((items) {
          if(mounted) {
            setState(() {
                _inventory = items;
                _loading = false;
            });
          }
      });

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: kFaceitSurface,
            title: const Text("Select Item to Sell", style: TextStyle(color: kFaceitOrange)),
            content: SizedBox(
              width: 500, height: 400,
              child: Column(
                children: [
                  if(_loading) const LinearProgressIndicator(color: kFaceitOrange),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3, childAspectRatio: 0.7, crossAxisSpacing: 8, mainAxisSpacing: 8),
                      itemCount: _inventory.length,
                      itemBuilder: (c, i) {
                        final item = _inventory[i];
                        bool selected = _selectedIndex == i;
                        return InkWell(
                          onTap: () => setDialogState(() => _selectedIndex = i),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: selected ? kFaceitOrange : kFaceitBorder, width: selected ? 2 : 1),
                              color: kFaceitSurface,
                            ),
                            child: Column(
                              children: [
                                Expanded(child: Image.network(item['image_url'], fit: BoxFit.cover)),
                                Padding(
                                  padding: const EdgeInsets.all(4.0),
                                  child: Text(item['name'], style: const TextStyle(fontSize: 10, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                                ),
                                Text(item['wear'], style: const TextStyle(fontSize: 8, color: Colors.grey)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  if(_selectedIndex != -1) ...[
                      TextField(
                          controller: priceCtrl, 
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white), 
                          decoration: InputDecoration(
                              labelText: "Price for ${_inventory[_selectedIndex]['name']} (EDN)",
                              border: const OutlineInputBorder()
                          )
                      ),
                      const SizedBox(height: 10),
                      TextField(
                          controller: durationCtrl, 
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white), 
                          decoration: InputDecoration(
                              labelText: "Duration for ${_inventory[_selectedIndex]['name']} (seconds)",
                              border: const OutlineInputBorder()
                          )
                      ),
                    ]
                ],
              ),
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
                onPressed: () async {
                    if(_selectedIndex == -1 || priceCtrl.text.isEmpty) return;
                    
                    final item = _inventory[_selectedIndex];
                    await widget.p2pService.listRichItem(
                        item['asset_id'],
                        item['name'],
                        item['image_url'],
                        item['wear'],
                        double.parse(priceCtrl.text),
                        durationCtrl.text.isEmpty ? 3600 : int.parse(durationCtrl.text)
                    );
                    Navigator.pop(ctx);
                    Future.delayed(const Duration(seconds: 1), _refreshAuctions);
                }, 
                child: const Text("LIST ITEM")
              )
            ],
          );
        }
      )
    );
  }

  Widget _buildAuctionContent() {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
               const Text("GLOBAL MARKET", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
               Row(
                 children: [
                   IconButton(
                     icon: const Icon(Icons.refresh, color: kFaceitOrange), 
                     onPressed: _refreshAuctions,
                     tooltip: "Sync with Blockchain",
                   ),
                   const SizedBox(width: 10),
                   ElevatedButton.icon(
                      icon: const Icon(Icons.add_shopping_cart, size: 16),
                      label: const Text("SELL ITEM"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green[700],
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)
                      ),
                      onPressed: _showListingDialog,
                   ),
                 ],
               )
            ],
          ),
        ),
        Expanded(
          child: _realAuctions.isEmpty 
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.wifi_tethering_off, size: 64, color: Colors.white10),
                    const SizedBox(height: 16),
                    Text("No active listings found on the chain.", style: TextStyle(color: kFaceitTextDim.withOpacity(0.5))),
                  ],
                )
              )
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.8,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                itemCount: _realAuctions.length,
                itemBuilder: (ctx, i) {
                  final item = _realAuctions[i];
                  // Blockchain data structure: {id, seller, asset_id, price, expires_at}
                  
                  // Helper to determine image based on name (optional visual polish)
                  String imageUrl = ""; 
                  if(item['asset_id'].toString().contains("Asiimov")) imageUrl = "https://market.fp.ps.netease.com/file/65f57072372367dc73b699e2Zc91itAt05?fop=imageView/6/f/webp/q/75";
                  else if(item['asset_id'].toString().contains("Dragon")) imageUrl = "https://market.fp.ps.netease.com/file/65f58ae9831310d75518738eMzkP12O205?fop=imageView/6/f/webp/q/75";
                  
                  bool isMyItem = item['seller'] == _myPeerID;

                  return Container(
                    decoration: BoxDecoration(
                      color: kFaceitSurface,
                      border: Border.all(color: isMyItem ? Colors.green.withOpacity(0.5) : kFaceitBorder),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Container(
                            color: Colors.black26,
                            padding: const EdgeInsets.all(16),
                            child: imageUrl.isNotEmpty 
                              ? Image.network(imageUrl, fit: BoxFit.contain, errorBuilder: (_,__,___)=>const Icon(Icons.card_giftcard, size: 50, color: Colors.white24))
                              : const Icon(Icons.card_giftcard, size: 50, color: Colors.white24),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item['asset_id'], 
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text("${item['price']} EDN", style: const TextStyle(color: kFaceitOrange, fontWeight: FontWeight.bold)),
                                  if(isMyItem) const Text("YOU", style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: isMyItem 
                                ? OutlinedButton(
                                    onPressed: null, 
                                    child: const Text("LISTED", style: TextStyle(color: Colors.grey))
                                  )
                                : ElevatedButton(
                                    style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
                                    onPressed: () async {
                                      String res = await widget.p2pService.buyItem(
                                        item['seller'], // Real Seller ID
                                        item['asset_id'], // Real Asset ID
                                        (item['price'] as num).toDouble()
                                      );
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res)));
                                        _refreshAuctions(); 
                                      }
                                    },
                                    child: const Text("BUY NOW"),
                                  ),
                              )
                            ],
                          ),
                        )
                      ],
                    ),
                  );
                },
              ),
        ),
      ],
    );
  }

Future<void> _placeBet(String matchID, String team, String amountStr, double odds) async {
    double amt = double.tryParse(amountStr) ?? 0.0;
    if (amt <= 0) return;
    
    String res = await widget.p2pService.placeBet(matchID, team, amt);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res.contains("Error") ? "Bet Failed" : "Bet Placed! Potential Payout: ${(amt * odds).toStringAsFixed(2)} EDN"),
        backgroundColor: res.contains("Error") ? Colors.red : Colors.green,
      ));
    }
  }

Widget _buildBettingContent() {
    if (_liveMatches.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.sports_esports_outlined, size: 64, color: Colors.white10),
            const SizedBox(height: 16),
            Text("No live matches found.", style: TextStyle(color: kFaceitTextDim.withOpacity(0.5))),
            const SizedBox(height: 8),
            const Text("Servers broadcast automatically when live.", style: TextStyle(color: Colors.grey, fontSize: 10)),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _liveMatches.length,
      itemBuilder: (ctx, i) {
        final m = _liveMatches[i];
        final amountCtrl = TextEditingController();

        // Calculate dynamic odds based on score (simplified logic)
        int scoreCT = m['score_ct'];
        int scoreT = m['score_t'];
        int total = scoreCT + scoreT;
        double oddsCT = 1.8; 
        double oddsT = 1.8;
        
        // Simple odds shift based on lead
        if (total > 0) {
          if (scoreCT > scoreT) {
            oddsCT = 1.2 + (scoreT / total); // Lower return for winner
            oddsT = 2.0 + ((scoreCT - scoreT) * 0.1); // Higher return for loser
          } else if (scoreT > scoreCT) {
            oddsT = 1.2 + (scoreCT / total);
            oddsCT = 2.0 + ((scoreT - scoreCT) * 0.1);
          }
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kFaceitSurface,
            border: Border.all(color: kFaceitBorder),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
                    child: const Text("LIVE", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                  const Spacer(),
                  Text(m['map_name'].toString().toUpperCase(), style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text("CT", style: TextStyle(color: Color(0xFF5D79AE), fontWeight: FontWeight.bold)),
                      Text("${m['score_ct']}", style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Text("VS", style: TextStyle(color: Colors.grey)),
                  Column(
                    children: [
                      const Text("T", style: TextStyle(color: Color(0xFFDE9B35), fontWeight: FontWeight.bold)),
                      Text("${m['score_t']}", style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
              const Divider(color: kFaceitBorder, height: 24),
              Row(
                children: [
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: amountCtrl,
                      decoration: const InputDecoration(hintText: "0", suffixText: "EDN", isDense: true),
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D79AE)),
                      onPressed: () => _placeBet(m['match_id'], "CT", amountCtrl.text, oddsCT),
                      child: Text("CT x${oddsCT.toStringAsFixed(2)}"),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDE9B35)),
                      onPressed: () => _placeBet(m['match_id'], "T", amountCtrl.text, oddsT),
                      child: Text("T x${oddsT.toStringAsFixed(2)}"),
                    ),
                  ),
                ],
              )
            ],
          ),
        );
      },
    );
  }

  void _showSettingsWindow() {
    String tempLanguage = appLanguageNotifier.value;
    _dbUserController.text = g_dbUser;
    _dbPassController.text = g_DbPassword;
    _steamIDKeyController.text = g_steamIDKey;
    _steamApiKeyController.text = g_steamApiKey;
    
    showDialog(
      context: context, 
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: kFaceitSurface, 
            child: Container(
              width: 400, 
              padding: const EdgeInsets.all(24), 
              child: Column(
                mainAxisSize: MainAxisSize.min, 
                crossAxisAlignment: CrossAxisAlignment.start, 
                children: [
                  Text(_lgpkg.get("Settings"), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: "Oswald", fontSize: 20)), 
                  const SizedBox(height: 20), 
                  
                  // CS2 Path Input
                  Text(_lgpkg.get("CS2Path"), style: const TextStyle(color: Colors.grey)), 
                  TextField(
                    controller: _cs2PathController, 
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitBorder)),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitOrange)),
                    ),
                  ), 
                  const SizedBox(height: 20),

                  // Steam ID Key Input
                  const Text("Steam 64 ID (For Trade)", style: TextStyle(color: Colors.grey)), 
                    TextField(
                      controller: _steamIDKeyController, 
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitBorder)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitOrange)),
                      ),
                    ), 
                    const SizedBox(height: 20),

                  // Steam API Key Input
                  const Text("Steam Web API Key", style: TextStyle(color: Colors.grey)), 
                    TextField(
                      controller: _steamApiKeyController, 
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitBorder)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitOrange)),
                      ),
                    ), 
                    const SizedBox(height: 20),

                  // DB User Input
                  const Text("Database User", style: TextStyle(color: Colors.grey)),
                  TextField(
                    controller: _dbUserController, 
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitBorder)),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitOrange)),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // DB Password Input
                  const Text("Database Password", style: TextStyle(color: Colors.grey)), 
                  TextField(
                    controller: _dbPassController, 
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitBorder)),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kFaceitOrange)),
                    ),
                  ), 
                  const SizedBox(height: 20),

                  // Language Selection
                  Text("Language / 语言", style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(border: Border.all(color: kFaceitBorder), borderRadius: BorderRadius.circular(4)),
                    child: DropdownButton<String>(
                      value: tempLanguage,
                      dropdownColor: kFaceitSurface,
                      isExpanded: true,
                      underline: const SizedBox(),
                      icon: const Icon(Icons.language, color: kFaceitOrange),
                      style: const TextStyle(color: Colors.white),
                      items: const [
                        DropdownMenuItem(value: "English", child: Text("English")),
                        DropdownMenuItem(value: "Chinese", child: Text("Chinese (中文)")),
                      ],
                      onChanged: (val) {
                         if(val != null) setDialogState(() => tempLanguage = val);
                      },
                    ),
                  ),

                  const SizedBox(height: 30), 
                  
                  // Action Buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(_lgpkg.get("Cancel"), style: const TextStyle(color: kFaceitTextDim))
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange), 
                        onPressed: (){ 
                          // 1. Update Global Settings
                          g_CS2Path = _cs2PathController.text;
                          g_dbUser = _dbUserController.text;
                          g_DbPassword = _dbPassController.text;
                          g_steamIDKey = _steamIDKeyController.text;
                          g_steamApiKey = _steamApiKeyController.text;
                          appLanguageNotifier.value = tempLanguage;
                          
                          // 2. Update Runtime Services
                          widget.demoService.setDatabaseUser(g_dbUser);
                          widget.demoService.setDatabasePassword(g_DbPassword);
                          widget.p2pService.updateSteamAPIKey(g_steamApiKey);
                          // 3. Save to File
                          _saveSettings();
                          
                          // 4. Close Dialog
                          Navigator.pop(ctx); 
                          
                          // 5. Force UI Refresh (Language change handles itself via Notifier)
                          setState(() {});

                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Settings Saved. Restart app for any changes to fully take effect."))
                          );
                        }, 
                        child: const Text("SUBMIT")
                      ),
                    ],
                  )
                ]
              )
            )
          );
        }
      )
    );
  }

  // --- Demo Stats View ---
  Widget _buildStatsView() {
    return Row(
      children: [
        Container(
          width: 300,
          decoration: BoxDecoration(
            color: kFaceitSurface,
            border: Border.all(color: kFaceitBorder),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_lgpkg.get("MATCH HISTORY"), style: const TextStyle(color: kFaceitTextDim, fontWeight: FontWeight.bold, fontFamily: "Oswald")),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 16, color: kFaceitOrange),
                      onPressed: _fetchMatches,
                    )
                  ],
                ),
              ),
              const Divider(height: 1, color: kFaceitBorder),
              Expanded(
                child: ListView.builder(
                  itemCount: _matchHistory.length,
                  itemBuilder: (ctx, i) {
                    final match = _matchHistory[i];
                    bool isSelected = match['id'] == _selectedMatchId;
                    return InkWell(
                      onTap: () => _fetchMatchDetails(match['id']),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected ? kFaceitSurface.withOpacity(0.8) : null,
                          border: Border(left: BorderSide(color: isSelected ? kFaceitOrange : Colors.transparent, width: 3)),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(4)),
                              alignment: Alignment.center,
                              child: Text(match['map'].toString().substring(3, 5).toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white)),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(match['map'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                const SizedBox(height: 4),
                                RichText(
                                  text: TextSpan(
                                    children: [
                                      TextSpan(text: "${match['score_ct']}", style: const TextStyle(color: Color(0xFF5D79AE), fontWeight: FontWeight.bold)),
                                      const TextSpan(text: " : ", style: TextStyle(color: Colors.grey)),
                                      TextSpan(text: "${match['score_t']}", style: const TextStyle(color: Color(0xFFDE9B35), fontWeight: FontWeight.bold)),
                                    ]
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            Text(match['date'].toString().split(' ')[0], style: const TextStyle(color: Colors.grey, fontSize: 10)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kFaceitOrange,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    icon: const Icon(Icons.upload_file),
                    label: const Text("ANALYZE NEW DEMO"),
                    onPressed: () async {
                      await _uploadDemo();
                      _fetchMatches();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        
        const SizedBox(width: 24),
        
        Expanded(
          child: _selectedMatchId == null 
            ? _buildEmptyStatsState()
            : _buildScoreboard(),
        ),
      ],
    );
  }

  Widget _buildEmptyStatsState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.analytics_outlined, size: 64, color: kFaceitTextDim),
          const SizedBox(height: 16),
          Text("SELECT A MATCH", style: TextStyle(color: kFaceitTextDim.withOpacity(0.5), fontSize: 24, fontFamily: "Oswald")),
          const SizedBox(height: 8),
          const Text("Select a match from the left to view detailed analytics", style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildScoreboard() {
    if (_isLoadingStats) {
      return const Center(child: CircularProgressIndicator(color: kFaceitOrange));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("SCOREBOARD", style: TextStyle(color: Colors.white, fontSize: 24, fontFamily: "Oswald")),
            Row(
              children: [
                OutlinedButton(onPressed: (){}, child: const Text("DOWNLOAD DEMO")),
                const SizedBox(width: 10),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kFaceitSurface),
                  onPressed: (){}, 
                  child: const Text("WATCH ROOM")
                ),
              ],
            )
          ],
        ),
        const SizedBox(height: 20),
        
        // Table Header
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: kFaceitSurface,
          child: const Row(
            children: [
              Expanded(flex: 3, child: Text("PLAYER", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text("KILLS", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text("DEATHS", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text("K/D", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text("ADR", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
              Expanded(child: Text("RATING", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
            ],
          ),
        ),
        
        // Table Rows
        Expanded(
          child: ListView.builder(
            itemCount: _selectedMatchStats.length,
            itemBuilder: (ctx, i) {
              final p = _selectedMatchStats[i];
              double kd = (p['kills'] / (p['deaths'] == 0 ? 1 : p['deaths']));
              bool positive = kd >= 1.0;

              return Container(
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kFaceitBorder))),
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3, 
                      child: Row(
                        children: [
                          CircleAvatar(radius: 12, backgroundColor: Colors.grey[800], child: Text(p['name'][0], style: const TextStyle(fontSize: 10, color: Colors.white))),
                          const SizedBox(width: 10),
                          Text(p['name'], style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                        ],
                      ),
                    ),
                    Expanded(child: Text("${p['kills']}", style: const TextStyle(color: Colors.white))),
                    Expanded(child: Text("${p['deaths']}", style: const TextStyle(color: Colors.white))),
                    Expanded(child: Text(kd.toStringAsFixed(2), style: TextStyle(color: positive ? Colors.green : Colors.red))),
                    Expanded(child: Text("${p['adr'].toStringAsFixed(1)}", style: const TextStyle(color: Colors.white))),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _getRatingColor(p['rating']),
                          borderRadius: BorderRadius.circular(4)
                        ),
                        child: Text(
                          "${p['rating'].toStringAsFixed(2)}", 
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)
                        ),
                      ),
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

  Color _getRatingColor(double r) {
    if (r >= 1.2) return const Color(0xFF2ECC71);
    if (r >= 1.0) return const Color(0xFFF1C40F);
    return const Color(0xFFE74C3C);
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
  final Lgpkg _lgpkg = Lgpkg();
  double _balance = 0.0;
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    // Sync language
    _lgpkg.currentLanguage = appLanguageNotifier.value;
    
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
        title: Text(_lgpkg.get("SendEDN"), style: const TextStyle(color: kFaceitOrange, fontFamily: "Oswald")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: recipientCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(labelText: _lgpkg.get("ReceiverID"), hintText: "Qm..."),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(labelText: _lgpkg.get("Amount"), suffixText: "EDN"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_lgpkg.get("Cancel"))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange),
            onPressed: () async {
              double amt = double.tryParse(amountCtrl.text) ?? 0.0;
              if (recipientCtrl.text.isNotEmpty && amt > 0) {
                Navigator.pop(ctx);
                bool success = await widget.p2pService.sendEdenCoin(widget.myPeerID, recipientCtrl.text, amt);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(success ? "Sent $amt EDN!" : _lgpkg.get("TransferFailed")),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ));
                }
              }
            }, 
            child: Text(_lgpkg.get("Send"))
          )
        ],
      )
    );
  }

  void _showReceiveDialog() async {
    
    String walletAddress = await widget.p2pService.getPublicKey();
    
    if (!mounted) return;

    showDialog(
      context: context, 
      builder: (ctx) => AlertDialog(
        backgroundColor: kFaceitSurface,
        title: Text(_lgpkg.get("ReceiveEDN"), style: const TextStyle(color: Colors.greenAccent, fontFamily: "Oswald")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_lgpkg.get("ShareIDMsg"), style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 15),
            Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(4)),
                child: SelectableText(walletAddress.isEmpty ? "Wallet Not Initialized" : walletAddress, 
                  style: const TextStyle(color: Colors.white, fontFamily: "monospace", fontSize: 12),
              ),
            )
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: walletAddress));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lgpkg.get("CopiedClipboard"))));
              Navigator.pop(ctx);
            }, 
            child: Text(_lgpkg.get("Copy"))
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_lgpkg.get("Close"))),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    // Ensure text updates if language changed while wallet open
    _lgpkg.currentLanguage = appLanguageNotifier.value;

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
            Text(_lgpkg.get("EdenWallet"), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            Text("${_balance.toStringAsFixed(2)} EDN", style: const TextStyle(color: kFaceitOrange, fontSize: 32, fontFamily: "Oswald")),
            const SizedBox(height: 8),
            Text(_lgpkg.get("LiveBalance"), style: const TextStyle(color: Colors.grey, fontSize: 10)),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kFaceitOrange, foregroundColor: Colors.white),
                    onPressed: _showSendDialog,
                    child: Text(_lgpkg.get("Send")),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.greenAccent), foregroundColor: Colors.greenAccent),
                    onPressed: _showReceiveDialog,
                    child: Text(_lgpkg.get("Receive")),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(_lgpkg.get("MiningRewardsMsg"), style: const TextStyle(color: Colors.grey, fontSize: 10), textAlign: TextAlign.center),
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
  final Lgpkg _lgpkg = Lgpkg();
  final TextEditingController _amountController = TextEditingController(text: "10");
  double _myBalance = 0.0;
  double _timerValue = 1.0; 
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    _lgpkg.currentLanguage = appLanguageNotifier.value;
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lgpkg.get("TradeSuccessful")), backgroundColor: Colors.green));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lgpkg.get("TradeFailed")), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _lgpkg.currentLanguage = appLanguageNotifier.value;
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
              child: Center(child: Text(_lgpkg.get("SecureTradeOffer"), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 2))),
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
                          Text("${_lgpkg.get("Holdings")}: ${_myBalance.toStringAsFixed(2)} EDN", style: const TextStyle(color: Colors.grey)),
                          const SizedBox(height: 20),
                          Text(_lgpkg.get("EstRemaining"), style: const TextStyle(color: kFaceitTextDim, fontSize: 12)),
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
                        Text(_lgpkg.get("TradingAmount"), style: const TextStyle(color: kFaceitTextDim, fontSize: 10, fontWeight: FontWeight.bold)),
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
                          Text("${_lgpkg.get("Holdings")}: ${widget.friend.edn} EDN", style: const TextStyle(color: Colors.grey)),
                          const SizedBox(height: 20),
                          Text(_lgpkg.get("EstTotal"), style: const TextStyle(color: kFaceitTextDim, fontSize: 12)),
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
                            child: Text(_lgpkg.get("CancelTrade"), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
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
                            child: Text(_lgpkg.get("ConfirmAccept"), style: const TextStyle(fontWeight: FontWeight.bold)),
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
  final Lgpkg _lgpkg = Lgpkg();
  Offset position = const Offset(50, 50);
  
  @override
  Widget build(BuildContext context) {
    _lgpkg.currentLanguage = appLanguageNotifier.value;
    
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
              Row(children: [const Icon(Icons.shield, color: kFaceitOrange, size: 16), const SizedBox(width: 8), Text(_lgpkg.get("EdenACActive"), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)), const Spacer(), InkWell(onTap: widget.onMinimize, child: const Icon(Icons.close, color: Colors.grey, size: 16))]),
              const SizedBox(height: 8),
              StreamBuilder(
                stream: Stream.periodic(const Duration(seconds: 1)),
                builder: (ctx, _) {
                  final info = widget.p2pService.getDashboardData();
                  return Row(
                    children: [
                      Text("TUNNEL: ${info.isMounted ? _lgpkg.get("TunnelSecured") : _lgpkg.get("TunnelWaiting")} \nSESSION: ${widget.p2pService.isConnected() ? _lgpkg.get("SessionConnected") : _lgpkg.get("SessionIdle")}", style: const TextStyle(color: Colors.grey, fontSize: 10, fontFamily: "monospace")),
                      const Spacer(),
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