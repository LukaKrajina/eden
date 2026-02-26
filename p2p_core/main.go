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
	"crypto/sha256"
	"encoding/hex"
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

const GSI_PORT = "127.0.0.1:3000"
const MaxPayloadSize = 2048

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
	matchFeedTopic *pubsub.Topic
	networkMatches = make(map[string]MatchAnnouncement)
	matchesMutex   sync.RWMutex

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
		Phase  string `json:"phase"`
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

type SteamInventoryResponse struct {
	Assets []struct {
		AppID      int    `json:"appid"`
		ContextID  string `json:"contextid"`
		AssetID    string `json:"assetid"`
		ClassID    string `json:"classid"`
		InstanceID string `json:"instanceid"`
		Amount     string `json:"amount"`
	} `json:"assets"`
	Descriptions []struct {
		ClassID        string `json:"classid"`
		InstanceID     string `json:"instanceid"`
		MarketHashName string `json:"market_hash_name"`
		IconUrl        string `json:"icon_url"`
		Descriptions   []struct {
			Value string `json:"value"`
		} `json:"descriptions"`
		Tags []struct {
			Category string `json:"category"`
			Name     string `json:"name"`
		} `json:"tags"`
	} `json:"descriptions"`
}

type RichItem struct {
	AssetID  string `json:"asset_id"`
	Name     string `json:"name"`
	ImageURL string `json:"image_url"`
	Wear     string `json:"wear"`
	Quality  string `json:"quality"`
}

type MatchAnnouncement struct {
	MatchID   string `json:"match_id"`
	HostID    string `json:"host_id"`
	MapName   string `json:"map_name"`
	ScoreCT   int    `json:"score_ct"`
	ScoreT    int    `json:"score_t"`
	Phase     string `json:"phase"`
	Timestamp int64  `json:"timestamp"`
}

var netStats NetworkStats
var lastSeenPeer time.Time
var peerMutex sync.Mutex
var myPeerID string
var myPrivKey string
var myPubKey string

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

		if currentMatchID != "" && state.Map.Phase == "live" {
			if time.Now().Unix()%5 == 0 {
				ann := MatchAnnouncement{
					MatchID:   currentMatchID,
					HostID:    h.ID().String(),
					MapName:   state.Map.Name,
					ScoreCT:   state.Map.TeamCT.Score,
					ScoreT:    state.Map.TeamT.Score,
					Phase:     "live",
					Timestamp: time.Now().Unix(),
				}

				if data, err := json.Marshal(ann); err == nil {
					if matchFeedTopic != nil {
						matchFeedTopic.Publish(ctx, data)
					}
				}
			}
		}

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

//export GetNetworkMatches
func GetNetworkMatches() *C.char {
	matchesMutex.RLock()
	defer matchesMutex.RUnlock()

	var active []MatchAnnouncement
	now := time.Now().Unix()

	for id, m := range networkMatches {
		if now-m.Timestamp < 60 {
			active = append(active, m)
		} else {
			delete(networkMatches, id)
		}
	}

	data, _ := json.Marshal(active)
	return C.CString(string(data))
}

// --- CGO Exports: Node Management ---

