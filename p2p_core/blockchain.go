package main

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/syndtr/goleveldb/leveldb"
)

const (
	TxTypeTransfer     = "TRANSFER"
	TxTypeBet          = "BET"
	TxTypeEscrow       = "ESCROW_LOCK"
	TxTypeResolve      = "RESOLVE_PAYOUT"
	TxTypeList         = "LIST_ITEM"
	TxTypeCloseExpired = "CLOSE_EXPIRED"
	TxTypeMatchStart   = "MATCH_START"
	TxTypeWitness      = "MATCH_WITNESS"
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
	PublicKey []byte  `json:"pub_key"`
	Nonce     uint64  `json:"nonce"`
}

type GameProof struct {
	MatchID       string   `json:"match_id"`
	Duration      int      `json:"duration"`
	MaxPlayers    int      `json:"max_players"`
	QualityScore  int      `json:"quality_score"`
	PlayerWitness []string `json:"witnesses"`
}

type Auction struct {
	ID        string  `json:"id"`
	Seller    string  `json:"seller"`
	AssetID   string  `json:"asset_id"`
	Name      string  `json:"name"`
	ImageURL  string  `json:"image_url"`
	Wear      string  `json:"wear"`
	Price     float64 `json:"price"`
	ExpiresAt int64   `json:"expires_at"`
	State     string  `json:"state"`
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
	LastBlock      Block
	Balances       map[string]float64
	ActiveAuctions map[string]*Auction
	ActivePools    map[string]*BettingPool
	ActiveEscrows  map[string]*Escrow
	AccountNonces  map[string]uint64
	MatchRosters   map[string][]string          `json:"match_rosters"`
	MatchVotes     map[string]map[string]string `json:"match_votes"`
	Database       *leveldb.DB
	DBPath         string
	Mutex          sync.RWMutex
}

var EdenChain *Blockchain

func InitializeChain(dbPath string) {
	db, err := leveldb.OpenFile(dbPath, nil)
	if err != nil {
		panic("Failed to open LevelDB: " + err.Error())
	}

	EdenChain = &Blockchain{
		Balances:       make(map[string]float64),
		ActiveAuctions: make(map[string]*Auction),
		ActivePools:    make(map[string]*BettingPool),
		ActiveEscrows:  make(map[string]*Escrow),
		AccountNonces:  make(map[string]uint64),
		MatchRosters:   make(map[string][]string),
		MatchVotes:     make(map[string]map[string]string),
		Database:       db,
		DBPath:         dbPath,
	}
	EdenChain.LoadFromDB()
}

func (bc *Blockchain) SaveBlockToDB(b Block) {
	data, _ := json.Marshal(b)
	key := fmt.Sprintf("block_%d", b.Index)

	bc.Database.Put([]byte(key), data, nil)

	bc.Database.Put([]byte("latest_index"), []byte(strconv.Itoa(b.Index)), nil)
}

func (bc *Blockchain) LoadFromDB() {
	latestBytes, err := bc.Database.Get([]byte("latest_index"), nil)
	if err != nil {
		fmt.Println("[DB] No history found. Creating Genesis Block.")
		genesis := Block{
			Index: 0, Timestamp: time.Now().Unix(), Hash: "GENESIS_BLOCK", PrevHash: "0",
		}
		bc.AddBlock(genesis)
		return
	}

	latestIndex, _ := strconv.Atoi(string(latestBytes))
	fmt.Printf("[DB] Found chain history up to height %d. Replaying...\n", latestIndex)

	for i := 0; i <= latestIndex; i++ {
		key := fmt.Sprintf("block_%d", i)
		data, err := bc.Database.Get([]byte(key), nil)
		if err != nil {
			fmt.Printf("[DB] Error corrupted chain at block %d\n", i)
			break
		}

		var b Block
		json.Unmarshal(data, &b)

		bc.ProcessBlockState(b)
		bc.LastBlock = b
	}
	fmt.Println("[DB] State restoration complete.")
}

func (tx *Transaction) GenerateTxHash() []byte {
	record := fmt.Sprintf("%s%s%s%f%d%s%d", tx.Sender, tx.PublicKey, tx.Receiver, tx.Amount, tx.Timestamp, tx.Payload, tx.Nonce)
	h := sha256.New()
	h.Write([]byte(record))
	return h.Sum(nil)
}

