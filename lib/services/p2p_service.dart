import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef StartEngineC = Void Function();
typedef StartEngineDart = void Function();

typedef StopEngineC = Void Function();
typedef StopEngineDart = void Function();

typedef ConnectToPeerC = Void Function(Pointer<Utf8> peerID);
typedef ConnectToPeerDart = void Function(Pointer<Utf8> peerID);

typedef GetLocalPeerIDC = Pointer<Utf8> Function();
typedef GetLocalPeerIDDart = Pointer<Utf8> Function();

typedef GetIPForPeerC = Pointer<Utf8> Function(Pointer<Utf8> peerID);
typedef GetIPForPeerDart = Pointer<Utf8> Function(Pointer<Utf8> peerID);

typedef GetMyPublicKeyC = Pointer<Utf8> Function();
typedef GetMyPublicKeyDart = Pointer<Utf8> Function();

typedef GetDashboardDataC = Void Function(Pointer<Bool> isMounted, Pointer<Utf8> dateOut);
typedef GetDashboardDataDart = void Function(Pointer<Bool> isMounted, Pointer<Utf8> dateOut);

typedef FindMatchC = Pointer<Utf8> Function();
typedef FindMatchDart = Pointer<Utf8> Function();

typedef MineBlockC = Pointer<Utf8> Function(Int32 duration, Int32 playerCount);
typedef MineBlockDart = Pointer<Utf8> Function(int duration, int playerCount);

typedef GetBalanceC = Double Function(Pointer<Utf8> address);
typedef GetBalanceDart = double Function(Pointer<Utf8> address);

typedef SendTxC = Int32 Function(Pointer<Utf8> sender, Pointer<Utf8> receiver, Double amount);
typedef SendTxDart = int Function(Pointer<Utf8> sender, Pointer<Utf8> receiver, double amount);

typedef FetchLiveMatchesC = Pointer<Utf8> Function();
typedef FetchLiveMatchesDart = Pointer<Utf8> Function();

typedef ListAuctionItemC = Pointer<Utf8> Function(Pointer<Utf8> assetID, Double price, Int32 duration);
typedef ListAuctionItemDart = Pointer<Utf8> Function(Pointer<Utf8> assetID, double price, int duration);

typedef FetchAuctionsC = Pointer<Utf8> Function();
typedef FetchAuctionsDart = Pointer<Utf8> Function();

typedef PlaceBetC = Pointer<Utf8> Function(Pointer<Utf8> matchID, Pointer<Utf8> team, Double amount);
typedef PlaceBetDart = Pointer<Utf8> Function(Pointer<Utf8> matchID, Pointer<Utf8> team, double amount);

typedef BuyItemC = Pointer<Utf8> Function(Pointer<Utf8> sellerID, Pointer<Utf8> assetID, Double price);
typedef BuyItemDart = Pointer<Utf8> Function(Pointer<Utf8> sellerID, Pointer<Utf8> assetID, double price);

typedef ConfirmTradeC = Int32 Function(Pointer<Utf8> tradeID, Pointer<Utf8> assetID);
typedef ConfirmTradeDart = int Function(Pointer<Utf8> tradeID, Pointer<Utf8> assetID);

typedef SetSteamAPIKeyC = Void Function(Pointer<Utf8> key);
typedef SetSteamAPIKeyDart = void Function(Pointer<Utf8> key);

typedef GetSteamInventoryC = Pointer<Utf8> Function(Pointer<Utf8> steamID);
typedef GetSteamInventoryDart = Pointer<Utf8> Function(Pointer<Utf8> steamID);

typedef RegisterFriendC = Pointer<Utf8> Function();
typedef RegisterFriendDart = Pointer<Utf8> Function();

typedef AddFriendC = Pointer<Utf8> Function(Pointer<Utf8> code);
typedef AddFriendDart = Pointer<Utf8> Function(Pointer<Utf8> code);

typedef GetFriendsC = Pointer<Utf8> Function();
typedef GetFriendsDart = Pointer<Utf8> Function();

typedef RegisterSteamIDC = Pointer<Utf8> Function(Pointer<Utf8> steamID);
typedef RegisterSteamIDDart = Pointer<Utf8> Function(Pointer<Utf8> steamID);

typedef UpdateProfileC = Pointer<Utf8> Function(Pointer<Utf8> url);
typedef UpdateProfileDart = Pointer<Utf8> Function(Pointer<Utf8> url);

