# 🍎 Eden

**The Decentralized Counter-Strike 2 Competitive Hub**

![License](https://img.shields.io/badge/License-GPL%203.0-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Windows-blue)
![Status](https://img.shields.io/badge/Status-Alpha-orange)

**Eden** is a hybrid-architecture application that merges a peer-to-peer VPN, a custom blockchain, and high-performance game analytics into a single competitive platform for Counter-Strike 2. It allows players to host decentralized matches, wager on outcomes, trade virtual assets, and analyze gameplay with professional-grade metrics.

---

## ✨ Key Features

### 🛡️ **P2P Virtual Network (EdenVPN)**
* **Virtual LAN:** Creates a secure, encrypted virtual network (10.x.x.x) using the **Wintun** driver, allowing players to connect directly without dedicated servers.
* **Libp2p Mesh:** Utilizes a Kademlia DHT for peer discovery and hole-punching to bypass NATs.

### 🔗 **EdenChain (Blockchain)**
* **Custom Consensus:** A Proof-of-Gameplay authority chain where match outcomes (verified by GSI) mine blocks and mint **EDN** tokens.
* **Smart Wagering:** Decentralized betting pools for live matches (CT vs T) with automated payouts based on consensus results.
* **Asset Marketplace:** List Steam inventory items (Skins) for auction using a trustless escrow system backed by the chain.

### 📊 **Deep Analytics (Rust Core)**
* **Automated Tribunal:** High-performance Go engine parses `.dem` replay files using `demoinfocs-golang` to automatically detect suspicious snaps and wall-tracing.
* **Glicko-2 Rating (Abel2):** Decentralized calculation of player skill (Rating & Deviation) directly on the blockchain.
* **Persistent Stats:** Stores match history and player performance locally.

### 🎮 **Competitive Suite**
* **Game State Integration (GSI):** Real-time match tracking (Score, Phase, MVPs) via a local HTTP oracle.
* **Map Vetoes & Penalties:** Integrated lobby system with map vetos, match ready-states, and automatic queue bans for dodgers.
* **Social Hub:** Encrypted Friend Codes, direct messaging, and profile progression (Levels/XP).
* **Pro Configs:** Built-in repository of professional player settings.

---

## 🏗️ Architecture

Eden leverages **Foreign Function Interfaces (FFI)** to combine the strengths of four different languages:

| Component | Language | Description |
| :--- | :--- | :--- |
| **Frontend** | **Dart (Flutter)** | The user interface, handling state management, Steam Web API calls, and FFI orchestration. |
| **Core Network** | **Go** | Compiled as `Cain.dll`. Handles the Blockchain (`EdenChain`), Libp2p networking, and Game State Integration. |
| **System Bridge** | **C++** | Compiled as `adam.dll`. Manages low-level Windows Tun/Tap adapters (Wintun) and bridges packet flow to Go. |
| **Analytics** | **Rust** | Compiled as `demo_core.dll` (or `.so`). A dedicated library for parsing binary demo files and SQL interactions. |

---

## 🛠️ Prerequisites

Before building, ensure you have the following installed:

* **Flutter SDK:** (Stable Channel)
* **Go:** v1.20+ (Required for `Cain.dll`)
* **Rust:** Latest Stable (Required for `demo_core.dll`)
* **C++ Compiler:** MSVC (Visual Studio 2022) or MinGW
* **PostgreSQL:** Local service running on port `5432`
* **Wintun:** `wintun.dll` and `wintun.lib` (from [wintun.net](https://www.wintun.net))

---

## 🚀 Build Instructions

### 1. Build the Blockchain Core (Go)
Compile the Go backend into a C-shared library.

```bash
cd go_src
# Builds Cain.dll and Cain.h
go build -o Cain.dll -buildmode=c-shared main.go eve.go
```

### 2. Build the Demo Parser (Rust)
Compile the analytics engine.

```bash
cd rust_src
# Builds demo_core.dll
cargo build --release
```

### 3. Build the System Bridge (C++)
Compile the Wintun adapter bridge. Ensure wintun.lib is in your library path.

```bash
# Example using MSVC
cl /LD adam.cpp /Fe:adam.dll /I.\wintun\include wintun.lib ws2_32.lib shell32.lib
```

### 4. Database Setup
Initialize the PostgreSQL database for statistics storage(or run db_configuration.bat).

```sql
CREATE DATABASE eden_db;

CREATE TABLE matches (
    id SERIAL PRIMARY KEY,
    map_name TEXT,
    score_ct INT,
    score_t INT,
    file_name TEXT,
    played_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE player_stats (
    id SERIAL PRIMARY KEY,
    match_id INT REFERENCES matches(id),
    steam_id TEXT,
    name TEXT,
    kills INT,
    deaths INT,
    adr FLOAT,
    hltv_rating FLOAT
);
```

### 5. Run the Application
Place Cain.dll, adam.dll, demo_core.dll, and wintun.dll in the root/assets directory accessible by the Flutter executable.
Run via Flutter:

```bash
flutter pub get
flutter run -d windows
```

⚙️ Configuration
Eden uses a eden_config.json file for local settings. If not present, it can be generated via the in-app settings menu.

```JSON
{
  "cs2_path": "YOUR_ACTUAL_CS2_PATH",
  "db_user": "YOUR_POSTGRES_USERNAME",
  "db_password": "YOUR_POSTGRES_PASSWORD",
  "steam_api_key": "YOUR_STEAM_WEB_API_KEY",
  "steam_id_key": "YOUR_STEAM_64_ID",
  "language": "English"
}
```

📦 Third-Party Libraries
Eden heavily relies on the open-source community. The Go backend utilizes:

libp2p: The core modular network stack (including go-libp2p-kad-dht, go-libp2p-pubsub, and go-multiaddr).

goleveldb: Fast, local key/value storage powering the EdenChain state.

demoinfocs-golang: High-performance CS:GO and CS2 demo parser used for the automated Tribunal.

golang/geo: S2 geometry library (specifically r3 vectors) used to detect anomalous crosshair movements and wall-tracing.

Other Third party: 

1. Counter-Strike, Counter-Strike 2, CS:GO, and the Steam logo are trademarks and/or registered trademarks of Valve Corporation. Eden is not endorsed by or affiliated with Valve Corporation.

2. Networking infrastructure powered by Wintun. Copyright © 2019 WireGuard LLC.

3. Pro player imagery and configuration data sourced from ProSettings.net.

⚠️ Disclaimer
Educational Purpose Only: This software intercepts network traffic and modifies game configurations (GSI). While it includes an "Anti-Cheat" shield toggle, usage alongside Valve Anti-Cheat (VAC) is at your own risk.

Virtual Currency: The EDN token is a testnet currency used for gameplay mechanics and has no real-world monetary value.

Reason 1: The project has many unresolved issues. 

Reason 2: Respect local laws and do not use it for illegal purposes such as money laundering, fraud, or other illegal activities. If any legal issues arise due to malicious use/modification of the code, the user/modifier will bear the consequences, and the original author will not be held responsible.

License: GPL 3.0 (See LICENSE.txt)

Copyright © 2026 LukaKrajina & The Eden Project