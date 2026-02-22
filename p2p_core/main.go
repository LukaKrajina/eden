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

// --- Constants & Globals ---

const (
	FrameGame      = 0x01
	FrameHeartbeat = 0x02
	ProtocolID     = "/eden-cs2/1.0.0"
	TopicName      = "eden-consensus-v1"
)

var (
	h            host.Host
	ctx          context.Context
	kademliaDHT  *dht.IpfsDHT
	activeStream network.Stream
	streamLock   sync.Mutex
	pubSub       *pubsub.PubSub
	blockTopic   *pubsub.Topic

	// Optimization: Reuse buffers to reduce GC pressure
	bufferPool = sync.Pool{
		New: func() interface{} {
			return make([]byte, 4096) // Standard MTU is 1500, 4096 is safe
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

var netStats NetworkStats
var lastSeenPeer time.Time
var peerMutex sync.Mutex
var myPeerID string

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
