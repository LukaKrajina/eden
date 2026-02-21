package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

type Transaction struct {
	ID        string  `json:"id"`
	Sender    string  `json:"sender"`
	Receiver  string  `json:"receiver"`
	Amount    float64 `json:"amount"`
	Timestamp int64   `json:"timestamp"`
	Signature string  `json:"signature"`
}

type GameProof struct {
	MatchID       string   `json:"match_id"`
	Duration      int      `json:"duration"`
	MaxPlayers    int      `json:"max_players"`
	QualityScore  int      `json:"quality_score"`
	PlayerWitness []string `json:"witnesses"`
}

type Block struct {
	Index        int           `json:"index"`
	Timestamp    int64         `json:"timestamp"`
	Transactions []Transaction `json:"transactions"`
	GameData     *GameProof    `json:"game_data,omitempty"`
	PrevHash     string        `json:"prev_hash"`
	Hash         string        `json:"hash"`
}

type Blockchain struct {
	Chain     []Block
	Balances  map[string]float64 
	Mutex     sync.RWMutex
}

var EdenChain *Blockchain

func InitializeChain() {
	EdenChain = &Blockchain{
		Chain: []Block{
			{Index: 0, Timestamp: time.Now().Unix(), Hash: "GENESIS_BLOCK", PrevHash: "0"},
		},
		Balances: make(map[string]float64),
	}
}

func (bc *Blockchain) AddBlock(b Block) bool {
	bc.Mutex.Lock()
	defer bc.Mutex.Unlock()

	lastBlock := bc.Chain[len(bc.Chain)-1]
	if b.PrevHash != lastBlock.Hash {
		fmt.Printf("[Chain] Hash mismatch. Expected prev: %s, Got: %s\n", lastBlock.Hash, b.PrevHash)
		return false
	}
	if b.Index != lastBlock.Index+1 {
		fmt.Printf("[Chain] Block gap detected. Local: %d, Incoming: %d\n", lastBlock.Index, b.Index)
		return false
	}

	for _, tx := range b.Transactions {
		if tx.Sender != "SYSTEM_MINT" {
			if bc.Balances[tx.Sender] < tx.Amount {
				fmt.Printf("[Chain] Invalid TX: Insufficient funds for %s\n", tx.Sender)
				return false
			}
			bc.Balances[tx.Sender] -= tx.Amount
		}
		bc.Balances[tx.Receiver] += tx.Amount
	}

	bc.Chain = append(bc.Chain, b)
	return true
}

func (bc *Blockchain) CreateGameBlock(proof GameProof, minerID string) Block {
	bc.Mutex.RLock()
	lastBlock := bc.Chain[len(bc.Chain)-1]
	index := len(bc.Chain)
	bc.Mutex.RUnlock()

	rewardAmount := CalculateReward(&proof)

	rewardTx := Transaction{
		ID:        fmt.Sprintf("tx_mint_%d", time.Now().UnixNano()),
		Sender:    "SYSTEM_MINT",
		Receiver:  minerID,
		Amount:    rewardAmount,
		Timestamp: time.Now().Unix(),
		Signature: "CONSENSUS_VERIFIED",
	}

	newBlock := Block{
		Index:        index,
		Timestamp:    time.Now().Unix(),
		Transactions: []Transaction{rewardTx},
		GameData:     &proof,
		PrevHash:     lastBlock.Hash,
	}

	newBlock.Hash = calculateHash(newBlock)
	
	if bc.AddBlock(newBlock) {
		return newBlock
	}
	return Block{}
}

func CalculateReward(proof *GameProof) float64 {
	const BaseRatePerSecond = 0.01
	const PlayerMultiplier = 1.5

	timeReward := float64(proof.Duration) * BaseRatePerSecond
	connectionBonus := timeReward * (float64(len(proof.PlayerWitness)) * PlayerMultiplier)
	
	qualityFactor := float64(proof.QualityScore) / 100.0
	if proof.QualityScore < 80 {
		qualityFactor *= 0.5
	}

	return (timeReward + connectionBonus) * qualityFactor
}

func calculateHash(b Block) string {
	record := fmt.Sprintf("%d%d%v%s", b.Index, b.Timestamp, b.Transactions, b.PrevHash)
	h := sha256.New()
	h.Write([]byte(record))
	return hex.EncodeToString(h.Sum(nil))
}

// GetBalance is now O(1) instead of O(N)
func (bc *Blockchain) GetBalance(address string) float64 {
	bc.Mutex.RLock()
	defer bc.Mutex.RUnlock()
	return bc.Balances[address]
}