func VerifyTransaction(tx Transaction) bool {
	var pubKeyBytes []byte
	if len(tx.PublicKey) > 0 {
		pubKeyBytes = tx.PublicKey
	} else {
		return false
	}

	genericPublicKey, err := x509.ParsePKIXPublicKey(pubKeyBytes)
	if err != nil {
		fmt.Printf("[Crypto] Failed to parse PKIX Public Key: %v\n", err)
		return false
	}

	pubKey, ok := genericPublicKey.(*ecdsa.PublicKey)
	if !ok {
		fmt.Printf("[Crypto] Public Key is not ECDSA\n")
		return false
	}

	derivedAddress := hex.EncodeToString(tx.PublicKey)
	if derivedAddress != tx.Sender {
		fmt.Printf("[Crypto] FRAUD: Public Key %s does not belong to Sender %s\n", derivedAddress, tx.Sender)
		return false
	}

	sigBytes, err := hex.DecodeString(tx.Signature)
	if err != nil || len(sigBytes) == 0 {
		fmt.Printf("[Crypto] Invalid Signature Hex\n")
		return false
	}

	r := big.NewInt(0).SetBytes(sigBytes[:len(sigBytes)/2])
	s := big.NewInt(0).SetBytes(sigBytes[len(sigBytes)/2:])
	hash := tx.GenerateTxHash()
	return ecdsa.Verify(pubKey, hash, r, s)
}

func (bc *Blockchain) AddBlock(b Block) bool {
	bc.Mutex.Lock()
	defer bc.Mutex.Unlock()
	lastBlock := bc.LastBlock
	if b.PrevHash != lastBlock.Hash {
		return false
	}

	if b.Index != lastBlock.Index+1 {
		return false
	}

	if !bc.ProcessBlockState(b) {
		fmt.Println("[Chain] Block rejected due to invalid state transition")
		return false
	}

	bc.LastBlock = b
	bc.SaveBlockToDB(b)
	return true
}

func (bc *Blockchain) GeneratePayouts(matchID string, winningTeam string) []Transaction {
	pool, exists := bc.ActivePools[matchID]
	if !exists || !pool.IsOpen {
		return nil
	}

	return nil
}

func (bc *Blockchain) ProcessBlockState(b Block) bool {
	for _, tx := range b.Transactions {

		isSystemTx := tx.Sender == "SYSTEM_MINT" || tx.Sender == "SYSTEM_PAYOUT"

		expectedNonce := bc.AccountNonces[tx.Sender]

		if !isSystemTx {
			if !VerifyTransaction(tx) {
				fmt.Printf("[Chain] REJECTED: Invalid Signature for TX %s\n", tx.ID)
				return false
			}

			if tx.Nonce != expectedNonce+1 {
				fmt.Printf("[Chain] REJECTED: Invalid Nonce for %s. Expected %d, Got %d\n", tx.Sender, expectedNonce+1, tx.Nonce)
				return false
			}

			if bc.Balances[tx.Sender] < tx.Amount {
				fmt.Printf("[Chain] REJECTED: Insufficient funds for %s\n", tx.Sender)
				return false
			}

			bc.Balances[tx.Sender] -= tx.Amount
			bc.AccountNonces[tx.Sender]++
		}

		switch tx.Type {
		case TxTypeTransfer:
			bc.Balances[tx.Receiver] += tx.Amount

		case TxTypeList:
			bc.processListing(tx)

		case TxTypeCloseExpired:
			bc.processExpiration(tx, b.Timestamp)

		case TxTypeBet:
			bc.processBet(tx)

		case TxTypeEscrow:
			bc.processEscrowLock(tx)

		case TxTypeResolve:
			bc.Balances[tx.Receiver] += tx.Amount

		case TxTypeMatchStart:
			parts := strings.Split(tx.Payload, "|")
			if len(parts) == 2 {
				matchID := parts[0]
				players := strings.Split(parts[1], ",")
				bc.MatchRosters[matchID] = players
				bc.MatchVotes[matchID] = make(map[string]string)
				fmt.Printf("[Consensus] Match %s started with %d players.\n", matchID, len(players))
			}

		case TxTypeWitness:
			var matchID, votedWinner string
			fmt.Sscanf(tx.Payload, "%s:%s", &matchID, &votedWinner)

			roster, exists := bc.MatchRosters[matchID]
			if !exists {
				fmt.Printf("[Consensus] Ignored vote for unknown match %s\n", matchID)
				continue
			}

			isParticipant := false
			for _, p := range roster {
				if p == tx.Sender {
					isParticipant = true
					break
				}
			}
			if !isParticipant {
				fmt.Printf("[Consensus] REJECTED vote from non-participant %s\n", tx.Sender)
				continue
			}

			bc.MatchVotes[matchID][tx.Sender] = votedWinner
			fmt.Printf("[Consensus] Player %s voted for %s in match %s\n", tx.Sender, votedWinner, matchID)

			voteCounts := make(map[string]int)
			for _, vote := range bc.MatchVotes[matchID] {
				voteCounts[vote]++
			}

			majorityNeeded := len(roster) / 2
			if voteCounts[votedWinner] > majorityNeeded {
				fmt.Printf("[Consensus] Majority Reached! %s wins Match %s. Executing Payouts...\n", votedWinner, matchID)

				payoutTxs := bc.GeneratePayouts(matchID, votedWinner)

				for _, pTx := range payoutTxs {
					bc.Balances[pTx.Receiver] += pTx.Amount
					fmt.Printf("[Payout] Sent %.2f to %s\n", pTx.Amount, pTx.Receiver)
				}

				delete(bc.MatchRosters, matchID)
				delete(bc.MatchVotes, matchID)
			}
		}
	}
	return true
}