typedef GetPeerProfileC = Pointer<Utf8> Function(Pointer<Utf8> id);
typedef GetPeerProfileDart = Pointer<Utf8> Function(Pointer<Utf8> id);

typedef FreeStringC = Void Function(Pointer<Utf8> str);
typedef FreeStringDart = void Function(Pointer<Utf8> str);

class DashboardInfo {
  final bool isMounted;
  final String date;
  DashboardInfo(this.isMounted, this.date);
}

class P2PService {
  static final P2PService _instance = P2PService._internal();
  factory P2PService() => _instance;

  late DynamicLibrary _lib;
  bool _isInitialized = false;
  late StartEngineDart _startEngine;
  late StopEngineDart _stopEngine;
  late ConnectToPeerDart _connectToPeer;
  late GetLocalPeerIDDart _getLocalPeerID;
  late GetIPForPeerDart _getIPForPeer;
  late GetMyPublicKeyDart _getMyPublicKey;
  late GetDashboardDataDart _getDashboardData;
  late FindMatchDart _findMatch;
  late MineBlockDart _mineBlock;
  late GetBalanceDart _getBalance;
  late SendTxDart _sendTx;
  late FetchLiveMatchesDart _fetchLiveMatches;
  late ListAuctionItemDart _listAuctionItem;
  late FetchAuctionsDart _fetchAuctions;
  late PlaceBetDart _placeBet;
  late BuyItemDart _buyItem;
  late ConfirmTradeDart _confirmTrade;
  late SetSteamAPIKeyDart _setSteamAPIKey;
  late GetSteamInventoryDart _getSteamInventory;
  late RegisterFriendDart _registerFriend;
  late AddFriendDart _addFriend;
  late GetFriendsDart _getFriends;
  late RegisterSteamIDDart _registerSteamID;
  late UpdateProfileDart _updateProfile;
  late GetPeerProfileDart _getPeerProfile;
  late FreeStringDart _freeString;

  P2PService._internal() {
    if (Platform.isWindows) {
      try {
        _lib = DynamicLibrary.open('adam.dll');
        _bindFunctions();
        _isInitialized = true;
        print("[P2P] adam.dll loaded successfully.");
      } catch (e) {
        print("[Critical] Failed to load adam.dll: $e");
      }
    }
  }

  void _bindFunctions() {
    _startEngine = _lib.lookupFunction<StartEngineC, StartEngineDart>('StartEngine');
    _stopEngine = _lib.lookupFunction<StopEngineC, StopEngineDart>('StopEngine');
    _connectToPeer = _lib.lookupFunction<ConnectToPeerC, ConnectToPeerDart>('JoinBattle');
    _getLocalPeerID = _lib.lookupFunction<GetLocalPeerIDC, GetLocalPeerIDDart>('GetLocalPeerID');
    _getIPForPeer = _lib.lookupFunction<GetIPForPeerC, GetIPForPeerDart>('GetIPForPeer');
    _getMyPublicKey = _lib.lookupFunction<GetMyPublicKeyC, GetMyPublicKeyDart>('GetMyPublicKey');
    _getDashboardData = _lib.lookupFunction<GetDashboardDataC, GetDashboardDataDart>('GetDashboardData');
    _findMatch = _lib.lookupFunction<FindMatchC, FindMatchDart>('FindMatch');
    _mineBlock = _lib.lookupFunction<MineBlockC, MineBlockDart>('MineBlock');
    _getBalance = _lib.lookupFunction<GetBalanceC, GetBalanceDart>('GetBalance');
    _sendTx = _lib.lookupFunction<SendTxC, SendTxDart>('SendEdenCoin');
    _fetchLiveMatches = _lib.lookupFunction<FetchLiveMatchesC, FetchLiveMatchesDart>('FetchLiveMatches');
    _listAuctionItem = _lib.lookupFunction<ListAuctionItemC, ListAuctionItemDart>('ListAuctionItem');
    _fetchAuctions = _lib.lookupFunction<FetchAuctionsC, FetchAuctionsDart>('FetchAuctions');
    _placeBet = _lib.lookupFunction<PlaceBetC, PlaceBetDart>('PlaceBet');
    _buyItem = _lib.lookupFunction<BuyItemC, BuyItemDart>('BuyItem');
    _confirmTrade = _lib.lookupFunction<ConfirmTradeC, ConfirmTradeDart>('ConfirmTrade');
    _setSteamAPIKey = _lib.lookupFunction<SetSteamAPIKeyC, SetSteamAPIKeyDart>('UpdateSteamAPIKey');
    _getSteamInventory = _lib.lookupFunction<GetSteamInventoryC, GetSteamInventoryDart>('GetSteamInventory');
    _registerFriend = _lib.lookupFunction<RegisterFriendC, RegisterFriendDart>('RegisterAndGetFriendCode');
    _addFriend = _lib.lookupFunction<AddFriendC, AddFriendDart>('AddFriend');
    _getFriends = _lib.lookupFunction<GetFriendsC, GetFriendsDart>('GetFriends');
    _registerSteamID = _lib.lookupFunction<RegisterSteamIDC, RegisterSteamIDDart>('RegisterMySteamID');
    _updateProfile = _lib.lookupFunction<UpdateProfileC, UpdateProfileDart>('UpdateProfile');
    _getPeerProfile = _lib.lookupFunction<GetPeerProfileC, GetPeerProfileDart>('GetPeerProfile');
    _freeString = _lib.lookupFunction<FreeStringC, FreeStringDart>('FreeString');
  }

