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
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/libp2p/go-libp2p"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	lp2pcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/discovery/routing"
	dutil "github.com/libp2p/go-libp2p/p2p/discovery/util"
	libp2pquic "github.com/libp2p/go-libp2p/p2p/transport/quic"
	"github.com/multiformats/go-multiaddr"
	"github.com/syndtr/goleveldb/leveldb"
)

var SteamAPIKey = os.Getenv("STEAM_API_KEY")

const GSI_PORT = "127.0.0.1:3000"
const MaxPayloadSize = 2048
const (
	FrameGame        = 0x01
	FrameHeartbeat   = 0x02
	ProtocolID       = "/eden-cs2/1.0.0"
	SyncProtocolID   = "/eden/sync/1.0.0"
	FriendProtocolID = "/eden/friend/1.0.0"
	FriendsDBFile    = "friends.json"
	TopicName        = "eden-consensus-v1"
)

var (
	h                 host.Host
	ctx               context.Context
	kademliaDHT       *dht.IpfsDHT
	streamLock        sync.Mutex
	pubSub            *pubsub.PubSub
	blockTopic        *pubsub.Topic
	currentMatchID    string
	lastBroadcastHash string
	lastBroadcastTime int64
	bettingTopic      *pubsub.Topic
	readyFeedTopic    *pubsub.Topic
	matchFeedTopic    *pubsub.Topic
	matchReadyStates  = make(map[string]map[string]bool)
	networkMatches    = make(map[string]MatchAnnouncement)
	readyMutex        sync.RWMutex
	matchesMutex      sync.RWMutex

	matchLive  bool   = false
	ctTeamName string = "CT Team"
	tTeamName  string = "T Team"

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

type ChainStatus struct {
	Height int    `json:"height"`
	Hash   string `json:"hash"`
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
	Player struct {
		SteamID    string `json:"steamid"`
		Name       string `json:"name"`
		Team       string `json:"team"`
		MatchStats struct {
			Kills   int `json:"kills"`
			Assists int `json:"assists"`
			Deaths  int `json:"deaths"`
			MVPs    int `json:"mvps"`
			Score   int `json:"score"`
		} `json:"match_stats"`
		State struct {
			Health     int `json:"health"`
			RoundKills int `json:"round_kills"`
		} `json:"state"`
	} `json:"player"`
}

type MatchReadyBroadcast struct {
	MatchID string `json:"match_id"`
	PeerID  string `json:"peer_id"`
}

type LiveMatchSession struct {
	MatchID     string
	CTCaptain   string
	TCaptain    string
	CTTeamName  string
	TTeamName   string
	SteamRoster map[string]string
	Scores      map[string]int
	Ratings     map[string]float64
}

type FriendInfo struct {
	Name       string `json:"name"`
	PeerID     string `json:"peer_id"`
	FriendCode string `json:"friend_code"`
	IsOnline   bool   `json:"is_online"`
	LastSeen   int64  `json:"last_seen"`
	Status     string `json:"status"`
}

type FriendHandshake struct {
	Type    string `json:"type"`
	Name    string `json:"name"`
	Message string `json:"message"`
}

type SyncRequest struct {
	Type  string `json:"type"`
	Index int    `json:"index"`
	Hash  string `json:"hash"`
	Limit int    `json:"limit"`
}

type SyncResponse struct {
	Height int     `json:"height"`
	Hash   string  `json:"hash"`
	Match  bool    `json:"match"`
	Blocks []Block `json:"blocks"`
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
	MatchID   string  `json:"match_id"`
	HostID    string  `json:"host_id"`
	MapName   string  `json:"map_name"`
	ScoreCT   int     `json:"score_ct"`
	ScoreT    int     `json:"score_t"`
	Phase     string  `json:"phase"`
	Timestamp int64   `json:"timestamp"`
	TotalPool float64 `json:"total_pool"`
	TeamAPool float64 `json:"team_a_pool"`
	TeamBPool float64 `json:"team_b_pool"`
}

var activeStreams = make(map[peer.ID]network.Stream)
var rendezvousString string
var MyFriends = make(map[string]FriendInfo)
var friendMutex sync.RWMutex
var netStats NetworkStats
var lastSeenPeer time.Time
var peerMutex sync.Mutex
var sessionMutex sync.RWMutex
var localGSIToken string
var friendStorePath string
var myPeerID string
var myPrivKey string
var myPubKey string
var state GSIState
var roundsPlayed int = 0
var activeSession *LiveMatchSession
var FriendSystemKey = []byte("0123456789ABCDEF0123456789ABCDEF")

//export UpdateMyProfile
func UpdateMyProfile(username *C.char, avatarURL *C.char) *C.char {
	user := C.GoString(username)
	url := C.GoString(avatarURL)

	payload := fmt.Sprintf("%s|%s", user, url)

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
	}

	tx := Transaction{
		ID:        fmt.Sprintf("prof_%d", time.Now().UnixNano()),
		Type:      TxTypeUpdateProfile,
		Sender:    h.ID().String(),
		Receiver:  "IDENTITY_CONTRACT",
		Amount:    0,
		Payload:   payload,
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	if err := SignTransaction(myPrivKey, &tx); err != nil {
		return C.CString("Error: Signing Failed")
	}

	EdenChain.Mutex.RLock()
	lastIndex := EdenChain.LastBlock.Index
	prevHash := EdenChain.LastBlock.Hash
	EdenChain.Mutex.RUnlock()

	newBlock := Block{
		Index:        lastIndex + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     prevHash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		return C.CString("Success")
	}
	return C.CString("Error: Block Rejected")
}

//export GetPeerProfile
func GetPeerProfile(peerID *C.char) *C.char {
	pid := C.GoString(peerID)
	if pid == "" {
		pid = h.ID().String()
	}

	EdenChain.Mutex.RLock()
	profile := EdenChain.GetOrInitProfile(pid)
	EdenChain.Mutex.RUnlock()

	data, _ := json.Marshal(profile)
	return C.CString(string(data))
}

func calculateRating(kills, deaths, assist, roundKills int) float64 {
	if deaths == 0 {
		deaths = 1
	}
	kdr := float64(kills) + (float64(assist)*0.5)/float64(deaths)
	impact := 1.0 + (float64(roundKills) * 0.1)
	rating := (kdr * 0.7) + (impact * 0.3)
	if rating < 0.1 {
		rating = 0.1
	}
	return rating
}

func getMachineToken() string {
	if localGSIToken != "" {
		return localGSIToken
	}
	data := []string{}

	if host, err := os.Hostname(); err == nil {
		data = append(data, host)
	}

	if interfaces, err := net.Interfaces(); err == nil {
		for _, i := range interfaces {
			if len(i.HardwareAddr) > 0 {
				data = append(data, i.HardwareAddr.String())
			}
		}
	}

	sort.Strings(data)

	rawString := strings.Join(data, "|")
	hash := sha256.Sum256([]byte(rawString))
	return hex.EncodeToString(hash[:16])
}

func StartGSIServer() {
	localGSIToken = getMachineToken()
	fmt.Printf("[GSI] Auth Token Required: %s\n\n", localGSIToken)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			return
		}

		clientToken := r.Header.Get("x-gsi-token")

		if clientToken != localGSIToken {
			fmt.Printf("[GSI] REJECTED: Invalid Auth Token from %s\n", r.RemoteAddr)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}

		body, _ := io.ReadAll(r.Body)
		var rawData map[string]interface{}
		json.Unmarshal(body, &rawData)
		json.Unmarshal(body, &state)
		w.WriteHeader(http.StatusOK)

		if state.Map.Phase == "warmup" {
			matchLive = false
		}

		if currentMatchID != "" && state.Map.Phase == "live" {
			matchLive = true
			sessionMutex.Lock()

			if activeSession == nil || activeSession.MatchID != currentMatchID {
				activeSession = &LiveMatchSession{
					MatchID:     currentMatchID,
					SteamRoster: make(map[string]string),
					Scores:      make(map[string]int),
					Ratings:     make(map[string]float64),
				}
				fmt.Println("[Match] New Session Initialized")
			}

			if activeSession == nil || activeSession.MatchID != currentMatchID {
				activeSession = &LiveMatchSession{
					MatchID:     currentMatchID,
					SteamRoster: make(map[string]string),
					Scores:      make(map[string]int),
				}
				fmt.Println("[Match] New Session Initialized")
			}

			if allPlayers, ok := rawData["allplayers"].(map[string]interface{}); ok {
				var topCTScore = -1
				var topTScore = -1
				var potentialCTCap = ""
				var potentialTCap = ""

				for steamID, pData := range allPlayers {
					pMap := pData.(map[string]interface{})
					name := pMap["name"].(string)
					team := pMap["team"].(string)

					matchStats := pMap["match_stats"].(map[string]interface{})
					score := int(matchStats["score"].(float64))
					kills := int(matchStats["kills"].(float64))
					assists := int(matchStats["assists"].(float64))
					deaths := int(matchStats["deaths"].(float64))

					roundKills := 0
					if stateMap, ok := pMap["state"].(map[string]interface{}); ok {
						if rk, ok := stateMap["round_kills"].(float64); ok {
							roundKills = int(rk)
						}
					}

					activeSession.SteamRoster[steamID] = team
					activeSession.Scores[steamID] = score
					activeSession.Ratings[steamID] = calculateRating(kills, deaths, assists, roundKills)

					if team == "CT" {
						if score > topCTScore {
							topCTScore = score
							potentialCTCap = name
						}
					} else if team == "T" {
						if score > topTScore {
							topTScore = score
							potentialTCap = name
						}
					}
				}

				if activeSession.CTTeamName == "" && potentialCTCap != "" {
					activeSession.CTCaptain = potentialCTCap
					activeSession.CTTeamName = fmt.Sprintf("%s's Team", potentialCTCap)
					fmt.Printf("[Match] CT Team locked as: %s\n", activeSession.CTTeamName)
				}
				if activeSession.TTeamName == "" && potentialTCap != "" {
					activeSession.TCaptain = potentialTCap
					activeSession.TTeamName = fmt.Sprintf("%s's Team", potentialTCap)
					fmt.Printf("[Match] T Team locked as: %s\n", activeSession.TTeamName)
				}
			}
			sessionMutex.Unlock()

			currentHash := fmt.Sprintf("%s-%d-%d-%s", state.Map.Phase, state.Map.TeamCT.Score, state.Map.TeamT.Score, state.Map.Name)
			now := time.Now().Unix()

			if currentHash != lastBroadcastHash || now-lastBroadcastTime >= 5 {
				sessionMutex.RLock()
				EdenChain.Mutex.RLock()
				var totalPool, poolA, poolB float64
				if pool, exists := EdenChain.ActivePools[currentMatchID]; exists {
					totalPool = pool.TotalPool
					poolA = pool.TeamAPool
					poolB = pool.TeamBPool
				}
				EdenChain.Mutex.RUnlock()

				ann := MatchAnnouncement{
					MatchID:   currentMatchID,
					HostID:    h.ID().String(),
					MapName:   state.Map.Name,
					ScoreCT:   state.Map.TeamCT.Score,
					ScoreT:    state.Map.TeamT.Score,
					Phase:     "live",
					Timestamp: now,
					TotalPool: totalPool,
					TeamAPool: poolA,
					TeamBPool: poolB,
				}
				sessionMutex.RUnlock()

				if data, err := json.Marshal(ann); err == nil {
					if matchFeedTopic != nil {
						matchFeedTopic.Publish(ctx, data)
					}
					lastBroadcastHash = currentHash
					lastBroadcastTime = now
				}
			}
		}

		if state.Map.Phase == "gameover" && currentMatchID != "" {
			sessionMutex.Lock()
			defer sessionMutex.Unlock()

			myVerdict := "CT"
			winningTeamName := activeSession.CTTeamName
			if state.Map.TeamT.Score > state.Map.TeamCT.Score {
				myVerdict = "T"
				winningTeamName = activeSession.TTeamName
			}

			mvpSteamID := "NONE"
			highestScore := -1

			for steamID, team := range activeSession.SteamRoster {
				if team == myVerdict {
					if score, ok := activeSession.Scores[steamID]; ok {
						if score > highestScore {
							highestScore = score
							mvpSteamID = steamID
						}
					}
				}
			}

			var alignmentParts []string
			for sID, team := range activeSession.SteamRoster {
				rating := activeSession.Ratings[sID]
				alignmentParts = append(alignmentParts, fmt.Sprintf("%s=%s=%.2f", sID, team, rating))
			}
			alignmentStr := strings.Join(alignmentParts, ",")

			fmt.Printf("[GSI] Match Ended. Winner: %s | MVP: %s. Broadcasting Vote...\n", winningTeamName, mvpSteamID)

			votePayload := fmt.Sprintf("%s:%s:%s:%s", currentMatchID, myVerdict, mvpSteamID, alignmentStr)

			pubKeyBytes, _ := hex.DecodeString(myPubKey)

			tx := Transaction{
				ID:        fmt.Sprintf("vote_%s_%s", currentMatchID, h.ID().String()),
				Type:      TxTypeWitness,
				Sender:    h.ID().String(),
				Receiver:  "CONSENSUS_ENGINE",
				Amount:    0,
				Payload:   votePayload,
				Timestamp: time.Now().Unix(),
				PublicKey: pubKeyBytes,
				Nonce:     GetNextNonce(h.ID().String()),
			}

			SignTransaction(myPrivKey, &tx)

			EdenChain.Mutex.RLock()
			lastIndex := EdenChain.LastBlock.Index
			prevHash := EdenChain.LastBlock.Hash
			EdenChain.Mutex.RUnlock()

			newBlock := Block{
				Index:        lastIndex + 1,
				Timestamp:    time.Now().Unix(),
				Transactions: []Transaction{tx},
				PrevHash:     prevHash,
			}
			newBlock.Hash = calculateHash(newBlock)

			if EdenChain.AddBlock(newBlock) {
				broadcastBlock(newBlock)
				fmt.Println("[GSI] Vote cast successfully.")
			}

			activeSession = nil
			currentMatchID = ""
		}
	})

	go http.ListenAndServe(GSI_PORT, nil)
	fmt.Printf("[GSI] Oracle listening on %s\n", GSI_PORT)
}

