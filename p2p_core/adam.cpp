// adam.cpp
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <string>
#include <iostream>
#include <thread>
#include <vector>
#include <shellapi.h>
#include <mutex>
#include <atomic>
#include "../wintun/include/wintun.h"

#pragma comment(lib, "wintun.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "shell32.lib")

static WINTUN_CREATE_ADAPTER_FUNC* ptrCreateAdapter;
static WINTUN_OPEN_ADAPTER_FUNC* ptrOpenAdapter;
static WINTUN_START_SESSION_FUNC* ptrStartSession;
static WINTUN_GET_READ_WAIT_EVENT_FUNC* ptrGetReadWaitEvent;
static WINTUN_RECEIVE_PACKET_FUNC* ptrReceivePacket;
static WINTUN_RELEASE_RECEIVE_PACKET_FUNC* ptrReleaseReceivePacket;
static WINTUN_ALLOCATE_SEND_PACKET_FUNC* ptrAllocateSendPacket;
static WINTUN_SEND_PACKET_FUNC* ptrSendPacket;
static WINTUN_END_SESSION_FUNC* ptrEndSession;
static WINTUN_CLOSE_ADAPTER_FUNC* ptrCloseAdapter;

HMODULE WintunModule = NULL;
WINTUN_ADAPTER_HANDLE Adapter = NULL;
WINTUN_SESSION_HANDLE Session = NULL;
std::atomic<bool> IsRunning(false);

typedef void (*GoPacketCallback)(void* data, int len);
typedef char* (*SubmitGameBlockFunc)(int duration, int playerCount);
typedef double (*GetWalletBalanceFunc)(char* address);
typedef int (*SendTransactionFunc)(char* sender, char* receiver, double amount);
typedef void (*InitPacketBridgeFunc)(void (*)(void*, int));
typedef char* (*StartEdenNodeFunc)(const char* virtualIP);
typedef void (*ConnectToPeerFunc)(const char* peerID);
typedef char* (*GetIPForPeerFunc)(const char* peerID);
typedef char* (*StartMatchFunc)(char* matchID, char* playerList);
typedef char* (*GetWalletPubKeyFunc)();
typedef void (*StopNodeFunc)();
typedef char* (*GetMyPeerIDFunc)();
typedef char* (*AutoConnectToPeersFunc)();
typedef int (*IsPeerAliveFunc)();
typedef char* (*GetNetworkMatchesFunc)();
typedef char* (*FetchMyInventoryFunc)(char* steamID);
typedef char* (*ListSteamItemFunc)(char* assetID, double price, int duration);
typedef char* (*GetOpenAuctionsFunc)();
typedef char* (*TriggerExpirationCleanupFunc)();
typedef char* (*PlaceBetFunc)(char* matchID, char* team, double amount);
typedef char* (*CreateEscrowFunc)(char* sellerID, char* assetID, double price);
typedef int (*VerifyTradeFunc)(char* tradeID, char* assetID);
typedef void (*SetSteamAPIKeyFunc)(char* key);

SubmitGameBlockFunc ptrSubmitGameBlock = nullptr;
GetWalletBalanceFunc ptrGetWalletBalance = nullptr;
SendTransactionFunc ptrSendTransaction = nullptr;
StartEdenNodeFunc ptrStartEdenNode = nullptr;
ConnectToPeerFunc ptrConnectToPeer = nullptr;
GetIPForPeerFunc ptrGetIPForPeer = nullptr;
StartMatchFunc ptrStartMatch = nullptr;
GetWalletPubKeyFunc ptrGetWalletPubKey = nullptr;
StopNodeFunc ptrStopNode = nullptr;
GetMyPeerIDFunc ptrGetMyPeerID = nullptr;
AutoConnectToPeersFunc ptrAutoConnect = nullptr;
IsPeerAliveFunc ptrIsPeerAlive = nullptr;
static GetNetworkMatchesFunc ptrGetNetworkMatches = nullptr;
GoPacketCallback ptrSendToP2P = nullptr;
FetchMyInventoryFunc ptrFetchMyInventory = nullptr;
ListSteamItemFunc ptrListSteamItem = nullptr;
GetOpenAuctionsFunc ptrGetOpenAuctions = nullptr;
TriggerExpirationCleanupFunc ptrTriggerExpirationCleanup = nullptr;
PlaceBetFunc ptrPlaceBet = nullptr;
CreateEscrowFunc ptrCreateEscrow = nullptr;
VerifyTradeFunc ptrVerifyTrade = nullptr;
SetSteamAPIKeyFunc ptrSetSteamAPIKey = nullptr;
static void (*ptrFreeString)(char*) = nullptr;

