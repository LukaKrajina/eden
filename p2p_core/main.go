package main

/*
#include <stdlib.h>
#include <stdint.h>

typedef void (*InjectVPNPacketFn)(void* data, int len);

typedef void (*MatchFoundCallbackFn)(char* matchID, char* hostID, char* rosterList);

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

static MatchFoundCallbackFn ptrMatchFoundCallback = NULL;

static void SetMatchFoundCallback(MatchFoundCallbackFn ptr) {
    ptrMatchFoundCallback = ptr;
}

static void CallMatchFound(char* matchID, char* hostID, char* rosterList) {
    if (ptrMatchFoundCallback != NULL) {
        ptrMatchFoundCallback(matchID, hostID, rosterList);
    }
}
*/
import "C"

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/golang/geo/r3"
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
	demoinfocs "github.com/markus-wa/demoinfocs-golang/v4/pkg/demoinfocs"
	"github.com/markus-wa/demoinfocs-golang/v4/pkg/demoinfocs/common"
	events "github.com/markus-wa/demoinfocs-golang/v4/pkg/demoinfocs/events"
	"github.com/multiformats/go-multiaddr"
	"github.com/syndtr/goleveldb/leveldb"
)

var SteamAPIKey = os.Getenv("STEAM_API_KEY")

const GSI_PORT = "127.0.0.1:3000"
const MaxPayloadSize = 2048
const (
	FrameGame          = 0x01
	FrameHeartbeat     = 0x02
	ProtocolID         = "/eden-cs2/1.0.0"
	SyncProtocolID     = "/eden/sync/1.0.0"
	FriendProtocolID   = "/eden/friend/1.0.0"
	FriendsDBFile      = "friends.json"
	TopicName          = "eden-consensus-v1"
	QueueTopicName     = "eden-queue-v1"
	ProposalTopicName  = "eden-proposals-v1"
	ValidatorTopicName = "eden-validators-v1"
	DemoProtocolID     = "/eden/demo/1.0.0"
)