func (bc *Blockchain) processListing(tx Transaction) {
	var assetID string
	var duration int
	fmt.Sscanf(tx.Payload, "%s:%d", &assetID, &duration)

	parts := strings.Split(tx.Payload, "|")
	if len(parts) < 5 {
		return
	}

	duration, _ = strconv.Atoi(parts[4])

	auction := &Auction{
		ID:        tx.ID,
		Seller:    tx.Sender,
		AssetID:   parts[0],
		Name:      parts[1],
		ImageURL:  parts[2],
		Wear:      parts[3],
		Price:     tx.Amount,
		ExpiresAt: time.Now().Unix() + int64(duration),
		State:     "OPEN",
	}

	bc.ActiveAuctions[tx.ID] = auction
	fmt.Printf("[Chain] New Auction Listed: %s for %.2f EDN\n", assetID, tx.Amount)
}

func (bc *Blockchain) processExpiration(tx Transaction, blockTime int64) {
	auctionID := tx.Payload

	if auction, exists := bc.ActiveAuctions[auctionID]; exists {
		if auction.State == "OPEN" && blockTime >= auction.ExpiresAt {
			auction.State = "EXPIRED"
			fmt.Printf("[Chain] Auction %s finalized as EXPIRED at block time %d.\n", auctionID, blockTime)
		} else {
			fmt.Printf("[Chain] consensus rejected expiration for %s (Not yet time).\n", auctionID)
		}
	}
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
		burnTx := Transaction{
			ID:        fmt.Sprintf("burn_%s_%d", matchID, time.Now().UnixNano()),
			Type:      TxTypeResolve,
			Sender:    "SYSTEM_PAYOUT",
			Receiver:  "BURN_ADDRESS",
			Amount:    pool.TotalPool,
			Timestamp: time.Now().Unix(),
			Signature: "CONSENSUS_VERIFIED",
		}

		delete(bc.ActivePools, matchID)
		return []Transaction{burnTx}
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

func (bc *Blockchain) VerifyTxSignature(tx Transaction) bool {
	msg := fmt.Sprintf("%s%s%f%d", tx.Sender, tx.Receiver, tx.Amount, tx.Timestamp)
	hash := sha256.Sum256([]byte(msg))
	sigBytes, err := hex.DecodeString(tx.Signature)
	if err != nil {
		return false
	}

	if len(sigBytes) != 64 {
		return false
	}

	_, err = ecdh.P256().NewPublicKey(tx.PublicKey)
	if err != nil {
		return false
	}

	x := new(big.Int).SetBytes(tx.PublicKey[1:33])
	y := new(big.Int).SetBytes(tx.PublicKey[33:])
	pubKey := ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	r := new(big.Int).SetBytes(sigBytes[:32])
	s := new(big.Int).SetBytes(sigBytes[32:])

	return ecdsa.Verify(&pubKey, hash[:], r, s)
}

func (bc *Blockchain) CreateGameBlock(proof GameProof, minerID string) Block {
	bc.Mutex.RLock()
	lastBlock := bc.LastBlock
	index := bc.LastBlock.Index + 1
	bc.Mutex.RUnlock()

	rewardAmount := CalculateReward(&proof)

	rewardTx := Transaction{
		ID:        fmt.Sprintf("tx_mint_%d", time.Now().UnixNano()),
		Sender:    "SYSTEM_MINT",
		Receiver:  minerID,
		Amount:    rewardAmount,
		Timestamp: time.Now().Unix(),
		Signature: "MINER_REWARD",
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

func GenerateKeyPair() (string, string) {
	privKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)

	privBytes, err := x509.MarshalECPrivateKey(privKey)
	if err != nil {
		return "", ""
	}
	privHex := hex.EncodeToString(privBytes)

	pubBytes, err := x509.MarshalPKIXPublicKey(&privKey.PublicKey)
	if err != nil {
		return "", ""
	}
	pubHex := hex.EncodeToString(pubBytes)

	return privHex, pubHex
}

func SignTransaction(privKeyHex string, tx *Transaction) error {
	privBytes, err := hex.DecodeString(privKeyHex)
	if err != nil {
		return fmt.Errorf("invalid private key hex")
	}

	privKey, err := x509.ParseECPrivateKey(privBytes)
	if err != nil {
		return fmt.Errorf("failed to parse EC private key: %v", err)
	}

	hash := tx.GenerateTxHash()
	r, s, err := ecdsa.Sign(rand.Reader, privKey, hash)
	if err != nil {
		return err
	}

	rBytes := r.Bytes()
	sBytes := s.Bytes()
	sigBytes := make([]byte, 64)
	copy(sigBytes[32-len(rBytes):32], rBytes)
	copy(sigBytes[64-len(sBytes):64], sBytes)
	tx.Signature = hex.EncodeToString(sigBytes)
	return nil
}
