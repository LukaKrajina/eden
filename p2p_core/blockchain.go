package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

const (
	TxTypeTransfer = "TRANSFER"
	TxTypeBet      = "BET"
	TxTypeEscrow   = "ESCROW_LOCK"
	TxTypeResolve  = "RESOLVE_PAYOUT"
)

type Transaction struct {
	ID        string  `json:"id"`
	Type      string  `json:"type"`
	Sender    string  `json:"sender"`
	Receiver  string  `json:"receiver"`
	Amount    float64 `json:"amount"`
	Payload   string  `json:"payload"`
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

type Bet struct {
	Bettor  string  `json:"bettor"`
	Amount  float64 `json:"amount"`
	Team    string  `json:"team"`
	MatchID string  `json:"match_id"`
}

type BettingPool struct {
	MatchID   string  `json:"match_id"`
	TotalPool float64 `json:"total_pool"`
	TeamAPool float64 `json:"team_a_pool"`
	TeamBPool float64 `json:"team_b_pool"`
	IsOpen    bool    `json:"is_open"`
	Bets      []Bet   `json:"bets"`
}

type Escrow struct {
	TradeID   string  `json:"trade_id"`
	Buyer     string  `json:"buyer"`
	Seller    string  `json:"seller"`
	Amount    float64 `json:"amount"`
	AssetID   string  `json:"asset_id"`
	State     string  `json:"state"`
	ExpiresAt int64   `json:"expires_at"`
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
	Chain         []Block
	Balances      map[string]float64
	ActivePools   map[string]*BettingPool
	ActiveEscrows map[string]*Escrow
	Mutex         sync.RWMutex
}

var EdenChain *Blockchain

func InitializeChain() {
	EdenChain = &Blockchain{
		Chain: []Block{
			{Index: 0, Timestamp: time.Now().Unix(), Hash: "GENESIS_BLOCK", PrevHash: "0"},
		},
		Balances:      make(map[string]float64),
		ActivePools:   make(map[string]*BettingPool),
		ActiveEscrows: make(map[string]*Escrow),
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
		switch tx.Type {
		case TxTypeTransfer:
			bc.Balances[tx.Receiver] += tx.Amount

		case TxTypeBet:
			bc.processBet(tx)

		case TxTypeEscrow:
			bc.processEscrowLock(tx)

		case TxTypeResolve:
			bc.Balances[tx.Receiver] += tx.Amount
		}
	}

	bc.Chain = append(bc.Chain, b)
	return true
}

func (bc *Blockchain) processBet(tx Transaction) {
	var matchID, team string
	fmt.Sscanf(tx.Payload, "%s:%s", &matchID, &team)

	originalBalances := make(map[string]float64)
	for k, v := range bc.Balances {
		originalBalances[k] = v
	}

	bc.Balances[tx.Sender] -= tx.Amount

	pool, exists := bc.ActivePools[matchID]
	poolCreated := false
	if !exists {
		pool = &BettingPool{MatchID: matchID, IsOpen: true}
		bc.ActivePools[matchID] = pool
		poolCreated = true
	}

	if !pool.IsOpen {
		bc.Balances = originalBalances
		if poolCreated {
			delete(bc.ActivePools, matchID)
		}
		return
	}

	newBet := Bet{Bettor: tx.Sender, Amount: tx.Amount, Team: team, MatchID: matchID}
	pool.Bets = append(pool.Bets, newBet)
	pool.TotalPool += tx.Amount
	if team == "CT" {
		pool.TeamAPool += tx.Amount
	} else {
		pool.TeamBPool += tx.Amount
	}

	fmt.Println("Bet processed successfully.")
}

func (bc *Blockchain) processEscrowLock(tx Transaction) {
	escrow := &Escrow{
		TradeID:   tx.ID,
		Buyer:     tx.Sender,
		Seller:    tx.Receiver,
		Amount:    tx.Amount,
		AssetID:   tx.Payload,
		State:     "FUNDED",
		ExpiresAt: time.Now().Add(24 * time.Hour).Unix(),
	}
	bc.ActiveEscrows[tx.ID] = escrow
}

func (bc *Blockchain) ResolveMatch(matchID string, winningTeam string) []Transaction {
	bc.Mutex.Lock()
	defer bc.Mutex.Unlock()

	pool, exists := bc.ActivePools[matchID]
	if !exists || !pool.IsOpen {
		return nil
	}

	pool.IsOpen = false
	payoutTxs := []Transaction{}

	const CommissionRate = 0.04
	netPool := pool.TotalPool * (1.0 - CommissionRate)

	var winningPoolTotal float64
	if winningTeam == "CT" {
		winningPoolTotal = pool.TeamAPool
	} else {
		winningPoolTotal = pool.TeamBPool
	}

	if winningPoolTotal == 0 {
		// Edge case: No winners. Burn/Keep pool (simplified here)
		return nil
	}

	for _, bet := range pool.Bets {
		if bet.Team == winningTeam {
			share := bet.Amount / winningPoolTotal
			payoutAmount := share * netPool

			tx := Transaction{
				ID:        fmt.Sprintf("pay_%s_%d", matchID, time.Now().UnixNano()),
				Type:      TxTypeResolve,
				Sender:    "SYSTEM_PAYOUT",
				Receiver:  bet.Bettor,
				Amount:    payoutAmount,
				Timestamp: time.Now().Unix(),
				Signature: "CONSENSUS_VERIFIED",
			}
			payoutTxs = append(payoutTxs, tx)
		}
	}

	delete(bc.ActivePools, matchID)

	return payoutTxs
}

func (bc *Blockchain) SettleEscrow(tradeID string) *Transaction {
	bc.Mutex.Lock()
	defer bc.Mutex.Unlock()

	escrow, exists := bc.ActiveEscrows[tradeID]
	if !exists || escrow.State != "FUNDED" {
		return nil
	}

	escrow.State = "SETTLED"

	return &Transaction{
		ID:        fmt.Sprintf("settle_%s", tradeID),
		Type:      TxTypeTransfer,
		Sender:    "SYSTEM_PAYOUT",
		Receiver:  escrow.Seller,
		Amount:    escrow.Amount,
		Timestamp: time.Now().Unix(),
	}
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

func (bc *Blockchain) GetBalance(address string) float64 {
	bc.Mutex.RLock()
	defer bc.Mutex.RUnlock()
	return bc.Balances[address]
}