var (
	h                 host.Host
	ctx               context.Context
	nodeCancel        context.CancelFunc
	kademliaDHT       *dht.IpfsDHT
	pubSub            *pubsub.PubSub
	currentMatchID    string
	lastBroadcastHash string
	lastBroadcastTime int64
	blockTopic        *pubsub.Topic
	bettingTopic      *pubsub.Topic
	readyFeedTopic    *pubsub.Topic
	matchFeedTopic    *pubsub.Topic
	queueTopic        *pubsub.Topic
	proposalTopic     *pubsub.Topic
	vetoTopic         *pubsub.Topic
	validatorTopic    *pubsub.Topic
	inQueue           bool
	myCurrentTicket   string
	bestProposal      LobbyProposal
	proposalTimer     *time.Timer
	streamLock        sync.Mutex
	queueMutex        sync.RWMutex
	proposalMutex     sync.Mutex
	vetoMutex         sync.RWMutex
	readyMutex        sync.RWMutex
	matchesMutex      sync.RWMutex
	sigsMutex         sync.Mutex

	matchLive        bool   = false
	ctTeamName       string = "CT Team"
	tTeamName        string = "T Team"
	vpnEgressQueue          = make(chan []byte, 4096)
	matchReadyStates        = make(map[string]map[string]bool)
	networkMatches          = make(map[string]MatchAnnouncement)
	activeTickets           = make(map[string]MatchmakingTicket)
	matchVetoes             = make(map[string][]string)
	pendingBlockSigs        = make(map[string]map[string]string)
	recentAngles            = make(map[uint64][]PlayerState)

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

type PlayerState struct {
	ViewDirection r3.Vector
	Tick          int
}

type MatchmakingTicket struct {
	TicketID     string   `json:"ticket_id"`
	LeaderID     string   `json:"leader_id"`
	PartyMembers []string `json:"party_members"`
	AverageElo   float64  `json:"average_elo"`
	Mode         string   `json:"mode"`
	Timestamp    int64    `json:"timestamp"`
}

type LobbyProposal struct {
	ProposalID string   `json:"proposal_id"`
	HostID     string   `json:"host_id"`
	Mode       string   `json:"mode"`
	Players    []string `json:"players"`
	AverageElo float64  `json:"average_elo"`
	Timestamp  int64    `json:"timestamp"`
}

type BlockProposal struct {
	ProposerID string `json:"proposer_id"`
	BlockData  Block  `json:"block_data"`
}

type BlockSignature struct {
	ValidatorID string `json:"validator_id"`
	BlockHash   string `json:"block_hash"`
	Signature   string `json:"signature"`
}

type ValidatorMessage struct {
	Type    string `json:"type"`
	Payload []byte `json:"payload"`
}

type VetoBroadcast struct {
	MatchID string `json:"match_id"`
	PeerID  string `json:"peer_id"`
	MapName string `json:"map_name"`
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

type DemoRequest struct {
	MatchID string `json:"match_id"`
}

type DemoResponse struct {
	Status   string `json:"status"`
	FileSize int64  `json:"file_size"`
}

type SyncRequest struct {
	Type        string  `json:"type"`
	Index       int     `json:"index"`
	Hash        string  `json:"hash"`
	Limit       int     `json:"limit"`
	ChainWeight float64 `json:"chain_weight"`
}

type SyncResponse struct {
	Height      int     `json:"height"`
	Hash        string  `json:"hash"`
	Match       bool    `json:"match"`
	Blocks      []Block `json:"blocks"`
	ChainWeight float64 `json:"chain_weight"`
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
var routingTable = make(map[string]network.Stream)
var rendezvousString string
var MyFriends = make(map[string]FriendInfo)
var friendMutex sync.RWMutex
var netStats NetworkStats
var lastSeenPeer time.Time
var peerMutex sync.Mutex
var sessionMutex sync.RWMutex
var statsMutex sync.RWMutex
var localGSIToken string
var friendStorePath string
var myPeerID string
var myPrivKey string
var myPubKey string
var state GSIState
var roundsPlayed int = 0
var activeSession *LiveMatchSession
var FriendSystemKey = []byte("0123456789ABCDEF0123456789ABCDEF")
var FinalMatchStats = make(map[string]map[string]interface{})

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

func StartVPNEgressWorker() {
	go func() {
		for frame := range vpnEgressQueue {
			if len(frame) < 27 {
				continue
			}

			destIP := net.IPv4(frame[7+16], frame[7+17], frame[7+18], frame[7+19]).String()

			streamLock.Lock()
			targetStream, isUnicast := routingTable[destIP]

			if isUnicast {
				targetStream.SetWriteDeadline(time.Now().Add(15 * time.Millisecond))
				_, err := targetStream.Write(frame)
				if err != nil {
					targetStream.SetWriteDeadline(time.Time{})
				}
				streamLock.Unlock()

			} else if destIP == "255.255.255.255" || strings.HasSuffix(destIP, ".255") {
				streamsCopy := make([]network.Stream, 0, len(activeStreams))
				for _, s := range activeStreams {
					streamsCopy = append(streamsCopy, s)
				}
				streamLock.Unlock()

				for _, s := range streamsCopy {
					s.SetWriteDeadline(time.Now().Add(15 * time.Millisecond))
					s.Write(frame)
					s.SetWriteDeadline(time.Time{})
				}
			} else {
				streamLock.Unlock()
			}
		}
	}()
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

		var localState GSIState

		body, _ := io.ReadAll(r.Body)
		var rawData map[string]interface{}
		json.Unmarshal(body, &rawData)
		json.Unmarshal(body, &localState)
		w.WriteHeader(http.StatusOK)

		sessionMutex.Lock()
		state = localState
		sessionMutex.Unlock()

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

			statsMutex.Lock()
			matchStats := make(map[string]interface{})
			if allPlayers, ok := rawData["allplayers"].(map[string]interface{}); ok {
				for steamID, pData := range allPlayers {
					pMap := pData.(map[string]interface{})
					if matchStatsMap, ok := pMap["match_stats"].(map[string]interface{}); ok {
						kills := int(matchStatsMap["kills"].(float64))
						assists := int(matchStatsMap["assists"].(float64))
						deaths := int(matchStatsMap["deaths"].(float64))

						EdenChain.Mutex.RLock()
						peerID := EdenChain.SteamToPeerID[steamID]
						EdenChain.Mutex.RUnlock()

						if peerID != "" {
							matchStats[peerID] = map[string]interface{}{
								"kills":   kills,
								"assists": assists,
								"deaths":  deaths,
							}
						}
					}
				}
			}
			FinalMatchStats[currentMatchID] = matchStats
			statsMutex.Unlock()

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
	matchesMutex.Lock()
	var active []MatchAnnouncement
	now := time.Now().Unix()

	for id, m := range networkMatches {
		if now-m.Timestamp < 60 {
			active = append(active, m)
		} else {
			delete(networkMatches, id)
		}
	}

	matchesMutex.Unlock()

	EdenChain.Mutex.RLock()
	for mID, session := range EdenChain.MatchSessions {
		found := false
		for _, existing := range active {
			if existing.MatchID == mID {
				found = true
				break
			}
		}
		if !found {
			var total, a, b float64
			if pool, ok := EdenChain.ActivePools[mID]; ok {
				total = pool.TotalPool
				a = pool.TeamAPool
				b = pool.TeamBPool
			}
			active = append(active, MatchAnnouncement{
				MatchID:   mID,
				HostID:    session.HostID,
				Phase:     "lobby",
				Timestamp: session.StartTime,
				TotalPool: total,
				TeamAPool: a,
				TeamBPool: b,
			})
		}
	}
	EdenChain.Mutex.RUnlock()

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

	ctx, nodeCancel = context.WithCancel(context.Background())

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
		routingTable[getIPFromPeerID(s.Conn().RemotePeer().String())] = s
		streamLock.Unlock()
		go readStreamLoop(s)
	})
	h.SetStreamHandler(DemoProtocolID, HandleDemoRequest)

	StartVPNEgressWorker()

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
	localWeight := EdenChain.LastBlock.ChainWeight
	EdenChain.Mutex.RUnlock()

	fmt.Printf("[Sync] Peer Weight: %.2f | Local Weight: %.2f | Peer Height: %d | Local Height: %d\n", status.ChainWeight, localWeight, status.Height, localHeight)

	if status.ChainWeight <= localWeight {
		fmt.Println("[Sync] Peer chain is not heavier. Rejecting sync.")
		return
	}

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
	if nodeCancel != nil {
		nodeCancel()
	}

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

	if err := SignTransaction(myPrivKey, &tx); err != nil {
		fmt.Printf("[Error] Failed to sign listing tx: %v\n", err)
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

		if err := SignTransaction(myPrivKey, &tx); err != nil {
			fmt.Printf("[Error] Failed to sign listing tx: %v\n", err)
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

	if err := SignTransaction(myPrivKey, &tx); err != nil {
		fmt.Printf("[Error] Failed to sign listing tx: %v\n", err)
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

	if err := SignTransaction(myPrivKey, &tx); err != nil {
		fmt.Printf("[Error] Failed to sign listing tx: %v\n", err)
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

	select {
	case vpnEgressQueue <- frame:

	default:
		netStats.Lock()
		netStats.PacketsLost++
		netStats.Unlock()
	}

	for _, s := range streams {
		s.Write(frame)
	}

	for _, s := range streams {
		frameCopy := make([]byte, totalLen)
		copy(frameCopy, frame)

		go func(stream network.Stream, asyncFrame []byte) {
			stream.Write(asyncFrame)
		}(s, frameCopy)
	}

	bufferPool.Put(bufPtr)
}

func readStreamLoop(s network.Stream) {
	defer s.Close()
	defer func() {
		remotePeer := s.Conn().RemotePeer()
		destIP := getIPFromPeerID(remotePeer.String())

		streamLock.Lock()
		delete(activeStreams, remotePeer)
		delete(routingTable, destIP)
		streamLock.Unlock()

		fmt.Sprint("[P2P] Connection lost to %s, cleaned up routing tables.\n", remotePeer.String())
	}()

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

	vetoTopic, err = pubSub.Join("eden-match-vetoes")
	if err == nil {
		vetoSub, _ := vetoTopic.Subscribe()
		go func() {
			for {
				msg, err := vetoSub.Next(ctx)
				if err != nil {
					return
				}

				var v VetoBroadcast
				if err := json.Unmarshal(msg.Data, &v); err == nil {
					vetoMutex.Lock()
					alreadyBanned := false
					for _, m := range matchVetoes[v.MatchID] {
						if m == v.MapName {
							alreadyBanned = true
							break
						}
					}
					if !alreadyBanned {
						matchVetoes[v.MatchID] = append(matchVetoes[v.MatchID], v.MapName)
					}
					vetoMutex.Unlock()
				}
			}
		}()
	}

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

	validatorTopic, err = pubSub.Join(ValidatorTopicName)
	if err == nil {
		valSub, _ := validatorTopic.Subscribe()
		go func() {
			for {
				msg, err := valSub.Next(ctx)
				if err != nil {
					return
				}
				if msg.ReceivedFrom == h.ID() {
					continue
				}

				var wrapper ValidatorMessage
				if err := json.Unmarshal(msg.Data, &wrapper); err != nil {
					continue
				}

				if wrapper.Type == "PROPOSAL" {
					var proposal BlockProposal
					json.Unmarshal(wrapper.Payload, &proposal)
					go handleBlockProposal(proposal)
				} else if wrapper.Type == "SIGNATURE" {
					var sig BlockSignature
					json.Unmarshal(wrapper.Payload, &sig)
					handleBlockSignature(sig)
				} else if wrapper.Type == "TRIBUNAL_VERDICT" {
					var verdict TribunalProposal
					json.Unmarshal(wrapper.Payload, &verdict)
					guiltyStr := "0"
					if verdict.IsGuilty {
						guiltyStr = "1"
					}

					tx := Transaction{
						ID:        fmt.Sprintf("tribunal_%s_%s", verdict.MatchID, verdict.ValidatorID),
						Type:      TxTypeTribunal,
						Sender:    verdict.ValidatorID,
						Receiver:  "CONSENSUS_ENGINE",
						Amount:    0,
						Payload:   fmt.Sprintf("%s:%s:%s", verdict.MatchID, verdict.SuspectID, guiltyStr),
						Timestamp: time.Now().Unix(),
						Signature: verdict.Signature,
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
					}
				}
			}
		}()
	}

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

	queueTopic, err = pubSub.Join(QueueTopicName)
	if err == nil {
		queueSub, _ := queueTopic.Subscribe()
		go func() {
			for {
				msg, err := queueSub.Next(ctx)
				if err != nil {
					return
				}

				var ticket MatchmakingTicket
				if err := json.Unmarshal(msg.Data, &ticket); err == nil {
					queueMutex.Lock()
					activeTickets[ticket.TicketID] = ticket
					queueMutex.Unlock()
					if inQueue {
						go TryFormLobby(ticket.Mode)
					}
				}
			}
		}()
	}

	proposalTopic, err = pubSub.Join(ProposalTopicName)
	if err == nil {
		proposalSub, _ := proposalTopic.Subscribe()
		go func() {
			for {
				msg, err := proposalSub.Next(ctx)
				if err != nil {
					return
				}
				if msg.ReceivedFrom == h.ID() {
					continue
				}

				var proposal LobbyProposal
				if err := json.Unmarshal(msg.Data, &proposal); err == nil {
					go HandleLobbyProposal(proposal)
				}
			}
		}()
	}
}

func broadcastBlock(b Block) {
	if blockTopic == nil {
		return
	}
	data, _ := json.Marshal(b)
	blockTopic.Publish(ctx, data)
}

func TryFormLobby(mode string) {
	queueMutex.RLock()
	if !inQueue {
		queueMutex.RUnlock()
		return
	}

	var validTickets []MatchmakingTicket
	for _, t := range activeTickets {
		if t.Mode == mode {
			validTickets = append(validTickets, t)
		}
	}
	queueMutex.RUnlock()

	requiredPlayers := 10
	if mode == "1V1 HUBS" {
		requiredPlayers = 2
	}
	if mode == "DEATHMATCH" {
		requiredPlayers = 16
	}
	if mode == "TOURNAMENTS" {
		requiredPlayers = 12
	}
	if len(validTickets) < requiredPlayers {
		return
	}

	sort.Slice(validTickets, func(i, j int) bool {
		return validTickets[i].AverageElo < validTickets[j].AverageElo
	})

	var selectedTickets []MatchmakingTicket
	var currentPlayers int
	var minElo, maxElo float64
	const MaxEloSpread = 250.0

	for i := 0; i < len(validTickets); i++ {
		selectedTickets = []MatchmakingTicket{}
		currentPlayers = 0

		for j := i; j < len(validTickets); j++ {
			EdenChain.Mutex.RLock()
			isBanned := false
			for _, p := range validTickets[j].PartyMembers {
				if banExpiry, exists := EdenChain.QueueBans[p]; exists && banExpiry > time.Now().Unix() {
					isBanned = true
					break
				}
			}
			EdenChain.Mutex.RUnlock()

			if isBanned {
				continue
			}

			if currentPlayers+len(validTickets[j].PartyMembers) <= requiredPlayers {
				if len(selectedTickets) == 0 {
					minElo = validTickets[j].AverageElo
				}
				maxElo = validTickets[j].AverageElo

				if maxElo-minElo > MaxEloSpread {
					break
				}

				selectedTickets = append(selectedTickets, validTickets[j])
				currentPlayers += len(validTickets[j].PartyMembers)

				if currentPlayers == requiredPlayers {
					go ProposeLobby(selectedTickets, mode)
					return
				}
			}
		}
	}
}

func ElectHost(players []string) string {
	bestHost := players[0]
	bestScore := -99999.0

	EdenChain.Mutex.RLock()
	defer EdenChain.Mutex.RUnlock()

	for _, p := range players {
		prof := EdenChain.GetOrInitProfile(p)

		reliabilityScore := float64(prof.Matches)*10.0 + prof.Rating

		latencyPenalty := 1000.0
		pid, err := peer.Decode(p)
		if err == nil {
			latency := h.Peerstore().LatencyEWMA(pid)
			if latency > 0 {
				latencyPenalty = float64(latency.Milliseconds())
			} else if p == h.ID().String() {
				latencyPenalty = 0.0
			}
		}

		finalScore := reliabilityScore - (latencyPenalty * 5.0)

		if finalScore > bestScore {
			bestScore = finalScore
			bestHost = p
		}
	}

	fmt.Printf("[Matchmaking] Elected Host %s with score %.2f\n", bestHost, bestScore)
	return bestHost
}

func ProposeLobby(tickets []MatchmakingTicket, mode string) {
	var allPlayers []string
	var totalElo float64

	for _, t := range tickets {
		allPlayers = append(allPlayers, t.PartyMembers...)
		totalElo += (t.AverageElo * float64(len(t.PartyMembers)))
	}

	sort.Strings(allPlayers)
	hostID := ElectHost(allPlayers)
	proposalHash := sha256.Sum256([]byte(strings.Join(allPlayers, "")))

	proposal := LobbyProposal{
		ProposalID: fmt.Sprintf("prop_%x", proposalHash),
		HostID:     hostID,
		Mode:       mode,
		Players:    allPlayers,
		AverageElo: totalElo / float64(len(allPlayers)),
		Timestamp:  time.Now().Unix(),
	}

	data, _ := json.Marshal(proposal)
	if proposalTopic != nil {
		proposalTopic.Publish(ctx, data)
	}

	HandleLobbyProposal(proposal)
}

func HandleLobbyProposal(proposal LobbyProposal) {
	queueMutex.RLock()
	if !inQueue {
		queueMutex.RUnlock()
		return
	}
	queueMutex.RUnlock()

	amIIncluded := false
	for _, p := range proposal.Players {
		if p == h.ID().String() {
			amIIncluded = true
			break
		}
	}
	if !amIIncluded {
		return
	}

	proposalMutex.Lock()
	defer proposalMutex.Unlock()
	if bestProposal.ProposalID == "" || proposal.AverageElo > bestProposal.AverageElo || (proposal.AverageElo == bestProposal.AverageElo && proposal.ProposalID < bestProposal.ProposalID) {
		bestProposal = proposal

		if proposalTimer != nil {
			proposalTimer.Stop()
		}

		proposalTimer = time.AfterFunc(5*time.Second, func() {
			LockInLobby()
		})
	}
}

func handleBlockProposal(proposal BlockProposal) {
	EdenChain.Mutex.RLock()
	myProfile := EdenChain.GetOrInitProfile(myPeerID)
	lastHast := EdenChain.LastBlock.Hash
	EdenChain.Mutex.RUnlock()

	if myProfile.StakedEDN <= 0 {
		return
	}

	if proposal.BlockData.PrevHash != lastHast {
		fmt.Printf("[Validators] Rejecting proposal from %s: Out of sync.\n", proposal.ProposerID)
		return
	}

	hashBytes, _ := hex.DecodeString(proposal.BlockData.Hash)
	privBytes, _ := hex.DecodeString(myPrivKey)
	privKey, _ := x509.ParseECPrivateKey(privBytes)
	r, s, _ := ecdsa.Sign(rand.Reader, privKey, hashBytes)

	sigBytes := make([]byte, 64)
	rBytes := r.Bytes()
	sBytes := s.Bytes()
	copy(sigBytes[32-len(rBytes):32], rBytes)
	copy(sigBytes[64-len(sBytes):64], sBytes)
	sigHex := hex.EncodeToString(sigBytes)

	sigMsg := BlockSignature{
		ValidatorID: myPeerID,
		BlockHash:   proposal.BlockData.Hash,
		Signature:   sigHex,
	}

	payload, _ := json.Marshal(sigMsg)
	wrapper := ValidatorMessage{Type: "SIGNATURE", Payload: payload}
	data, _ := json.Marshal(wrapper)

	if validatorTopic != nil {
		validatorTopic.Publish(ctx, data)
	}

	fmt.Printf("[Validators] Signed block proposal %s from %s\n", proposal.BlockData.Hash, proposal.ProposerID)
}

func handleBlockSignature(sig BlockSignature) {
	sigsMutex.Lock()
	defer sigsMutex.Unlock()

	if pendingBlockSigs[sig.BlockHash] == nil {
		pendingBlockSigs[sig.BlockHash] = make(map[string]string)
	}

	pendingBlockSigs[sig.BlockHash][sig.ValidatorID] = sig.Signature
}

func RunAutomatedTribunal(matchID string, demoFilePath string, suspectPeerID string) {
	EdenChain.Mutex.RLock()
	myProfile := EdenChain.GetOrInitProfile(myPeerID)
	EdenChain.Mutex.RUnlock()

	if myProfile.StakedEDN <= 0 {
		return
	}

	f, err := os.Open(demoFilePath)
	if err != nil {
		fmt.Println("[Tribunal] Failed to open demo file:", err)
		return
	}
	defer f.Close()

	parser := demoinfocs.NewParser(f)
	defer parser.Close()

	suspiciousSnaps := 0
	totalKills := 0

	parser.RegisterEventHandler(func(e events.Kill) {
		if e.Killer != nil && e.Killer.Name == suspectPeerID {
			totalKills++
			if e.Distance > 20.0 && e.IsHeadshot {
				suspiciousSnaps++
			}
		}
	})

	err = parser.ParseToEnd()
	if err != nil {
		fmt.Println("[Tribunal] Demo parsing failed:", err)
		return
	}

	isGuilty := false
	if totalKills > 0 && float64(suspiciousSnaps)/float64(totalKills) > 0.40 {
		isGuilty = true
	}

	SubmitTribunalVerdict(matchID, suspectPeerID, isGuilty)
}

func DetectSnaps(parser demoinfocs.Parser, suspectSteamID64 uint64) int {
	confirmedSuspiciousSnaps := 0
	suspiciousShotsFired := make(map[int]bool)

	parser.RegisterEventHandler(func(e events.FrameDone) {
		for _, p := range parser.GameState().Participants().Playing() {
			if p != nil && p.SteamID64 == suspectSteamID64 {
				vec := angleToVector(p.ViewDirectionX(), p.ViewDirectionY())

				state := PlayerState{
					ViewDirection: vec,
					Tick:          parser.GameState().IngameTick(),
				}

				recentAngles[p.SteamID64] = append(recentAngles[p.SteamID64], state)
				if len(recentAngles[p.SteamID64]) > 10 {
					recentAngles[p.SteamID64] = recentAngles[p.SteamID64][1:]
				}
			}
		}
	})

	parser.RegisterEventHandler(func(e events.WeaponFire) {
		if e.Shooter != nil && e.Shooter.SteamID64 == suspectSteamID64 {
			history := recentAngles[suspectSteamID64]
			if len(history) < 2 {
				return
			}

			pastState := history[0]
			currentState := history[len(history)-1]

			angleDelta := angleBetween(pastState.ViewDirection, currentState.ViewDirection)

			if angleDelta > 25.0 {
				currentTick := parser.GameState().IngameTick()
				suspiciousShotsFired[currentTick] = true
			}
		}
	})

	parser.RegisterEventHandler(func(e events.PlayerHurt) {
		if e.Attacker != nil && e.Attacker.SteamID64 == suspectSteamID64 {
			currentTick := parser.GameState().IngameTick()

			for i := 0; i <= 3; i++ {
				checkTick := currentTick - i
				if suspiciousShotsFired[checkTick] {
					confirmedSuspiciousSnaps++
					delete(suspiciousShotsFired, checkTick)
					break
				}
			}
		}
	})

	return confirmedSuspiciousSnaps
}

func DetectWallTracing(parser demoinfocs.Parser, suspectSteamID64 uint64) int {
	traceFlags := 0
	suspectTraceDuration := make(map[uint64]int)

	parser.RegisterEventHandler(func(e events.FrameDone) {
		gameState := parser.GameState()

		var suspect *common.Player

		for _, p := range gameState.Participants().Playing() {
			if p.SteamID64 == suspectSteamID64 {
				suspect = p
				break
			}
		}

		if suspect == nil || !suspect.IsAlive() {
			return
		}

		suspectPos := suspect.Position()
		suspectView := angleToVector(suspect.ViewDirectionX(), suspect.ViewDirectionY())

		for _, enemy := range gameState.Participants().Playing() {
			if enemy == nil || !enemy.IsAlive() || enemy.Team == suspect.Team || enemy.SteamID64 == suspectSteamID64 {
				continue
			}

			if enemy.IsUnknown {
				suspectTraceDuration[enemy.SteamID64] = 0
				continue
			}

			if suspect.HasSpotted(enemy) {
				suspectTraceDuration[enemy.SteamID64] = 0
				continue
			}
			enemyPos := enemy.Position()
			targetVector := r3.Vector{
				X: enemyPos.X - suspectPos.X,
				Y: enemyPos.Y - suspectPos.Y,
				Z: (enemyPos.Z + 60.0) - suspectPos.Z,
			}

			angle := angleBetween(suspectView, targetVector)
			if angle < 2.5 {
				suspectTraceDuration[enemy.SteamID64]++
				if suspectTraceDuration[enemy.SteamID64] > 32 {
					traceFlags++
					suspectTraceDuration[enemy.SteamID64] = 0
				}
			} else {
				suspectTraceDuration[enemy.SteamID64] = 0
			}
		}
	})

	return traceFlags
}

func angleToVector(pitch, yaw float32) r3.Vector {
	pitchRad := float64(pitch) * (math.Pi / 180.0)
	yawRad := float64(yaw) * (math.Pi / 180.0)

	return r3.Vector{
		X: math.Cos(pitchRad) * math.Cos(yawRad),
		Y: math.Sin(yawRad) * math.Cos(pitchRad),
		Z: -math.Sin(pitchRad),
	}
}

func angleBetween(v1, v2 r3.Vector) float64 {
	dot := v1.Dot(v2)
	mag1 := v1.Norm()
	mag2 := v2.Norm()

	if mag1 == 0 || mag2 == 0 {
		return 0
	}

	cosTheta := dot / (mag1 * mag2)
	if cosTheta > 1.0 {
		cosTheta = 1.0
	} else if cosTheta < -1.0 {
		cosTheta = -1.0
	}

	return math.Acos(cosTheta) * (180.0 / math.Pi)
}

func HandleDemoRequest(s network.Stream) {
	defer s.Close()

	reqBuf, err := readFrame(s)
	if err != nil {
		fmt.Println("[P2P Demo] Failed to read request:", err)
		return
	}

	var req DemoRequest
	json.Unmarshal(reqBuf, &req)

	safeMatchID := filepath.Base(req.MatchID)
	demoPath := filepath.Join(".", "replays", fmt.Sprintf("%s.dem", safeMatchID))

	file, err := os.Open(demoPath)
	if err != nil {
		resp := DemoResponse{Status: "ERROR: File Not Found"}
		respData, _ := json.Marshal(resp)
		writeFrame(s, respData)
		return
	}
	defer file.Close()

	fileInfo, _ := file.Stat()

	resp := DemoResponse{
		Status:   "OK",
		FileSize: fileInfo.Size(),
	}
	respData, _ := json.Marshal(resp)
	if err := writeFrame(s, respData); err != nil {
		return
	}

	fmt.Printf("[P2P Demo] Streaming %s to validator %s...\n", req.MatchID, s.Conn().RemotePeer())
	_, err = io.Copy(s, file)
	if err != nil {
		fmt.Println("[P2P Demo] Error streaming file:", err)
	} else {
		fmt.Println("[P2P Demo] Transfer complete.")
	}
}

func FetchDemoAndAnalyze(ctx context.Context, hostPeerIDStr string, matchID string, suspectPeerID string) {
	targetID, err := peer.Decode(hostPeerIDStr)
	if err != nil {
		fmt.Println("[Tribunal] Invalid host peer ID")
		return
	}

	if h.Network().Connectedness(targetID) != network.Connected {
		peerInfo, err := kademliaDHT.FindPeer(ctx, targetID)
		if err == nil {
			h.Connect(ctx, peerInfo)
		}
	}

	s, err := h.NewStream(ctx, targetID, DemoProtocolID)
	if err != nil {
		fmt.Println("[Tribunal] Failed to open demo stream:", err)
		return
	}
	defer s.Close()

	req := DemoRequest{MatchID: matchID}
	reqData, _ := json.Marshal(req)
	if err := writeFrame(s, reqData); err != nil {
		fmt.Println("[Tribunal] Failed to send demo request:", err)
		return
	}

	respBuf, err := readFrame(s)
	if err != nil {
		fmt.Println("[Tribunal] Failed to read demo response:", err)
		return
	}

	var resp DemoResponse
	json.Unmarshal(respBuf, &resp)

	if resp.Status != "OK" {
		fmt.Printf("[Tribunal] Host rejected demo request: %s\n", resp.Status)
		return
	}

	localPath := fmt.Sprintf("./temp_demos/%s.dem", matchID)
	os.MkdirAll("./temp_demos", os.ModePerm)
	outFile, err := os.Create(localPath)
	if err != nil {
		fmt.Println("[Tribunal] Failed to create local demo file:", err)
		return
	}
	defer outFile.Close()

	fmt.Printf("[Tribunal] Downloading demo for %s (Size: %d bytes)...\n", matchID, resp.FileSize)

	bytesWritten, err := io.CopyN(outFile, s, resp.FileSize)
	if err != nil && err != io.EOF {
		fmt.Println("[Tribunal] Error downloading demo bytes:", err)
		return
	}

	fmt.Printf("[Tribunal] Demo download complete! Received %d bytes. Starting analysis...\n", bytesWritten)

	go RunAutomatedTribunal(matchID, localPath, suspectPeerID)
}

//export RegisterMatchCallback
func RegisterMatchCallback(fn C.MatchFoundCallbackFn) {
	C.SetMatchFoundCallback(fn)
}

//export LeaveMatchmaking
func LeaveMatchmaking() {
	queueMutex.Lock()
	defer queueMutex.Unlock()

	if !inQueue {
		return
	}

	inQueue = false
	if myCurrentTicket != "" {
		delete(activeTickets, myCurrentTicket)
		myCurrentTicket = ""
	}

	fmt.Println("[Matchmaking] Left the queue and wiped local ticket.")
}

func LockInLobby() {
	proposalMutex.Lock()
	finalProposal := bestProposal
	bestProposal = LobbyProposal{}
	proposalMutex.Unlock()

	if finalProposal.ProposalID == "" {
		return
	}

	LeaveMatchmaking()

	fmt.Printf("[Matchmaking] LOBBY LOCKED! Host: %s, Avg Elo: %.0f\n", finalProposal.HostID, finalProposal.AverageElo)

	cMatchID := C.CString(finalProposal.ProposalID)
	cHostID := C.CString(finalProposal.HostID)
	rosterStr := strings.Join(finalProposal.Players, ",")
	cRoster := C.CString(rosterStr)
	C.CallMatchFound(cMatchID, cHostID, cRoster)
	C.free(unsafe.Pointer(cMatchID))
	C.free(unsafe.Pointer(cHostID))
	C.free(unsafe.Pointer(cRoster))
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

//export GetMatchStats
func GetMatchStats(matchID *C.char) *C.char {
	mID := C.GoString(matchID)
	statsMutex.RLock()
	defer statsMutex.RUnlock()

	stats, exists := FinalMatchStats[mID]
	if !exists {
		return C.CString("{}")
	}
	data, _ := json.Marshal(stats)
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

//export SubmitDodgePenalty
func SubmitDodgePenalty(matchID *C.char, dodgerPeerID *C.char) *C.char {
	mID := C.GoString(matchID)
	dodgerID := C.GoString(dodgerPeerID)

	pubKeyBytes, err := hex.DecodeString(myPubKey)
	if err != nil {
		return C.CString("Error: Invalid Public Key")
	}

	payload := fmt.Sprintf("%s:%s", mID, dodgerID)

	tx := Transaction{
		ID:        fmt.Sprintf("pen_%d", time.Now().UnixNano()),
		Type:      TxTypePenalty,
		Sender:    h.ID().String(),
		Receiver:  "CONSENSUS_ENGINE",
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
		return C.CString("Success: Penalty Broadcasted")
	}
	return C.CString("Error: Block Rejected")
}

//export GetValidatorMetrics
func GetValidatorMetrics(peerID *C.char) *C.char {
	pid := C.GoString(peerID)
	if pid == "" {
		pid = h.ID().String()
	}

	EdenChain.Mutex.RLock()
	profile := EdenChain.GetOrInitProfile(pid)
	EdenChain.Mutex.RUnlock()

	accuracy := 0.0
	if profile.TribunalTotalVotes > 0 {
		accuracy = (float64(profile.TribunalCorrect) / float64(profile.TribunalTotalVotes)) * 100.0
	}

	metrics := map[string]interface{}{
		"demos_parsed": profile.TribunalDemosParsed,
		"edn_earned":   profile.TribunalEDNEarned,
		"accuracy":     accuracy,
		"staked_edn":   profile.StakedEDN,
	}

	data, _ := json.Marshal(metrics)
	return C.CString(string(data))
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
				EdenChain.Mutex.RLock()
				for _, session := range EdenChain.MatchSessions {
					if session.HostID == p.ID.String() {
						isHost = true
						break
					}
				}
				EdenChain.Mutex.RUnlock()
			}

			if !isHost {
				continue
			}
		}

		if h.Connect(ctx, p) == nil {
			s, err := h.NewStream(ctx, p.ID, ProtocolID)
			if err == nil {
				streamLock.Lock()
				activeStreams[p.ID] = s
				routingTable[getIPFromPeerID(p.ID.String())] = s
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

	if err := h.Connect(ctx, peerInfo); err == nil {
		s, err := h.NewStream(ctx, targetID, ProtocolID)
		if err == nil {
			streamLock.Lock()
			activeStreams[targetID] = s
			routingTable[getIPFromPeerID(targetID.String())] = s
			streamLock.Unlock()
			go readStreamLoop(s)
			fmt.Printf("[P2P] Successfully connected and opened stream to %s\n", pIDStr)
		} else {
			fmt.Printf("[P2P] Connected, but failed to open data stream: %v\n", err)
		}

		go TriggerSync(targetID)
	} else {
		fmt.Printf("[P2P] Failed to connect to peer: %v\n", err)
	}
}

//export EnterMatchmaking
func EnterMatchmaking(mode *C.char, partyList *C.char) *C.char {
	if pubSub == nil || queueTopic == nil {
		return C.CString("Error: PubSub Not Ready")
	}

	modeStr := C.GoString(mode)
	partyStr := C.GoString(partyList)
	party := strings.Split(partyStr, ",")

	EdenChain.Mutex.RLock()
	var totalElo float64 = 0
	for _, memberID := range party {
		profile := EdenChain.GetOrInitProfile(memberID)
		totalElo += profile.Rating
	}
	avgElo := totalElo / float64(len(party))
	EdenChain.Mutex.RUnlock()

	ticket := MatchmakingTicket{
		TicketID:     fmt.Sprintf("tk_%d_%s", time.Now().UnixNano(), h.ID().String()[:6]),
		LeaderID:     h.ID().String(),
		PartyMembers: party,
		AverageElo:   avgElo,
		Mode:         modeStr,
		Timestamp:    time.Now().Unix(),
	}

	data, err := json.Marshal(ticket)
	if err != nil {
		return C.CString("Error: Failed to serialize ticket")
	}

	queueTopic.Publish(ctx, data)
	queueMutex.Lock()
	inQueue = true
	myCurrentTicket = ticket.TicketID
	activeTickets[ticket.TicketID] = ticket
	queueMutex.Unlock()

	fmt.Printf("[Matchmaking] Entered %s queue at %.0f Elo. Ticket: %s\n", modeStr, avgElo, ticket.TicketID)

	go TryFormLobby(modeStr)

	return C.CString("Success: In Queue")
}

//export BroadcastMapVeto
func BroadcastMapVeto(matchID *C.char, mapName *C.char) {
	mID := C.GoString(matchID)
	mName := C.GoString(mapName)

	v := VetoBroadcast{MatchID: mID, PeerID: h.ID().String(), MapName: mName}
	if data, err := json.Marshal(v); err == nil {
		if vetoTopic != nil {
			vetoTopic.Publish(ctx, data)
		}

		vetoMutex.Lock()
		matchVetoes[mID] = append(matchVetoes[mID], mName)
		vetoMutex.Unlock()
	}
}

//export GetMatchVetoes
func GetMatchVetoes(matchID *C.char) *C.char {
	mID := C.GoString(matchID)

	vetoMutex.RLock()
	defer vetoMutex.RUnlock()

	bans, exists := matchVetoes[mID]
	if !exists {
		return C.CString("[]")
	}

	data, _ := json.Marshal(bans)
	return C.CString(string(data))
}

//export GetMyBanExpiry
func GetMyBanExpiry() *C.char {
	EdenChain.Mutex.RLock()
	defer EdenChain.Mutex.RUnlock()

	expiry := EdenChain.QueueBans[h.ID().String()]
	return C.CString(fmt.Sprintf("%d", expiry))
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