  String _consumeNativeString(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return "";
    try {
      final str = ptr.toDartString();
      return str;
    } finally {
      _freeString(ptr);
    }
  }

  void start() {
    if (_isInitialized) _startEngine();
  }

  void stop() {
    if (_isInitialized) _stopEngine();
  }

  void connectToPeer(String peerID) {
    if (!_isInitialized) return;
    final ptr = peerID.toNativeUtf8();
    _connectToPeer(ptr);
    calloc.free(ptr);
  }

  Future<String> getMyID() async {
    if (!_isInitialized) return "Offline";
    return _consumeNativeString(_getLocalPeerID());
  }

  String getVirtualIPForPeer(String peerID) {
    if (!_isInitialized) return "";
    final ptr = peerID.toNativeUtf8();
    final result = _getIPForPeer(ptr).toDartString();
    calloc.free(ptr);
    return result;
  }

  Future<String> getPublicKey() async {
    if (!_isInitialized) return "";
    try {
      return _getMyPublicKey().toDartString();
    } catch (e) {
      return "Error: Key Not Available";
    }
  }

  bool isConnected() {
    if (!_isInitialized) return false;
    final id = _getLocalPeerID().toDartString();
    return id.isNotEmpty && id != "Not Connected";
  }

  DashboardInfo getDashboardData() {
    if (!_isInitialized) return DashboardInfo(false, "--/--/----");

    final isMountedPtr = calloc<Bool>();
    final dateOutPtr = calloc<Uint8>(20).cast<Utf8>();

    try {
      _getDashboardData(isMountedPtr, dateOutPtr);
      return DashboardInfo(isMountedPtr.value, dateOutPtr.toDartString());
    } finally {
      calloc.free(isMountedPtr);
      calloc.free(dateOutPtr);
    }
  }

  Future<String> findMatch() async {
    if (!_isInitialized) return "Error: Engine Not Loaded";
    return _consumeNativeString(_findMatch());
  }

  Future<String> submitMatchReward(int duration, int playerCount) async {
    if (!_isInitialized) return "Error: Engine Offline";
    return _consumeNativeString(_mineBlock(duration, playerCount));
  }