func EncryptFriendCode(peerID string) string {
	block, err := aes.NewCipher(FriendSystemKey)
	if err != nil {
		panic(err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		panic(err)
	}

	hash := sha256.Sum256([]byte(peerID))
	nonceSize := gcm.NonceSize()
	nonce := make([]byte, nonceSize)
	copy(nonce, hash[:nonceSize])
	ciphertext := gcm.Seal(nonce, nonce, []byte(peerID), nil)
	return base64.URLEncoding.EncodeToString(ciphertext)
}

func DecryptFriendCode(code string) (string, error) {
	data, err := base64.URLEncoding.DecodeString(code)
	if err != nil {
		return "", err
	}

	block, _ := aes.NewCipher(FriendSystemKey)
	gcm, _ := cipher.NewGCM(block)
	nonceSize := gcm.NonceSize()
	if len(data) < nonceSize {
		return "", fmt.Errorf("invalid code")
	}

	nonce, ciphertext := data[:nonceSize], data[nonceSize:]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return "", err
	}
	return string(plaintext), nil
}

func GetNextNonce(sender string) uint64 {
	EdenChain.Mutex.RLock()
	defer EdenChain.Mutex.RUnlock()
	return EdenChain.AccountNonces[sender] + 1
}

//export GenerateAndRegisterFriendCode
func GenerateAndRegisterFriendCode() *C.char {
	code := EncryptFriendCode(h.ID().String())

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
	}

	tx := Transaction{
		ID:        fmt.Sprintf("reg_%d", time.Now().UnixNano()),
		Type:      TxTypeRegisterFriend,
		Sender:    h.ID().String(),
		Receiver:  "FRIEND_REGISTRY",
		Amount:    0,
		Payload:   code,
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	SignTransaction(myPrivKey, &tx)

	EdenChain.Mutex.RLock()
	lastIndex := EdenChain.LastBlock.Index
	prevHash := EdenChain.LastBlock.Hash
	EdenChain.Mutex.RUnlock()

	newBlock := Block{
		Index:        lastIndex + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     prevHash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		return C.CString(code)
	}
	return C.CString("Error: Chain Rejected")
}