//export StartEdenNode
func StartEdenNode(virtualIP *C.char) *C.char {
	ctx = context.Background()

	InitializeChain()

	InitializeWallet()

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

	// --- ADD THIS SECTION: DEV AIRDROP ---
	// Automatically mint 1000 EDN to self for testing
	airdropTx := Transaction{
		ID:        fmt.Sprintf("genesis_drop_%d", time.Now().UnixNano()),
		Type:      TxTypeTransfer,
		Sender:    "SYSTEM_MINT", // Bypasses balance check
		Receiver:  myPeerID,
		Amount:    1000.0,
		Timestamp: time.Now().Unix(),
		Signature: "DEV_AIRDROP",
	}

	// Create a block for this airdrop
	airdropBlock := Block{
		Index:        len(EdenChain.Chain),
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{airdropTx},
		PrevHash:     EdenChain.Chain[len(EdenChain.Chain)-1].Hash,
	}
	// Note: You need to make calculateHash exported (Capitalize to CalculateHash)
	// OR just copy the hashing logic here if it's private in blockchain.go.
	// Assuming you capitalized it or it's accessible:
	airdropBlock.Hash = calculateHash(airdropBlock)

	if EdenChain.AddBlock(airdropBlock) {
		fmt.Println("[Eden] Dev Airdrop: +1000 EDN minted to local wallet.")
	}

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

func InitializeWallet() {
	myPrivKey, myPubKey = GenerateKeyPair()
	fmt.Println("[Wallet] Generated Keys. Public:", myPubKey)
}

//export GetWalletPubKey
func GetWalletPubKey() string {
	return myPubKey
}

//export GetWalletBalance
func GetWalletBalance(address *C.char) C.double {
	return C.double(EdenChain.GetBalance(C.GoString(address)))
}

// --- CGO Exports: Betting & Auctions ---

//export ListSteamItem
func ListSteamItem(assetID *C.char, price C.double, durationSeconds C.int) *C.char {
	aID := C.GoString(assetID)
	p := float64(price)
	dur := int(durationSeconds)

	tx := Transaction{
		ID:        fmt.Sprintf("list_%d", time.Now().UnixNano()),
		Type:      TxTypeList,
		Sender:    h.ID().String(),
		Receiver:  "MARKETPLACE",
		Amount:    p,
		Payload:   fmt.Sprintf("%s|%d", aID, dur),
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
		return C.CString("Success")
	}
	return C.CString("Error: Listing Failed")
}

//export GetOpenAuctions
func GetOpenAuctions() *C.char {
	EdenChain.Mutex.RLock()
	defer EdenChain.Mutex.RUnlock()

	var active []Auction

	for _, v := range EdenChain.ActiveAuctions {
		if v.State == "OPEN" {
			active = append(active, *v)
		}
	}

	data, err := json.Marshal(active)
	if err != nil {
		return C.CString("[]")
	}
	return C.CString(string(data))
}

//export TriggerExpirationCleanup
func TriggerExpirationCleanup() *C.char {
	EdenChain.Mutex.RLock()
	var toClose []string
	now := time.Now().Unix()

	for k, v := range EdenChain.ActiveAuctions {
		if v.State == "OPEN" && v.ExpiresAt <= now {
			toClose = append(toClose, k)
		}
	}
	EdenChain.Mutex.RUnlock()

	if len(toClose) == 0 {
		return C.CString("Nothing to clean")
	}

	count := 0
	for _, auctionID := range toClose {
		tx := Transaction{
			ID:        fmt.Sprintf("expire_%s_%d", auctionID, time.Now().UnixNano()),
			Type:      TxTypeCloseExpired,
			Sender:    h.ID().String(),
			Receiver:  "MARKETPLACE",
			Amount:    0,
			Payload:   auctionID,
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
			count++
		}
	}

	return C.CString(fmt.Sprintf("Cleaned %d auctions", count))
}

//export PlaceBet
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

//export SendTransaction
func SendTransaction(receiver *C.char, amount C.double) C.int {
	r := C.GoString(receiver)
	amt := float64(amount)

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		fmt.Printf("[Error] Invalid local public key hex: %v\n", err)
		return 0
	}

	tx := Transaction{
		ID:        fmt.Sprintf("tx_%d", time.Now().UnixNano()),
		Type:      TxTypeTransfer,
		Sender:    myPubKey,
		Receiver:  r,
		Amount:    amt,
		Payload:   "",
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
	}

	err = SignTransaction(myPrivKey, &tx)
	if err != nil {
		fmt.Printf("[Error] Failed to sign transaction: %v\n", err)
		return 0
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
		fmt.Printf("[Wallet] Sent %.2f EDN to %s (Tx: %s)\n", amt, r, tx.ID)
		return 1
	}
	return 0
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

//export FetchMyInventory
func FetchMyInventory(steamID *C.char) *C.char {
	sID := C.GoString(steamID)
	url := fmt.Sprintf("https://steamcommunity.com/inventory/%s/730/2?l=english&count=100", sID)

	resp, err := http.Get(url)
	if err != nil {
		return C.CString("[]")
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var data SteamInventoryResponse
	json.Unmarshal(body, &data)
	//descMap := make(map[string]SteamInventoryResponse)
	type Key struct {
		ClassID, InstanceID string
	}
	lookup := make(map[Key]int)
	for i, d := range data.Descriptions {
		lookup[Key{d.ClassID, d.InstanceID}] = i
	}

	var richItems []RichItem

	for _, asset := range data.Assets {
		if idx, found := lookup[Key{asset.ClassID, asset.InstanceID}]; found {
			desc := data.Descriptions[idx]

			// Extract Wear (Float) - usually in descriptions or "inspect" link
			// For WebAPI, wear is often hidden, but "Exterior" is a tag.
			wear := "Unknown"
			quality := "Normal"

			for _, tag := range desc.Tags {
				if tag.Category == "Exterior" {
					wear = tag.Name
				}
				if tag.Category == "Rarity" {
					quality = tag.Name
				}
			}

			img := fmt.Sprintf("https://community.cloudflare.steamstatic.com/economy/image/%s/360fx360f", desc.IconUrl)

			richItems = append(richItems, RichItem{
				AssetID:  asset.AssetID,
				Name:     desc.MarketHashName,
				ImageURL: img,
				Wear:     wear,
				Quality:  quality,
			})
		}
	}

	jsonData, _ := json.Marshal(richItems)
	return C.CString(string(jsonData))
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

		if payloadLen > MaxPayloadSize {
			fmt.Printf("[Security] Peer sent oversized packet: %d\n", payloadLen)
			s.Close()
			return
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

	matchFeedTopic, _ = pubSub.Join("eden-matches")
	matchSub, _ := matchFeedTopic.Subscribe()
	go func() {
		for {
			msg, err := matchSub.Next(ctx)
			if err != nil {
				return
			}
			if msg.ReceivedFrom == h.ID() {
				continue
			}

			var ann MatchAnnouncement
			if err := json.Unmarshal(msg.Data, &ann); err == nil {
				matchesMutex.Lock()
				if time.Now().Unix()-ann.Timestamp < 60 {
					networkMatches[ann.MatchID] = ann
				}
				matchesMutex.Unlock()
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
	h := sha256.Sum256([]byte(pid))
	return fmt.Sprintf("10.%d.%d.%d", h[0], h[1], h[2])
}

//export FreeString
func FreeString(str *C.char) {
	C.free(unsafe.Pointer(str))
}

func main() {}