  Future<double> getBalance(String address) async {
    if (!_isInitialized) return 0.0;
    final ptr = address.toNativeUtf8();
    try {
      return _getBalance(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  Future<bool> sendEdenCoin(String sender, String receiver, double amount) async {
    if (!_isInitialized) return false;
    final sPtr = sender.toNativeUtf8();
    final rPtr = receiver.toNativeUtf8();
    try {
      final res = _sendTx(sPtr, rPtr, amount);
      return res == 1;
    } finally {
      calloc.free(sPtr);
      calloc.free(rPtr);
    }
  }

  Future<String> listSteamItem(String assetID, double price, int durationSeconds) async {
  if (!_isInitialized) return "Offline";
  final aPtr = assetID.toNativeUtf8();
  try {
    return _consumeNativeString(_listAuctionItem(aPtr, price, durationSeconds));
  } finally {
    calloc.free(aPtr);
  }
}

  Future<List<dynamic>> getActiveAuctions() async {
    if (!_isInitialized) return [];
    final ptr = _fetchAuctions();
    final jsonStr = _consumeNativeString(ptr);
    try {
      return jsonDecode(jsonStr);
    } catch (e) {
      return [];
    }
  }

  Future<String> placeBet(String matchID, String team, double amount) async {
    if (!_isInitialized) return "Error: Offline";
    final mPtr = matchID.toNativeUtf8();
    final tPtr = team.toNativeUtf8();
    try {
      return _consumeNativeString(_placeBet(mPtr, tPtr, amount));
    } finally {
      calloc.free(mPtr);
      calloc.free(tPtr);
    }
  }

  Future<String> buyItem(String sellerID, String assetID, double price) async {
    if (!_isInitialized) return "Error: Offline";
    final sPtr = sellerID.toNativeUtf8();
    final aPtr = assetID.toNativeUtf8();
    try {
      return _consumeNativeString(_buyItem(sPtr, aPtr, price));
    } finally {
      calloc.free(sPtr);
      calloc.free(aPtr);
    }
  }

  Future<bool> checkTradeStatus(String tradeID, String assetID) async {
    if (!_isInitialized) return false;
    final tPtr = tradeID.toNativeUtf8();
    final aPtr = assetID.toNativeUtf8();
    try {
      return _confirmTrade(tPtr, aPtr) == 1;
    } finally {
      calloc.free(tPtr);
      calloc.free(aPtr);
    }
  }

  Future<void> updateSteamAPIKey(String key) async {
    if (!_isInitialized) return;
    final kPtr = key.toNativeUtf8();
    try {
      _setSteamAPIKey(kPtr);
    } finally {
      calloc.free(kPtr);
    }
  }

  Future<List<dynamic>> getSteamInventory(String steamID) async {
    final ptrStr = steamID.toNativeUtf8();
    final res = _consumeNativeString(_getSteamInventory(ptrStr));
    calloc.free(ptrStr);
    try {
        return jsonDecode(res);
    } catch (e) {
        return [];
    }
  }

  Future<String> listRichItem(String assetID, String name, String img, String wear, double price, int duration) async {
      String payload = "$assetID|$name|$img|$wear";
      return listSteamItem(payload, price, duration);
  }

  Future<List<dynamic>> getLiveMatches() async {
    if (!_isInitialized) return [];
    final ptr = _fetchLiveMatches();
    final jsonStr = _consumeNativeString(ptr);
    try {
      return jsonDecode(jsonStr);
    } catch (e) {
      print("Error parsing matches: $e");
      return [];
    }
  }

  Future<String> generateMyFriendCode() async {
    if (!_isInitialized) return "Offline";
    return _consumeNativeString(_registerFriend());
  }

  Future<String> addFriendByCode(String code) async {
    if (!_isInitialized) return "Offline";
    final ptr = code.toNativeUtf8();
    try {
      return _consumeNativeString(_addFriend(ptr));
    } finally {
      calloc.free(ptr);
    }
  }

  Future<String> registerSteamID(String steamID) async {
    if (!_isInitialized) return "Offline";
    final ptr = steamID.toNativeUtf8();
    try {
      return _consumeNativeString(_registerSteamID(ptr));
    } finally {
      calloc.free(ptr);
    }
  }

  Future<List<dynamic>> getFriendList() async {
    if (!_isInitialized) return [];
    final ptr = _getFriends();
    final jsonStr = _consumeNativeString(ptr);
    try {
      return jsonDecode(jsonStr);
    } catch (e) {
      return [];
    }
  }

  Future<String> updateMyProfile(String avatarURL) async {
    if (!_isInitialized) return "Offline";
    final ptr = avatarURL.toNativeUtf8();
    try {
      return _consumeNativeString(_updateProfile(ptr));
    } finally {
      calloc.free(ptr);
    }
  }

  Future<Map<String, dynamic>> getPeerProfile(String peerID) async {
    if (!_isInitialized) return {};
    
    final ptr = peerID.toNativeUtf8();
    String jsonStr;
    
    try {
      jsonStr = _consumeNativeString(_getPeerProfile(ptr));
    } finally {
      calloc.free(ptr);
    }

    try {
      return jsonDecode(jsonStr);
    } catch (e) {
      print("[P2P] Failed to parse profile JSON: $e");
      return {};
    }
  }
}