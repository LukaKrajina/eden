package main

/*
#include <stdlib.h>
#include <stdint.h>

typedef void (*InjectVPNPacketFn)(void* data, int len);

static InjectVPNPacketFn ptrInjectVPNPacket = NULL;

static void SetInjectPacketPointer(InjectVPNPacketFn ptr) {
    ptrInjectVPNPacket = ptr;
}

static void CallInjectVPNPacket(void* data, int len) {
    if (ptrInjectVPNPacket != NULL) {
        ptrInjectVPNPacket(data, len);
    }
}

extern void HandleOutboundPacket(void* data, int len);
static void* GetGoCallback() {
    return (void*)HandleOutboundPacket;
}
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
	"unsafe"

	"github.com/libp2p/go-libp2p"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/p2p/discovery/routing"
	dutil "github.com/libp2p/go-libp2p/p2p/discovery/util"
)

// --- Steam Configuration ---
var SteamAPIKey = os.Getenv("STEAM_API_KEY")

const GSI_PORT = ":3000"

// --- Constants & Globals ---

const (
	FrameGame      = 0x01
	FrameHeartbeat = 0x02
	ProtocolID     = "/eden-cs2/1.0.0"
	TopicName      = "eden-consensus-v1"
)

var (
	h              host.Host
	ctx            context.Context
	kademliaDHT    *dht.IpfsDHT
	activeStream   network.Stream
	streamLock     sync.Mutex
	pubSub         *pubsub.PubSub
	blockTopic     *pubsub.Topic
	currentMatchID string
	bettingTopic   *pubsub.Topic

	bufferPool = sync.Pool{
		New: func() interface{} {
			return make([]byte, 4096)
		},
	}
)

type NetworkStats struct {
	sync.Mutex
	PacketsSent     uint64
	PacketsReceived uint64
	PacketsLost     uint64
	LastRemoteSeq   uint32
	LocalSeq        uint32
	IsInitialized   bool
}

type GSIState struct {
	Provider struct {
		SteamID   string `json:"steamid"`
		Timestamp int    `json:"timestamp"`
	} `json:"provider"`
	Map struct {
		Phase  string `json:"phase"` // "live", "gameover"
		Name   string `json:"name"`
		TeamCT struct {
			Score int `json:"score"`
		} `json:"team_ct"`
		TeamT struct {
			Score int `json:"score"`
		} `json:"team_t"`
	} `json:"map"`
}

type SteamTradeOfferResponse struct {
	Response struct {
		TradeOffersReceived []struct {
			TradeOfferID string `json:"tradeofferid"`
			State        int    `json:"trade_offer_state"`
			ItemsToGive  []struct {
				AssetID string `json:"assetid"`
				ClassID string `json:"classid"`
			} `json:"items_to_give"`
		} `json:"trade_offers_received"`
	} `json:"response"`
}

var netStats NetworkStats
var lastSeenPeer time.Time
var peerMutex sync.Mutex
var myPeerID string

// --- Game State Integration (GSI) Server ---

func StartGSIServer() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			return
		}

		body, _ := io.ReadAll(r.Body)
		var state GSIState
		json.Unmarshal(body, &state)

		w.WriteHeader(http.StatusOK)

		if state.Map.Phase == "gameover" && currentMatchID != "" {
			winningTeam := "CT"
			if state.Map.TeamT.Score > state.Map.TeamCT.Score {
				winningTeam = "T"
			}

			payoutTxs := EdenChain.ResolveMatch(currentMatchID, winningTeam)
			if len(payoutTxs) > 0 {
				newBlock := Block{
					Index:        len(EdenChain.Chain),
					Timestamp:    time.Now().Unix(),
					Transactions: payoutTxs,
					PrevHash:     EdenChain.Chain[len(EdenChain.Chain)-1].Hash,
				}
				newBlock.Hash = calculateHash(newBlock)

				if EdenChain.AddBlock(newBlock) {
					broadcastBlock(newBlock)
					fmt.Printf("[Oracle] Match %s resolved. Winner: %s. Broadcast Block #%d\n", currentMatchID, winningTeam, newBlock.Index)
				}
			}
			currentMatchID = ""
		}
	})

	go http.ListenAndServe(GSI_PORT, nil)
	fmt.Printf("[GSI] Oracle listening on %s\n", GSI_PORT)
}

// --- CGO Exports: Node Management ---

//export StartEdenNode
func StartEdenNode(virtualIP *C.char) *C.char {
	ctx = context.Background()

	InitializeChain()

	var err error
	h, err = libp2p.New(
		libp2p.ListenAddrStrings("/ip4/0.0.0.0/tcp/0"),
		libp2p.EnableAutoNATv2(),
		libp2p.EnableHolePunching(),
	)
	if err != nil {
		return C.CString("Error: " + err.Error())
	}

	kademliaDHT, _ = dht.New(ctx, h)
	kademliaDHT.Bootstrap(ctx)

	routingDiscovery := routing.NewRoutingDiscovery(kademliaDHT)
	dutil.Advertise(ctx, routingDiscovery, "eden-cs2-lobby")

	setupPubSub()

	h.SetStreamHandler(ProtocolID, func(s network.Stream) {
		fmt.Println("[P2P] Incoming Game Connection")
		streamLock.Lock()
		activeStream = s
		streamLock.Unlock()
		go readStreamLoop(s)
	})

	StartGSIServer()

	myPeerID = h.ID().String()
	fmt.Printf("[Eden] Node Started. ID: %s\n", h.ID().String())

	return C.CString(getIPFromPeerID(h.ID().String()))
}

//export StopEdenNode
func StopEdenNode() {
	streamLock.Lock()
	if activeStream != nil {
		activeStream.Close()
	}
	streamLock.Unlock()
	if h != nil {
		h.Close()
	}
}

// --- CGO Exports: Mining & Wallet ---

//export SubmitGameBlock
func SubmitGameBlock(duration C.int, playerCount C.int) *C.char {
	peerMutex.Lock()
	alive := time.Since(lastSeenPeer) < 15*time.Second
	peerMutex.Unlock()
	if !alive {
		return C.CString("Error: Node Offline")
	}

	proof := GameProof{
		MatchID:      fmt.Sprintf("match_%d", time.Now().Unix()),
		Duration:     int(duration),
		MaxPlayers:   int(playerCount),
		QualityScore: GetNetworkQuality(),
	}

	newBlock := EdenChain.CreateGameBlock(proof, h.ID().String())
	if newBlock.Hash == "" {
		return C.CString("Error: Block Creation Failed")
	}

	broadcastBlock(newBlock)
	return C.CString(newBlock.Hash)
}

//export GetWalletBalance
func GetWalletBalance(address *C.char) C.double {
	return C.double(EdenChain.GetBalance(C.GoString(address)))
}

// --- CGO Exports: Betting & Auctions ---
func PlaceBet(matchID *C.char, team *C.char, amount C.double) *C.char {
	mID := C.GoString(matchID)
	tm := C.GoString(team)
	amt := float64(amount)

	tx := Transaction{
		ID:        fmt.Sprintf("bet_%d", time.Now().UnixNano()),
		Type:      TxTypeBet,
		Sender:    h.ID().String(),
		Receiver:  "POOL_CONTRACT", // Logic handled in AddBlock
		Amount:    amt,
		Payload:   fmt.Sprintf("%s:%s", mID, tm),
		Timestamp: time.Now().Unix(),
	}

	// Wrap in a block (Simplified: normally goes to mempool)
	newBlock := Block{
		Index:        len(EdenChain.Chain),
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     EdenChain.Chain[len(EdenChain.Chain)-1].Hash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		return C.CString(tx.ID)
	}
	return C.CString("Error: Bet Failed")
}

//export CreateEscrow
func CreateEscrow(sellerID *C.char, assetID *C.char, price C.double) *C.char {
	tx := Transaction{
		ID:        fmt.Sprintf("escrow_%d", time.Now().UnixNano()),
		Type:      TxTypeEscrow,
		Sender:    h.ID().String(),
		Receiver:  C.GoString(sellerID),
		Amount:    float64(price),
		Payload:   C.GoString(assetID),
		Timestamp: time.Now().Unix(),
	}

	newBlock := Block{
		Index:        len(EdenChain.Chain),
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     EdenChain.Chain[len(EdenChain.Chain)-1].Hash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		return C.CString(tx.ID)
	}
	return C.CString("Error: Escrow Broadcast Failed")
}

// --- Steam Oracle Logic ---

//export VerifySteamTrade
func VerifySteamTrade(tradeOfferID *C.char, expectedAssetID *C.char) C.int {
	tid := C.GoString(tradeOfferID)
	aid := C.GoString(expectedAssetID)
	url := fmt.Sprintf("https://api.steampowered.com/IEconService/GetTradeOffer/v1/?key=%s&tradeofferid=%s&language=en_us", SteamAPIKey, tid)
	resp, err := http.Get(url)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var data SteamTradeOfferResponse
	json.Unmarshal(body, &data)

	if len(data.Response.TradeOffersReceived) > 0 {
		offer := data.Response.TradeOffersReceived[0]
		if offer.State == 3 {
			for _, item := range offer.ItemsToGive {
				if item.AssetID == aid {
					settleTx := EdenChain.SettleEscrow(tid)
					if settleTx != nil {
						newBlock := Block{
							Index:        len(EdenChain.Chain),
							Timestamp:    time.Now().Unix(),
							Transactions: []Transaction{*settleTx},
							PrevHash:     EdenChain.Chain[len(EdenChain.Chain)-1].Hash,
						}
						newBlock.Hash = calculateHash(newBlock)

						if EdenChain.AddBlock(newBlock) {
							broadcastBlock(newBlock)
							return 1
						}
					}
				}
			}
		}
	}
	return 0
}

//export SetSteamAPIKey
func SetSteamAPIKey(key *C.char) {
	SteamAPIKey = C.GoString(key)
	fmt.Println("[Eden] Steam API Key updated via C-API")
}

// --- CGO Exports: Networking ---

//export InitPacketBridge
func InitPacketBridge(fn C.InjectVPNPacketFn) {
	C.SetInjectPacketPointer(fn)
}

//export HandleOutboundPacket
func HandleOutboundPacket(data unsafe.Pointer, len C.int) {
	streamLock.Lock()
	s := activeStream
	streamLock.Unlock()

	if s == nil {
		return
	}

	payloadLen := int(len)
	totalLen := 7 + payloadLen

	bufPtr := bufferPool.Get().([]byte)
	if cap(bufPtr) < totalLen {
		bufPtr = make([]byte, totalLen)
	}
	frame := bufPtr[:totalLen]

	// Header Construction
	netStats.Lock()
	netStats.LocalSeq++
	seq := netStats.LocalSeq
	netStats.PacketsSent++
	netStats.Unlock()

	frame[0] = FrameGame
	frame[1] = byte(uint16(payloadLen) >> 8)
	frame[2] = byte(uint16(payloadLen))
	frame[3] = byte(seq >> 24)
	frame[4] = byte(seq >> 16)
	frame[5] = byte(seq >> 8)
	frame[6] = byte(seq)

	cData := unsafe.Slice((*byte)(data), payloadLen)
	copy(frame[7:], cData)

	s.Write(frame)

	bufferPool.Put(bufPtr)
}

// --- Internal Networking Logic ---

func readStreamLoop(s network.Stream) {
	defer s.Close()
	header := make([]byte, 7)

	for {
		if _, err := io.ReadFull(s, header); err != nil {
			return
		}

		payloadLen := uint16(header[1])<<8 | uint16(header[2])
		remoteSeq := uint32(header[3])<<24 | uint32(header[4])<<16 | uint32(header[5])<<8 | uint32(header[6])

		updateNetworkStats(remoteSeq)

		if header[0] == FrameHeartbeat {
			continue
		}

		if payloadLen > 0 {
			bufPtr := bufferPool.Get().([]byte)
			if cap(bufPtr) < int(payloadLen) {
				bufPtr = make([]byte, int(payloadLen))
			}
			payload := bufPtr[:payloadLen]

			if _, err := io.ReadFull(s, payload); err != nil {
				bufferPool.Put(bufPtr)
				return
			}

			cPtr := C.CBytes(payload)
			C.CallInjectVPNPacket(cPtr, C.int(payloadLen))
			C.free(cPtr)

			bufferPool.Put(bufPtr)
		}
	}
}

func updateNetworkStats(remoteSeq uint32) {
	netStats.Lock()
	defer netStats.Unlock()

	if !netStats.IsInitialized {
		netStats.IsInitialized = true
	} else if remoteSeq > netStats.LastRemoteSeq+1 {
		netStats.PacketsLost += uint64(remoteSeq - netStats.LastRemoteSeq - 1)
	}

	netStats.LastRemoteSeq = remoteSeq
	netStats.PacketsReceived++

	peerMutex.Lock()
	lastSeenPeer = time.Now()
	peerMutex.Unlock()
}

func GetNetworkQuality() int {
	netStats.Lock()
	defer netStats.Unlock()
	total := netStats.PacketsReceived + netStats.PacketsLost
	if total == 0 {
		return 100
	}
	lossRate := float64(netStats.PacketsLost) / float64(total)
	score := 100 - int(lossRate*100)
	if score < 0 {
		return 0
	}
	return score
}

// --- PubSub & Sync ---

func setupPubSub() {
	var err error
	pubSub, err = pubsub.NewGossipSub(ctx, h)
	if err != nil {
		return
	}

	blockTopic, err = pubSub.Join(TopicName)
	if err != nil {
		return
	}

	sub, _ := blockTopic.Subscribe()
	go func() {
		for {
			msg, err := sub.Next(ctx)
			if err != nil {
				return
			}
			if msg.ReceivedFrom == h.ID() {
				continue
			}

			var b Block
			if err := json.Unmarshal(msg.Data, &b); err == nil {
				if EdenChain.AddBlock(b) {
					fmt.Printf("[Sync] Accepted Block #%d from %s\n", b.Index, msg.ReceivedFrom)
				}
			}
		}
	}()
}

func broadcastBlock(b Block) {
	if blockTopic == nil {
		return
	}
	data, _ := json.Marshal(b)
	blockTopic.Publish(ctx, data)
}

// --- Helpers ---

//export GetMyPeerID
func GetMyPeerID() *C.char {
	return C.CString(myPeerID)
}

//export AutoConnectToPeers
func AutoConnectToPeers() *C.char {
	if kademliaDHT == nil {
		return C.CString("DHT Not Ready")
	}

	rd := routing.NewRoutingDiscovery(kademliaDHT)
	peerChan, _ := rd.FindPeers(ctx, "eden-cs2-lobby")

	for p := range peerChan {
		if p.ID == h.ID() || len(p.Addrs) == 0 {
			continue
		}

		if h.Connect(ctx, p) == nil {
			s, err := h.NewStream(ctx, p.ID, ProtocolID)
			if err == nil {
				streamLock.Lock()
				activeStream = s
				streamLock.Unlock()
				go readStreamLoop(s)
				return C.CString(p.ID.String())
			}
		}
	}
	return C.CString("No peers found")
}

//export GetIPForPeer
func GetIPForPeer(peerIDStr *C.char) *C.char {
	return C.CString(getIPFromPeerID(C.GoString(peerIDStr)))
}

func getIPFromPeerID(pid string) string {
	sum := 0
	for _, char := range pid {
		sum += int(char)
	}
	return fmt.Sprintf("10.6.0.%d", (sum%250)+2)
}

func main() {}