// --- Forward Declarations ---
bool LoadWintun();
void ReadFromTunLoop();

// --- Wintun Logic ---

extern "C" __declspec(dllexport) int SetupAdapter(char* virtualIP) {
    if (!LoadWintun()) return -1;

    system("netsh interface delete interface name=\"EdenVPN\" > nul 2>&1");

    GUID guid = { 0xdeadbeef, 0xface, 0x4ace, { 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef } };
    Adapter = ptrCreateAdapter(L"EdenVPN", L"Wintun", &guid);
    if (!Adapter) Adapter = ptrOpenAdapter(L"EdenVPN");
    
    if (!Adapter) return -2;

    std::string ipCmd = "netsh interface ip set address name=\"EdenVPN\" static " + std::string(virtualIP) + " 255.255.255.0 > nul 2>&1";
    std::string mtuCmd = "netsh interface ipv4 set subinterface \"EdenVPN\" mtu=1400 store=persistent > nul 2>&1";
    system(ipCmd.c_str());
    system(mtuCmd.c_str());

    Session = ptrStartSession(Adapter, 0x400000);
    if (!Session) return -3;

    IsRunning = true;
    
    std::thread(ReadFromTunLoop).detach();

    return 0;
}

extern "C" __declspec(dllexport) void RegisterPacketHandler(GoPacketCallback handler) {
    ptrSendToP2P = handler;
}

extern "C" __declspec(dllexport) void InjectVPNPacket(void* data, int len) {
    if (!Session || !IsRunning) return;

    if (len <= 0 || len > 1500) return; 

    BYTE* tunPacket = ptrAllocateSendPacket(Session, (DWORD)len);
    if (tunPacket) {
        memcpy(tunPacket, data, len);
        ptrSendPacket(Session, tunPacket);
    }
}

bool LoadWintun() {
    if (WintunModule) return true;

    WintunModule = LoadLibraryExW(L"wintun.dll", NULL, LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!WintunModule) return false;

    ptrCreateAdapter = (WINTUN_CREATE_ADAPTER_FUNC*)GetProcAddress(WintunModule, "WintunCreateAdapter");
    ptrOpenAdapter = (WINTUN_OPEN_ADAPTER_FUNC*)GetProcAddress(WintunModule, "WintunOpenAdapter");
    ptrStartSession = (WINTUN_START_SESSION_FUNC*)GetProcAddress(WintunModule, "WintunStartSession");
    ptrGetReadWaitEvent = (WINTUN_GET_READ_WAIT_EVENT_FUNC*)GetProcAddress(WintunModule, "WintunGetReadWaitEvent");
    ptrReceivePacket = (WINTUN_RECEIVE_PACKET_FUNC*)GetProcAddress(WintunModule, "WintunReceivePacket");
    ptrReleaseReceivePacket = (WINTUN_RELEASE_RECEIVE_PACKET_FUNC*)GetProcAddress(WintunModule, "WintunReleaseReceivePacket");
    ptrAllocateSendPacket = (WINTUN_ALLOCATE_SEND_PACKET_FUNC*)GetProcAddress(WintunModule, "WintunAllocateSendPacket");
    ptrSendPacket = (WINTUN_SEND_PACKET_FUNC*)GetProcAddress(WintunModule, "WintunSendPacket");
    ptrEndSession = (WINTUN_END_SESSION_FUNC*)GetProcAddress(WintunModule, "WintunEndSession");
    ptrCloseAdapter = (WINTUN_CLOSE_ADAPTER_FUNC*)GetProcAddress(WintunModule, "WintunCloseAdapter");

    return (ptrCreateAdapter && ptrStartSession && ptrAllocateSendPacket && ptrEndSession && ptrCloseAdapter);
}