//export AddFriendByCode
func AddFriendByCode(code *C.char) *C.char {
	cStr := C.GoString(code)

	peerID, err := DecryptFriendCode(cStr)
	if err != nil {
		return C.CString("Error: Invalid Code")
	}

	EdenChain.Mutex.RLock()
	registeredOwner, exists := EdenChain.FriendRegistry[cStr]
	EdenChain.Mutex.RUnlock()

	if !exists {
		return C.CString("Error: Friend Code not found on blockchain. Please wait for confirmation.")
	}

	if registeredOwner != peerID {
		return C.CString("Error: Security Mismatch (Code owner does not match registry)")
	}

	friendMutex.Lock()
	MyFriends[peerID] = FriendInfo{
		Name:       "Pending Peer",
		PeerID:     peerID,
		FriendCode: cStr,
		IsOnline:   false,
		Status:     "Pending_Sent",
	}
	friendMutex.Unlock()

	SaveFriends()

	go SendFriendSignal(peerID, "REQUEST")

	return C.CString("Success: " + peerID)
}

//export FetchFriendList
func FetchFriendList() *C.char {
	friendMutex.Lock()
	defer friendMutex.Unlock()

	var list []FriendInfo

	for id, info := range MyFriends {
		if len(h.Peerstore().Addrs(peer.ID(id))) > 0 {
			info.IsOnline = true
		} else {
			info.IsOnline = false
		}
		list = append(list, info)
	}

	data, _ := json.Marshal(list)
	return C.CString(string(data))
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

func writeFrame(s network.Stream, data []byte) error {
	length := uint32(len(data))
	lenBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(lenBuf, length)

	if _, err := s.Write(lenBuf); err != nil {
		return err
	}
	if _, err := s.Write(data); err != nil {
		return err
	}
	return nil
}

func readFrame(s network.Stream) ([]byte, error) {
	lenBuf := make([]byte, 4)
	if _, err := io.ReadFull(s, lenBuf); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(lenBuf)

	if length > 10*1024*1024 {
		return nil, fmt.Errorf("message too large: %d bytes", length)
	}

	buf := make([]byte, length)
	if _, err := io.ReadFull(s, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

//export StartEdenNode
func StartEdenNode(virtualIP *C.char) *C.char {

	ctx = context.Background()

	InitializeWallet()

	privBytes, err := hex.DecodeString(myPrivKey)
	if err != nil {
		return C.CString("Error: Invalid Private Key Hex")
	}

	libp2pKey, err := lp2pcrypto.UnmarshalECDSAPrivateKey(privBytes)
	if err != nil {
		return C.CString("Error: Failed to convert to Libp2p Key: " + err.Error())
	}

	bootstrapPeers := []string{
		"/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
		"/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
		"/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
		"/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
		"/ip4/172.65.0.13/tcp/4009/p2p/QmcfgsJsMtx6qJb74akCw1M24X1zFwgGo11h1cuhwQjtJP",
	}

	var staticRelays []peer.AddrInfo
	for _, peerAddr := range bootstrapPeers {
		addr, err := multiaddr.NewMultiaddr(peerAddr)
		if err != nil {
			if peerInfo, err := peer.AddrInfoFromP2pAddr(addr); err == nil {
				staticRelays = append(staticRelays, *peerInfo)
			}
		}
	}

	h, err = libp2p.New(
		libp2p.Identity(libp2pKey),
		libp2p.EnableAutoNATv2(),
		libp2p.EnableHolePunching(),
		libp2p.Transport(libp2pquic.NewTransport),
		libp2p.ListenAddrStrings("/ip4/0.0.0.0/udp/0/quic-v1"),
		libp2p.EnableRelay(),
		libp2p.EnableHolePunching(),
		libp2p.EnableAutoRelayWithStaticRelays(staticRelays),
	)

	InitializeChain("./eden_db_" + h.ID().String())

	h.SetStreamHandler(SyncProtocolID, HandleSyncRequest)

	if err != nil {
		return C.CString("Error: " + err.Error())
	}

	kademliaDHT, _ = dht.New(ctx, h)
	kademliaDHT.Bootstrap(ctx)

	var wg sync.WaitGroup
	for _, p := range staticRelays {
		wg.Add(1)
		go func(pInfo peer.AddrInfo) {
			defer wg.Done()
			if err := h.Connect(ctx, pInfo); err != nil {
				fmt.Printf("[P2P] Failed to connect to bootstrap %s\n", pInfo.ID)
			} else {
				fmt.Printf("[P2P] Connected to Bootstrap Node: %s\n", pInfo.ID)
			}
		}(p)
	}
	wg.Wait()

	routingDiscovery := routing.NewRoutingDiscovery(kademliaDHT)
	rendezvousString = "eden-cs2-lobby-v1.0.0-prod"
	dutil.Advertise(ctx, routingDiscovery, rendezvousString)

	setupPubSub()

	LoadFriends()

	h.SetStreamHandler(FriendProtocolID, HandleFriendStream)

	h.SetStreamHandler(ProtocolID, func(s network.Stream) {
		fmt.Println("[P2P] Incoming Game Connection")
		streamLock.Lock()
		activeStreams[s.Conn().RemotePeer()] = s
		streamLock.Unlock()
		go readStreamLoop(s)
	})

	StartGSIServer()

	myPeerID = h.ID().String()
	fmt.Printf("[Eden] Node Started. ID: %s\n", h.ID().String())

	return C.CString(getIPFromPeerID(h.ID().String()))
}

func HandleFriendStream(s network.Stream) {
	defer s.Close()

	buf, err := readFrame(s)
	if err != nil {
		return
	}

	var msg FriendHandshake
	json.Unmarshal(buf, &msg)
	remotePID := s.Conn().RemotePeer().String()

	friendMutex.Lock()
	entry, exists := MyFriends[remotePID]

	switch msg.Type {
	case "REQUEST":
		if !exists {
			MyFriends[remotePID] = FriendInfo{
				Name:     msg.Name,
				PeerID:   remotePID,
				Status:   "Pending_Received",
				LastSeen: time.Now().Unix(),
			}
			fmt.Printf("[Friends] Received Request from %s\n", msg.Name)
		}

	case "ACCEPT":
		if exists {
			entry.Status = "Confirmed"
			entry.Name = msg.Name
			MyFriends[remotePID] = entry
			fmt.Printf("[Friends] Friend %s Confirmed!\n", msg.Name)
		}

	case "REJECT":
		if exists {
			delete(MyFriends, remotePID)
			fmt.Printf("[Friends] Request to %s was rejected.\n", msg.Name)
		}
	}
	friendMutex.Unlock()

	SaveFriends()
}

func HandleSyncRequest(s network.Stream) {
	defer s.Close()

	buf, err := readFrame(s)
	if err != nil {
		return
	}

	var req SyncRequest
	json.Unmarshal(buf, &req)

	EdenChain.Mutex.RLock()
	localHeight := EdenChain.LastBlock.Index + 1

	resp := SyncResponse{
		Height: localHeight,
	}

	switch req.Type {
	case "STATUS":
		if localHeight > 0 {
			resp.Hash = EdenChain.LastBlock.Hash
		}

	case "VERIFY":
		blocks := EdenChain.GetBlocksRange(req.Index, req.Index+1)
		if len(blocks) > 0 {
			localHash := blocks[0].Hash
			resp.Hash = localHash
			resp.Match = (localHash == req.Hash)
		} else {
			resp.Match = false
		}

	case "BLOCKS":
		if req.Index < localHeight {
			end := req.Index + req.Limit
			if end > localHeight {
				end = localHeight
			}
			resp.Blocks = EdenChain.GetBlocksRange(req.Index, end)
		}
	}
	EdenChain.Mutex.RUnlock()

	data, _ := json.Marshal(resp)
	writeFrame(s, data)
}

func (bc *Blockchain) GetBlocksRange(start, end int) []Block {
	var blocks []Block
	for i := start; i < end; i++ {
		key := fmt.Sprintf("block_%d", i)
		data, err := bc.Database.Get([]byte(key), nil)
		if err == nil {
			var b Block
			json.Unmarshal(data, &b)
			blocks = append(blocks, b)
		}
	}
	return blocks
}

func TriggerSync(pID peer.ID) {
	status, err := requestSync(pID, SyncRequest{Type: "STATUS"})
	if err != nil {
		return
	}

	EdenChain.Mutex.RLock()
	localHeight := EdenChain.LastBlock.Index + 1
	EdenChain.Mutex.RUnlock()

	fmt.Printf("[Sync] Peer Height: %d | Local Height: %d\n", status.Height, localHeight)

	if status.Height == 0 {
		return
	}

	low := 0
	high := localHeight - 1
	if status.Height-1 < high {
		high = status.Height - 1
	}

	ancestor := -1

	if high >= 0 {
		tipBlocks := EdenChain.GetBlocksRange(high, high+1)
		if len(tipBlocks) > 0 {
			tipCheck, _ := requestSync(pID, SyncRequest{
				Type:  "VERIFY",
				Index: high,
				Hash:  tipBlocks[0].Hash,
			})
			if tipCheck.Match {
				ancestor = high
			}
		}

	}

	if ancestor == -1 && localHeight > 0 {
		fmt.Println("[Sync] Fork detected! Searching for common ancestor...")
		for low <= high {
			mid := low + (high-low)/2

			midBlocks := EdenChain.GetBlocksRange(mid, mid+1)
			if len(midBlocks) == 0 {
				break
			}

			verifyResp, err := requestSync(pID, SyncRequest{
				Type:  "VERIFY",
				Index: mid,
				Hash:  midBlocks[0].Hash,
			})
			if err != nil {
				break
			}

			if verifyResp.Match {
				ancestor = mid
				low = mid + 1
			} else {
				high = mid - 1
			}
		}
	}

	if ancestor < localHeight-1 {
		fmt.Printf("[Sync] Reorganizing Chain. Rolling back from %d to %d\n", localHeight-1, ancestor)
		EdenChain.Mutex.Lock()

		batch := new(leveldb.Batch)
		for i := localHeight - 1; i > ancestor; i-- {
			key := fmt.Sprintf("block_%d", i)
			batch.Delete([]byte(key))
		}

		batch.Put([]byte("latest_index"), []byte(fmt.Sprintf("%d", ancestor)))
		EdenChain.Database.Write(batch, nil)

		EdenChain.Balances = make(map[string]float64)
		EdenChain.Profiles = make(map[string]*UserProfile)
		EdenChain.SteamToPeerID = make(map[string]string)
		EdenChain.ActiveAuctions = make(map[string]*Auction)
		EdenChain.ActivePools = make(map[string]*BettingPool)
		EdenChain.ActiveEscrows = make(map[string]*Escrow)
		EdenChain.AccountNonces = make(map[string]uint64)
		EdenChain.MatchSessions = make(map[string]MatchSessionInfo)
		EdenChain.MatchVotes = make(map[string]map[string]string)
		EdenChain.FriendRegistry = make(map[string]string)

		validBlocks := EdenChain.GetBlocksRange(0, ancestor+1)
		for _, b := range validBlocks {
			EdenChain.ProcessBlockState(b)
		}

		if len(validBlocks) > 0 {
			EdenChain.LastBlock = validBlocks[len(validBlocks)-1]
		} else {
			EdenChain.LastBlock = Block{Index: -1, Hash: "0"}
		}

		EdenChain.Mutex.Unlock()
	}

	startDownload := ancestor + 1
	for startDownload < status.Height {

		req := SyncRequest{
			Type:  "BLOCKS",
			Index: startDownload,
			Limit: 100,
		}

		resp, err := requestSync(pID, req)
		if err != nil {
			break
		}

		if len(resp.Blocks) == 0 {
			break
		}

		for _, b := range resp.Blocks {
			if !EdenChain.AddBlock(b) {
				fmt.Println("[Sync] Failed to append downloaded block. Chain invalid.")
				return
			}
		}
		startDownload += len(resp.Blocks)
	}

	fmt.Println("[Sync] Synchronization Complete.")
}

func requestSync(pID peer.ID, req SyncRequest) (SyncResponse, error) {
	s, err := h.NewStream(ctx, pID, SyncProtocolID)
	if err != nil {
		return SyncResponse{}, err
	}
	defer s.Close()

	reqData, _ := json.Marshal(req)
	if err := writeFrame(s, reqData); err != nil {
		return SyncResponse{}, err
	}

	buf, err := readFrame(s)
	if err != nil {
		return SyncResponse{}, err
	}

	var resp SyncResponse
	err = json.Unmarshal(buf, &resp)
	return resp, err
}

//export StartMatch
func StartMatch(matchID *C.char, playerList *C.char, password *C.char) *C.char {
	mID := C.GoString(matchID)
	rosterStr := C.GoString(playerList)
	serverPwd := C.GoString(password)

	currentMatchID = mID
	roster := strings.Split(rosterStr, ",")
	EdenChain.Mutex.RLock()
	var encryptedPasswords []string
	for _, peerID := range roster {
		peerPubKey, exists := EdenChain.PublicKeys[peerID]
		if !exists || peerID == h.ID().String() {
			encryptedPasswords = append(encryptedPasswords, "HOST")
			continue
		}

		aesKey, err := DeriveSharedAESKey(myPrivKey, peerPubKey)
		if err == nil {
			enc := EncryptPassword(aesKey, serverPwd)
			encryptedPasswords = append(encryptedPasswords, enc)
		} else {
			encryptedPasswords = append(encryptedPasswords, "ERR")
		}
	}
	EdenChain.Mutex.RUnlock()

	encPwdStr := strings.Join(encryptedPasswords, ",")
	finalPayload := fmt.Sprintf("%s|%s|%s", mID, rosterStr, encPwdStr)
	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
	}

	tx := Transaction{
		ID:        fmt.Sprintf("init_%s_%d", mID, time.Now().UnixNano()),
		Type:      "MATCH_START",
		Sender:    h.ID().String(),
		Receiver:  "CONSENSUS_ENGINE",
		Amount:    0,
		Payload:   finalPayload,
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	if !strings.Contains(rosterStr, h.ID().String()) {
		fmt.Println("[Security] Host attempted to start match without being in roster.")
		return C.CString("Error: Invalid Roster")
	}

	if err := SignTransaction(myPrivKey, &tx); err != nil {
		fmt.Printf("[Error] Failed to sign match start tx: %v\n", err)
		return C.CString("Error: Signing Failed")
	}

	EdenChain.Mutex.RLock()
	lastIndex := EdenChain.LastBlock.Index
	prevHash := EdenChain.LastBlock.Hash
	EdenChain.Mutex.RUnlock()

	newBlock := Block{
		Index:        lastIndex + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     prevHash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		fmt.Printf("[Lobby] Match %s successfully initialized on-chain.\n", mID)
		return C.CString("Success")
	}

	return C.CString("Error: Block Rejected")
}

//export GetMatchPassword
func GetMatchPassword(matchID *C.char) *C.char {
	mID := C.GoString(matchID)
	myID := h.ID().String()

	EdenChain.Mutex.RLock()
	defer EdenChain.Mutex.RUnlock()

	for i := EdenChain.LastBlock.Index; i >= 0; i-- {
		key := fmt.Sprintf("block_%d", i)
		data, err := EdenChain.Database.Get([]byte(key), nil)
		if err != nil {
			continue
		}

		var b Block
		json.Unmarshal(data, &b)

		for _, tx := range b.Transactions {
			if tx.Type == "MATCH_START" && strings.HasPrefix(tx.Payload, mID+"|") {
				parts := strings.Split(tx.Payload, "|")
				if len(parts) != 3 {
					return C.CString("")
				}

				roster := strings.Split(parts[1], ",")
				encPasswords := strings.Split(parts[2], ",")

				for idx, playerID := range roster {
					if playerID == myID && idx < len(encPasswords) {
						if encPasswords[idx] == "HOST" {
							return C.CString("")
						}

						hostPubKey := EdenChain.PublicKeys[tx.Sender]
						aesKey, err := DeriveSharedAESKey(myPrivKey, hostPubKey)
						if err != nil {
							return C.CString("Error: Crypto Failure")
						}

						plaintext := DecryptPassword(aesKey, encPasswords[idx])
						return C.CString(plaintext)
					}
				}
			}
		}
	}
	return C.CString("Error: Match Not Found")
}

//export StopEdenNode
func StopEdenNode() {
	streamLock.Lock()
	for _, s := range activeStreams {
		if s != nil {
			s.Close()
		}
	}

	activeStreams = make(map[peer.ID]network.Stream)
	streamLock.Unlock()
	if h != nil {
		h.Close()
	}
}

//export AbortMatch
func AbortMatch(matchID *C.char) *C.char {
	mID := C.GoString(matchID)

	pubKeyBytes, _ := hex.DecodeString(myPubKey)

	tx := Transaction{
		ID:        fmt.Sprintf("abort_%s_%d", mID, time.Now().UnixNano()),
		Type:      "MATCH_ABORT",
		Sender:    h.ID().String(),
		Receiver:  "CONSENSUS_ENGINE",
		Amount:    0,
		Payload:   mID,
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	if err := SignTransaction(myPrivKey, &tx); err != nil {
		return C.CString("Error: Signing Failed")
	}

	newBlock := Block{
		Index:        EdenChain.LastBlock.Index + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     EdenChain.LastBlock.Hash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		return C.CString("Success")
	}
	return C.CString("Error: Block Rejected")
}

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
	const KeyFileName = "eden_identity.key"
	if _, err := os.Stat(KeyFileName); err == nil {
		fmt.Println("[Wallet] Loading existing identity...")
		keyBytes, err := os.ReadFile(KeyFileName)
		if err == nil {
			savedPrivKeyHex := string(keyBytes)
			privBytes, err := hex.DecodeString(savedPrivKeyHex)
			if err == nil {
				privKey, err := x509.ParseECPrivateKey(privBytes)
				if err == nil {
					pubBytes, _ := x509.MarshalPKIXPublicKey(&privKey.PublicKey)
					myPrivKey = savedPrivKeyHex
					myPubKey = hex.EncodeToString(pubBytes)
					fmt.Printf("[Wallet] Identity Loaded. PubKey: %s...\n", myPubKey[:16])
					return
				}
			}
		}
		fmt.Println("[Wallet] Error loading key. Backup corrupted?")
	}

	fmt.Println("[Wallet] Generating NEW Identity...")
	myPrivKey, myPubKey = GenerateKeyPair()

	err := os.WriteFile(KeyFileName, []byte(myPrivKey), 0600)
	if err != nil {
		fmt.Printf("[Wallet] CRITICAL: Could not save identity to disk: %v\n", err)
	} else {
		fmt.Println("[Wallet] Identity saved to", KeyFileName)
	}
}

//export GetWalletPubKey
func GetWalletPubKey() *C.char {
	return C.CString(myPubKey)
}

//export GetWalletBalance
func GetWalletBalance(address *C.char) C.double {
	return C.double(EdenChain.GetBalance(C.GoString(address)))
}

//export ListSteamItem
func ListSteamItem(assetID *C.char, price C.double, durationSeconds C.int) *C.char {
	aID := C.GoString(assetID)
	p := float64(price)
	dur := int(durationSeconds)

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
	}

	tx := Transaction{
		ID:        fmt.Sprintf("list_%d", time.Now().UnixNano()),
		Type:      TxTypeList,
		Sender:    h.ID().String(),
		Receiver:  "MARKETPLACE",
		Amount:    p,
		Payload:   fmt.Sprintf("%s|%d", aID, dur),
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	newBlock := Block{
		Index:        EdenChain.LastBlock.Index + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     EdenChain.LastBlock.Hash,
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

	for k, v := range EdenChain.ActiveEscrows {
		if v.State == "FUNDED" && v.ExpiresAt <= now {
			toClose = append(toClose, k)
		}
	}
	EdenChain.Mutex.RUnlock()

	if len(toClose) == 0 {
		return C.CString("Nothing to clean")
	}

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
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
			PublicKey: pubKeyBytes,
			Nonce:     GetNextNonce(h.ID().String()),
		}

		newBlock := Block{
			Index:        EdenChain.LastBlock.Index + 1,
			Timestamp:    time.Now().Unix(),
			Transactions: []Transaction{tx},
			PrevHash:     EdenChain.LastBlock.Hash,
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

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
	}

	tx := Transaction{
		ID:        fmt.Sprintf("bet_%d", time.Now().UnixNano()),
		Type:      TxTypeBet,
		Sender:    h.ID().String(),
		Receiver:  "POOL_CONTRACT",
		Amount:    amt,
		Payload:   fmt.Sprintf("%s:%s", mID, tm),
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	newBlock := Block{
		Index:        EdenChain.LastBlock.Index + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     EdenChain.LastBlock.Hash,
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
		Sender:    h.ID().String(),
		Receiver:  r,
		Amount:    amt,
		Payload:   "",
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	err = SignTransaction(myPrivKey, &tx)
	if err != nil {
		fmt.Printf("[Error] Failed to sign transaction: %v\n", err)
		return 0
	}

	newBlock := Block{
		Index:        EdenChain.LastBlock.Index + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     EdenChain.LastBlock.Hash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		fmt.Printf("[Wallet] Sent %.2f EDN to %s (Tx: %s)\n", amt, r, tx.ID)
		return 1
	}
	return 0
}

func SendFriendSignal(peerIDStr string, signalType string) {
	pID, err := peer.Decode(peerIDStr)
	if err != nil {
		return
	}

	if h.Network().Connectedness(pID) != network.Connected {
		peerInfo, err := kademliaDHT.FindPeer(ctx, pID)
		if err == nil {
			h.Connect(ctx, peerInfo)
		}
	}

	s, err := h.NewStream(ctx, pID, FriendProtocolID)
	if err != nil {
		fmt.Printf("[Friends] Failed to open stream to %s\n", peerIDStr)
		return
	}
	defer s.Close()

	myID := h.ID().String()
	myName := "Unknown User"

	EdenChain.Mutex.RLock()
	if profile, exists := EdenChain.Profiles[myID]; exists {
		myName = profile.Username
	} else {
		myName = GenerateFixedUsername(myID)
	}
	EdenChain.Mutex.RUnlock()

	payload := FriendHandshake{
		Type:    signalType,
		Name:    myName,
		Message: "",
	}

	data, _ := json.Marshal(payload)
	writeFrame(s, data)
}

//export CreateEscrow
func CreateEscrow(sellerID *C.char, assetID *C.char, price C.double) *C.char {

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
	}

	tx := Transaction{
		ID:        fmt.Sprintf("escrow_%d", time.Now().UnixNano()),
		Type:      TxTypeEscrow,
		Sender:    h.ID().String(),
		Receiver:  C.GoString(sellerID),
		Amount:    float64(price),
		Payload:   C.GoString(assetID),
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	newBlock := Block{
		Index:        EdenChain.LastBlock.Index + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     EdenChain.LastBlock.Hash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		return C.CString(tx.ID)
	}
	return C.CString("Error: Escrow Broadcast Failed")
}

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
					settleTx := EdenChain.SettleEscrowByAsset(aid)
					if settleTx != nil {
						newBlock := Block{
							Index:        EdenChain.LastBlock.Index + 1,
							Timestamp:    time.Now().Unix(),
							Transactions: []Transaction{*settleTx},
							PrevHash:     EdenChain.LastBlock.Hash,
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

func getFriendFilePath() string {
	if friendStorePath != "" {
		return friendStorePath
	}
	return fmt.Sprintf("friends_%s.json", h.ID().String())
}

func SaveFriends() {
	friendMutex.Lock()
	defer friendMutex.Unlock()

	data, err := json.MarshalIndent(MyFriends, "", "  ")
	if err != nil {
		fmt.Printf("[Friends] Error marshalling data: %v\n", err)
		return
	}

	err = os.WriteFile(getFriendFilePath(), data, 0644)
	if err != nil {
		fmt.Printf("[Friends] Error saving to disk: %v\n", err)
	}
}

func LoadFriends() {
	friendMutex.Lock()
	defer friendMutex.Unlock()

	path := getFriendFilePath()
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return
	}

	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Printf("[Friends] Error reading file: %v\n", err)
		return
	}

	err = json.Unmarshal(data, &MyFriends)
	if err != nil {
		fmt.Printf("[Friends] Error parsing file: %v\n", err)
	} else {
		fmt.Printf("[Friends] Loaded %d friends from disk.\n", len(MyFriends))
	}
}

//export InitPacketBridge
func InitPacketBridge(fn C.InjectVPNPacketFn) {
	C.SetInjectPacketPointer(fn)
}

//export HandleOutboundPacket
func HandleOutboundPacket(data unsafe.Pointer, length C.int) {
	streamLock.Lock()
	streams := make([]network.Stream, 0, len(activeStreams))
	for _, s := range activeStreams {
		streams = append(streams, s)
	}
	streamLock.Unlock()

	if len(streams) == 0 {
		return
	}

	payloadLen := int(length)

	if payloadLen <= 0 || payloadLen > MaxPayloadSize {
		return
	}

	totalLen := 7 + payloadLen

	bufPtr := bufferPool.Get().([]byte)
	if cap(bufPtr) < totalLen {
		bufPtr = make([]byte, totalLen)
	}
	frame := bufPtr[:totalLen]

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

	for _, s := range streams {
		s.Write(frame)
	}

	bufferPool.Put(bufPtr)
}

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

	readyFeedTopic, _ = pubSub.Join("eden-match-ready")
	readySub, _ := readyFeedTopic.Subscribe()
	go func() {
		for {
			msg, err := readySub.Next(ctx)
			if err != nil {
				return
			}

			var ann MatchReadyBroadcast
			if err := json.Unmarshal(msg.Data, &ann); err == nil {
				readyMutex.Lock()
				if matchReadyStates[ann.MatchID] == nil {
					matchReadyStates[ann.MatchID] = make(map[string]bool)
				}
				matchReadyStates[ann.MatchID][ann.PeerID] = true
				readyMutex.Unlock()
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

//export RegisterMySteamID
func RegisterMySteamID(steamID *C.char) *C.char {
	sID := C.GoString(steamID)

	EdenChain.Mutex.RLock()
	existingOwner, exists := EdenChain.SteamToPeerID[sID]
	EdenChain.Mutex.RUnlock()

	if exists && existingOwner == h.ID().String() {
		return C.CString("Already Registered")
	}

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
	}

	tx := Transaction{
		ID:        fmt.Sprintf("reg_steam_%d", time.Now().UnixNano()),
		Type:      TxTypeRegisterSteamID,
		Sender:    h.ID().String(),
		Receiver:  "IDENTITY_CONTRACT",
		Amount:    0,
		Payload:   sID,
		Timestamp: time.Now().Unix(),
		PublicKey: pubKeyBytes,
		Nonce:     GetNextNonce(h.ID().String()),
	}

	if err := SignTransaction(myPrivKey, &tx); err != nil {
		return C.CString("Error: Signing Failed")
	}

	newBlock := Block{
		Index:        EdenChain.LastBlock.Index + 1,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{tx},
		PrevHash:     EdenChain.LastBlock.Hash,
	}
	newBlock.Hash = calculateHash(newBlock)

	if EdenChain.AddBlock(newBlock) {
		broadcastBlock(newBlock)
		return C.CString("Success")
	}
	return C.CString("Error: Block Rejected")
}

//export GetGSIToken
func GetGSIToken() *C.char {
	return C.CString(getMachineToken())
}

//export BroadcastMatchReady
func BroadcastMatchReady(matchID *C.char) {
	mID := C.GoString(matchID)

	ann := MatchReadyBroadcast{
		MatchID: mID,
		PeerID:  h.ID().String(),
	}

	if data, err := json.Marshal(ann); err == nil {
		readyFeedTopic.Publish(ctx, data)
		readyMutex.Lock()
		if matchReadyStates[mID] == nil {
			matchReadyStates[mID] = make(map[string]bool)
		}
		matchReadyStates[mID][h.ID().String()] = true
		readyMutex.Unlock()
	}
}

//export GetMatchReadyStates
func GetMatchReadyStates(matchID *C.char) *C.char {
	mID := C.GoString(matchID)

	readyMutex.RLock()
	defer readyMutex.RUnlock()

	states, exists := matchReadyStates[mID]
	if !exists {
		return C.CString("{}")
	}

	data, _ := json.Marshal(states)
	return C.CString(string(data))
}

//export GetMatchRoster
func GetMatchRoster(matchID *C.char) *C.char {
	mID := C.GoString(matchID)

	EdenChain.Mutex.RLock()
	defer EdenChain.Mutex.RUnlock()

	session, exists := EdenChain.MatchSessions[mID]
	if !exists {
		return C.CString("[]")
	}

	data, err := json.Marshal(session.Roster)
	if err != nil {
		return C.CString("[]")
	}

	return C.CString(string(data))
}

//export GetMyPeerID
func GetMyPeerID() *C.char {
	return C.CString(myPeerID)
}

//export RespondToFriendRequest
func RespondToFriendRequest(peerID *C.char, accept C.int) *C.char {
	pIDStr := C.GoString(peerID)
	isAccepting := int(accept) == 1
	friendMutex.Lock()
	entry, exists := MyFriends[pIDStr]
	friendMutex.Unlock()

	if !exists {
		return C.CString("Error: Friend request not found")
	}

	if isAccepting {
		friendMutex.Lock()
		entry.Status = "Confirmed"
		MyFriends[pIDStr] = entry
		friendMutex.Unlock()
		SaveFriends()
		go SendFriendSignal(pIDStr, "ACCEPT")
		return C.CString("Success: Friend Accepted")
	} else {
		friendMutex.Lock()
		delete(MyFriends, pIDStr)
		friendMutex.Unlock()
		SaveFriends()
		go SendFriendSignal(pIDStr, "REJECT")
		return C.CString("Success: Request Rejected")
	}
}

//export AdvertiseHostLobby
func AdvertiseHostLobby(mode *C.char, mapName *C.char) {
	modeStr := C.GoString(mode)
	mapStr := C.GoString(mapName)
	advString := fmt.Sprintf("eden-cs2-%s-%s-v1.0.0-pro", modeStr, mapStr)

	rd := routing.NewRoutingDiscovery(kademliaDHT)
	dutil.Advertise(ctx, rd, advString)
	fmt.Printf("[P2P] Now advertising as host for mode: %s\n", modeStr)
}

//export AutoConnectToPeers
func AutoConnectToPeers(targetMode *C.char, targetMap *C.char) *C.char {
	if kademliaDHT == nil {
		return C.CString("DHT Not Ready")
	}

	modeStr := C.GoString(targetMode)
	mapStr := C.GoString(targetMap)
	searchString := fmt.Sprintf("eden-cs2-%s-%s-v1.0.0-pro", modeStr, mapStr)

	rd := routing.NewRoutingDiscovery(kademliaDHT)
	peerChan, _ := rd.FindPeers(ctx, searchString)

	for p := range peerChan {
		if p.ID == h.ID() || len(p.Addrs) == 0 {
			matchesMutex.RLock()
			isHost := false
			for _, m := range networkMatches {
				if m.HostID == p.ID.String() {
					isHost = true
					break
				}
			}
			matchesMutex.RUnlock()

			if !isHost {
				continue
			}
		}

		if h.Connect(ctx, p) == nil {
			s, err := h.NewStream(ctx, p.ID, ProtocolID)
			if err == nil {
				streamLock.Lock()
				activeStreams[p.ID] = s
				streamLock.Unlock()
				go readStreamLoop(s)
				return C.CString(p.ID.String())
			}
			go TriggerSync(p.ID)
		}
	}
	return C.CString("No peers found")
}

//export ConnectToPeer
func ConnectToPeer(peerID *C.char) {
	if h == nil {
		return
	}
	pIDStr := C.GoString(peerID)
	targetID, err := peer.Decode(pIDStr)
	if err != nil {
		return
	}

	peerInfo, err := kademliaDHT.FindPeer(ctx, targetID)
	if err != nil {
		return
	}

	h.Connect(ctx, peerInfo)
}

//export IsPeerAlive
func IsPeerAlive() C.int {
	if h == nil {
		return 0
	}

	if len(h.Network().Peers()) > 0 {
		return 1
	}
	return 0
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
