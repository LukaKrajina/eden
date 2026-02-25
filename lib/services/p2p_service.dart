import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// --- Typedefs ---
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

typedef PlaceBetC = Pointer<Utf8> Function(Pointer<Utf8> matchID, Pointer<Utf8> team, Double amount);
typedef PlaceBetDart = Pointer<Utf8> Function(Pointer<Utf8> matchID, Pointer<Utf8> team, double amount);

typedef BuyItemC = Pointer<Utf8> Function(Pointer<Utf8> sellerID, Pointer<Utf8> assetID, Double price);
typedef BuyItemDart = Pointer<Utf8> Function(Pointer<Utf8> sellerID, Pointer<Utf8> assetID, double price);

typedef ConfirmTradeC = Int32 Function(Pointer<Utf8> tradeID, Pointer<Utf8> assetID);
typedef ConfirmTradeDart = int Function(Pointer<Utf8> tradeID, Pointer<Utf8> assetID);

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

  // Function Pointers
  late StartEngineDart _startEngine;
  late StopEngineDart _stopEngine;
  late ConnectToPeerDart _connectToPeer;
  late GetLocalPeerIDDart _getLocalPeerID;
  late GetIPForPeerDart _getIPForPeer;
  late GetDashboardDataDart _getDashboardData;
  late FindMatchDart _findMatch;
  late MineBlockDart _mineBlock;
  late GetBalanceDart _getBalance;
  late SendTxDart _sendTx;
  late PlaceBetDart _placeBet;
  late BuyItemDart _buyItem;
  late ConfirmTradeDart _confirmTrade;

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
    _getDashboardData = _lib.lookupFunction<GetDashboardDataC, GetDashboardDataDart>('GetDashboardData');
    _findMatch = _lib.lookupFunction<FindMatchC, FindMatchDart>('FindMatch');
    _mineBlock = _lib.lookupFunction<MineBlockC, MineBlockDart>('MineBlock');
    _getBalance = _lib.lookupFunction<GetBalanceC, GetBalanceDart>('GetBalance');
    _sendTx = _lib.lookupFunction<SendTxC, SendTxDart>('SendEdenCoin');
    _placeBet = _lib.lookupFunction<PlaceBetC, PlaceBetDart>('PlaceBet');
    _buyItem = _lib.lookupFunction<BuyItemC, BuyItemDart>('BuyItem');
    _confirmTrade = _lib.lookupFunction<ConfirmTradeC, ConfirmTradeDart>('ConfirmTrade');
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
    return _getLocalPeerID().toDartString();
  }

  String getVirtualIPForPeer(String peerID) {
    if (!_isInitialized) return "";
    final ptr = peerID.toNativeUtf8();
    final result = _getIPForPeer(ptr).toDartString();
    calloc.free(ptr);
    return result;
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
    return _findMatch().toDartString();
  }

  Future<String> submitMatchReward(int duration, int playerCount) async {
    if (!_isInitialized) return "Error: Engine Offline";
    return _mineBlock(duration, playerCount).toDartString();
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

  Future<String> placeBet(String matchID, String team, double amount) async {
    if (!_isInitialized) return "Error: Offline";
    final mPtr = matchID.toNativeUtf8();
    final tPtr = team.toNativeUtf8();
    try {
      return _placeBet(mPtr, tPtr, amount).toDartString();
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
      return _buyItem(sPtr, aPtr, price).toDartString();
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
}