bool LoadGoDLL() {
    static HMODULE hGo = NULL;
    if (hGo) return true;

    hGo = LoadLibraryExW(L"libp2p_core.dll", NULL, LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
    if (!hGo) {
        std::cerr << "[Error] Could not find libp2p_core.dll" << std::endl;
        return false;
    }

    auto ptrInitBridge = (InitPacketBridgeFunc)GetProcAddress(hGo, "InitPacketBridge");
    ptrStartEdenNode = (StartEdenNodeFunc)GetProcAddress(hGo, "StartEdenNode");
    ptrConnectToPeer = (ConnectToPeerFunc)GetProcAddress(hGo, "ConnectToPeer");
    ptrGetIPForPeer = (GetIPForPeerFunc)GetProcAddress(hGo, "GetIPForPeer");
    ptrStopNode = (StopNodeFunc)GetProcAddress(hGo, "StopEdenNode");
    ptrGetMyPeerID = (GetMyPeerIDFunc)GetProcAddress(hGo, "GetMyPeerID");
    ptrAutoConnect = (AutoConnectToPeersFunc)GetProcAddress(hGo, "AutoConnectToPeers");
    ptrIsPeerAlive = (IsPeerAliveFunc)GetProcAddress(hGo, "IsPeerAlive");
    ptrStartMatch = (StartMatchFunc)GetProcAddress(hGo, "StartMatch");
    ptrGetWalletPubKey = (GetWalletPubKeyFunc)GetProcAddress(hGo, "GetWalletPubKey");
    ptrGetNetworkMatches = (GetNetworkMatchesFunc)GetProcAddress(hGo, "GetNetworkMatches");
    ptrSubmitGameBlock = (SubmitGameBlockFunc)GetProcAddress(hGo, "SubmitGameBlock");
    ptrGetWalletBalance = (GetWalletBalanceFunc)GetProcAddress(hGo, "GetWalletBalance");
    ptrSendTransaction = (SendTransactionFunc)GetProcAddress(hGo, "SendTransaction");
    auto goHandler = (GoPacketCallback)GetProcAddress(hGo, "HandleOutboundPacket");
    ptrFetchMyInventory = (FetchMyInventoryFunc)GetProcAddress(hGo, "FetchMyInventory");
    ptrListSteamItem = (ListSteamItemFunc)GetProcAddress(hGo, "ListSteamItem");
    ptrGetOpenAuctions = (GetOpenAuctionsFunc)GetProcAddress(hGo, "GetOpenAuctions");
    ptrTriggerExpirationCleanup = (TriggerExpirationCleanupFunc)GetProcAddress(hGo, "TriggerExpirationCleanup");
    ptrPlaceBet = (PlaceBetFunc)GetProcAddress(hGo, "PlaceBet");
    ptrCreateEscrow = (CreateEscrowFunc)GetProcAddress(hGo, "CreateEscrow");
    ptrVerifyTrade = (VerifyTradeFunc)GetProcAddress(hGo, "VerifySteamTrade");
    ptrSetSteamAPIKey = (SetSteamAPIKeyFunc)GetProcAddress(hGo, "SetSteamAPIKey");
    ptrFreeString = (void(*)(char*))GetProcAddress(hGo, "FreeString");

    if (ptrInitBridge) {
        ptrInitBridge(InjectVPNPacket);
    }

    if (ptrStartEdenNode && ptrStopNode && goHandler) {
        RegisterPacketHandler(goHandler);
        return true;
    }
    return false;
}

void ReadFromTunLoop() {
    HANDLE waitHandle = ptrGetReadWaitEvent(Session);
    
    while (IsRunning) {
        if (WaitForSingleObject(waitHandle, INFINITE) == WAIT_OBJECT_0) {
            DWORD packetSize;
            BYTE* packet = ptrReceivePacket(Session, &packetSize);
            
            if (packet) {
                if (ptrSendToP2P && packetSize > 20) {
                     if ((packet[0] >> 4) == 4 && packet[9] == 17) {
                         ptrSendToP2P((void*)packet, (int)packetSize);
                     }
                }
                
                ptrReleaseReceivePacket(Session, packet);
            }
        }
    }
}

extern "C" __declspec(dllexport) void StartEngine() {
    if (!LoadGoDLL()) {
        std::cerr << "[Error] Failed to bridge with libp2p_core.dll" << std::endl;
        return;
    }
    
    char* derivedIP = nullptr;
    if (ptrStartEdenNode) {
        derivedIP = ptrStartEdenNode("0.0.0.0");
        if (derivedIP) {
            std::cout << "[Eden] P2P Node Active. Virtual IP: " << derivedIP << std::endl;
        }
    }

    if (!derivedIP || strlen(derivedIP) == 0) {
        std::cerr << "[Error] Failed to derive valid virtual IP from P2P node" << std::endl;
        return;
    }
    
    int adapterStatus = SetupAdapter(derivedIP);
    if (adapterStatus != 0) {
        std::cerr << "[Error] Wintun setup failed with code: " << adapterStatus << std::endl;
        return;
    }
}

extern "C" __declspec(dllexport) const char* GetIPForPeer(const char* peerID) {
    static std::string cache;
    char* res = ptrGetIPForPeer(peerID);
    cache = res;
    ptrFreeString(res);
    return cache.c_str();
}

extern "C" __declspec(dllexport) void StopEngine() {
    IsRunning = false;
    
    if (Session && ptrEndSession) {
        ptrEndSession(Session);
        Session = NULL;
    }
    if (Adapter && ptrCloseAdapter) {
        ptrCloseAdapter(Adapter);
        Adapter = NULL;
    }

    if (ptrStopNode) {
        ptrStopNode();
    }

    if (WintunModule) {
        FreeLibrary(WintunModule);
        WintunModule = NULL;
    }
}

extern "C" __declspec(dllexport) void GetDashboardData(bool* isMounted, char* dateOut) {
    *isMounted = IsRunning;
    time_t rawtime;
    struct tm * timeinfo;
    time(&rawtime);
    timeinfo = localtime(&rawtime);
    strftime(dateOut, 20, "%m/%d/%Y", timeinfo);
}

extern "C" __declspec(dllexport) char* GetLocalPeerID() {
    if (ptrGetMyPeerID) return ptrGetMyPeerID();
    return (char*)"";
}


extern "C" __declspec(dllexport) bool CheckConnectionHealth() {
    if (ptrIsPeerAlive) {
        return ptrIsPeerAlive() == 1;
    }
    return false;
}

extern "C" __declspec(dllexport) char* FindMatch() {
    if (ptrAutoConnect) {
        return ptrAutoConnect(); 
    }
    return (char*)"Error";
}

extern "C" __declspec(dllexport) void JoinBattle(char* targetID) {
    if (ptrConnectToPeer) ptrConnectToPeer(targetID);
}

extern "C" __declspec(dllexport) const char* MineBlock(int duration, int playerCount) {
    if (ptrSubmitGameBlock) return ptrSubmitGameBlock(duration, playerCount);
    return "Error: Function Not Loaded";
}

extern "C" __declspec(dllexport) double GetBalance(char* address) {
    if (ptrGetWalletBalance) return ptrGetWalletBalance(address);
    return 0.0;
}

extern "C" __declspec(dllexport) int SendEdenCoin(char* sender, char* receiver, double amount) {
    if (ptrSendTransaction) return ptrSendTransaction(sender, receiver, amount);
    return 0;
}

extern "C" __declspec(dllexport) const char* FetchLiveMatches() {
    if (ptrGetNetworkMatches) return ptrGetNetworkMatches();
    return "[]";
}

extern "C" __declspec(dllexport) const char* ListAuctionItem(char* assetID, double price, int duration) {
    if (ptrListSteamItem) return ptrListSteamItem(assetID, price, duration);
    return "Error: DLL Func Missing";
}

extern "C" __declspec(dllexport) const char* FetchAuctions() {
    if (ptrGetOpenAuctions) return ptrGetOpenAuctions();
    return "[]";
}

extern "C" __declspec(dllexport) const char* RunExpirationCheck() {
    if (ptrTriggerExpirationCleanup) return ptrTriggerExpirationCleanup();
    return "Error: DLL Func Missing";
}

extern "C" __declspec(dllexport) const char* PlaceBet(char* matchID, char* team, double amount) {
    if (ptrPlaceBet) return ptrPlaceBet(matchID, team, amount);
    return "Error: DLL Func Missing";
}

extern "C" __declspec(dllexport) const char* BuyItem(char* sellerID, char* assetID, double price) {
    if (ptrCreateEscrow) return ptrCreateEscrow(sellerID, assetID, price);
    return "Error: DLL Func Missing";
}

extern "C" __declspec(dllexport) bool ConfirmTrade(char* tradeID, char* assetID) {
    if (ptrVerifyTrade) {
        return ptrVerifyTrade(tradeID, assetID) == 1;
    }
    return false;
}

extern "C" __declspec(dllexport) void UpdateSteamAPIKey(char* key) {
    if (ptrSetSteamAPIKey) ptrSetSteamAPIKey(key);
}

extern "C" __declspec(dllexport) const char* GetSteamInventory(char* steamID) {
    if (ptrFetchMyInventory) return ptrFetchMyInventory(steamID);
    return "[]";
}

extern "C" __declspec(dllexport) const char* StartNetworkMatch(char* matchID, char* playerList) {
    if (ptrStartMatch) return ptrStartMatch(matchID, playerList);
    return "Error: DLL Func Missing";
}

extern "C" __declspec(dllexport) const char* GetMyPublicKey() {
    if (ptrGetWalletPubKey) return ptrGetWalletPubKey();
    return "";
}