use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use postgres::{Client, NoTls};
use source2_demo::prelude::*;
use memmap2::Mmap;

#[repr(C)]
pub struct DemoResult {
    success: bool,
    json_ptr: *mut c_char,
}

#[unsafe(no_mangle)]
pub extern "C" fn analyze_demo(
    path_ptr: *const c_char, 
    db_url_ptr: *const c_char
) -> *mut c_char {
    let c_path = unsafe { CStr::from_ptr(path_ptr) };
    let c_db_url = unsafe { CStr::from_ptr(db_url_ptr) };
    
    let path = c_path.to_str().unwrap_or("");
    let db_url = c_db_url.to_str().unwrap_or("");

    match process_internal(path, db_url) {
        Ok(json) => CString::new(json).unwrap().into_raw(),
        Err(e) => CString::new(format!("{{ \"error\": \"{}\" }}", e)).unwrap().into_raw(),
    }
}

// Round contribution for KAST
#[derive(Default)]
struct RoundStat {
    kills: i32,
    assists: i32,
    survived: bool,
}

// Player stats struct for tracking
#[derive(Default, Clone)]
struct PlayerStats {
    kills: i32,
    deaths: i32,
    assists: i32,
    total_damage: f32,
    name: String,
    steam_id: String,
    round_stats: Vec<RoundStat>, // For KAST and Impact
    opening_kills: i32, // For Impact
    multi_kills: i32, // Count of rounds with 2+ kills
}

// Observer for collecting CS2 stats
#[derive(Default)]
struct StatsCollector {
    players: HashMap<u32, PlayerStats>, // Key: user ID (u32)
    current_round: u32,
    total_rounds: u32,
    score_ct: i32,
    score_t: i32,
    round_first_kill: bool, // Track if first kill in round
    alive_players: HashMap<u32, bool>, // Per round alive tracking
}

#[observer(all)]
impl StatsCollector {
    #[on_game_event("round_start")]
    fn handle_round_start(&mut self, _ctx: &Context, _event: &GameEvent) -> ObserverResult {
        self.current_round += 1;
        self.total_rounds += 1;
        self.round_first_kill = true;
        // Assume all spawned players are alive at start (expand with player_spawn if needed)
        for stats in self.players.values_mut() {
            stats.round_stats.push(RoundStat::default());
            self.alive_players.insert(/* player user id */, true); // Populate from players
        }
        Ok(())
    }

    #[on_game_event("round_end")]
    fn handle_round_end(&mut self, _ctx: &Context, event: &GameEvent) -> ObserverResult {
        if let Some(winner) = event.get_value("winner").and_then(|v| v.as_i32()) {
            if winner == 3 { // CT win
                self.score_ct += 1;
            } else if winner == 2 { // T win
                self.score_t += 1;
            }
        }
        // Finalize KAST for the round
        for (id, stats) in self.players.mut_iter() {
            let current_round = stats.round_stats.last_mut().unwrap();
            current_round.survived = *self.alive_players.get(id).unwrap_or(&false);
            if current_round.kills > 1 {
                stats.multi_kills += 1;
            }
        }
        self.alive_players.clear();
        Ok(())
    }

    #[on_game_event("player_death")]
    fn handle_player_death(&mut self, ctx: &Context, event: &GameEvent) -> ObserverResult {
        let victim_id = event.get_value("userid").and_then(|v| v.as_u32()).unwrap_or(0);
        let attacker_id = event.get_value("attacker").and_then(|v| v.as_u32()).unwrap_or(0);
        let assister_id = event.get_value("assister").and_then(|v| v.as_u32()).unwrap_or(0);

        // Populate name/steam_id if not set
        for &id in &[victim_id, attacker_id, assister_id] {
            if id != 0 {
                if let Some(stats) = self.players.get_mut(&id) {
                    if stats.name.is_empty() {
                        if let Some(pr) = ctx.entities().get_by_class_name("CCSPlayerResource") {
                            let player_index = (id - 1) as usize;
                            stats.name = property!(pr, "m_szPlayerName.{:04}", player_index).unwrap_or_default();
                            stats.steam_id = property!(pr, "m_iSteamID.{:04}", player_index).unwrap_or_default().to_string(); // Assume u64, convert to string
                        }
                    }
                }
            }
        }

        // Increment deaths for victim
        if let Some(stats) = self.players.get_mut(&victim_id) {
            stats.deaths += 1;
            if let Some(current_round) = stats.round_stats.last_mut() {
                current_round.survived = false;
            }
            self.alive_players.insert(victim_id, false);
        }

        // Increment kills for attacker (if not suicide/world)
        if attacker_id != 0 && attacker_id != victim_id {
            if let Some(stats) = self.players.get_mut(&attacker_id) {
                stats.kills += 1;
                if let Some(current_round) = stats.round_stats.last_mut() {
                    current_round.kills += 1;
                }
                if self.round_first_kill {
                    stats.opening_kills += 1;
                    self.round_first_kill = false;
                }
            }
        }

        // Increment assists
        if assister_id != 0 {
            if let Some(stats) = self.players.get_mut(&assister_id) {
                stats.assists += 1;
                if let Some(current_round) = stats.round_stats.last_mut() {
                    current_round.assists += 1;
                }
            }
        }

        Ok(())
    }

    #[on_game_event("player_hurt")]
    fn handle_player_hurt(&mut self, _ctx: &Context, event: &GameEvent) -> ObserverResult {
        let victim_id = event.get_value("userid").and_then(|v| v.as_u32()).unwrap_or(0);
        let attacker_id = event.get_value("attacker").and_then(|v| v.as_u32()).unwrap_or(0);
        let dmg_health = event.get_value("dmg_health").and_then(|v| v.as_f32()).unwrap_or(0.0);

        // Add damage to attacker's total (if not self-damage)
        if attacker_id != 0 && attacker_id != victim_id {
            if let Some(stats) = self.players.get_mut(&attacker_id) {
                stats.total_damage += dmg_health;
            }
        }
        Ok(())
    }

    #[on_game_event("player_spawn")]
    fn handle_player_spawn(&mut self, _ctx: &Context, event: &GameEvent) -> ObserverResult {
        let player_id = event.get_value("userid").and_then(|v| v.as_u32()).unwrap_or(0);
        self.players.entry(player_id).or_insert_with(Default::default);
        self.alive_players.insert(player_id, true);
        Ok(())
    }
}

fn process_internal(path: &str, db_url: &str) -> Result<String, String> {
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mmap = unsafe { Mmap::map(&file).map_err(|e| e.to_string())? };
    let mut parser = Parser::new(&mmap).map_err(|e| e.to_string())?;
    
    let header = parser.header();
    let map_name = header.map_name.clone();
    
    // Register observer and parse
    let collector = parser.register_observer::<StatsCollector>();
    parser.run_to_end().map_err(|e| e.to_string())?;

    // Connect to DB
    let mut client = Client::connect(db_url, NoTls).map_err(|e| e.to_string())?;

    // 1. Insert Match
    let row = client.query_one(
        "INSERT INTO matches (file_name, map_name, score_ct, score_t) VALUES ($1, $2, $3, $4) RETURNING id",
        &[&path, &map_name, &collector.borrow().score_ct, &collector.borrow().score_t]
    ).map_err(|e| e.to_string())?;
    
    let match_id: i32 = row.get(0);

    // 2. Insert Player Stats
    let mut players_json = Vec::new();
    for (id, stats) in collector.borrow().players.iter() {
        let rounds = collector.borrow().total_rounds as f32;
        let kpr = stats.kills as f32 / rounds;
        let apr = stats.assists as f32 / rounds;
        let adr = stats.total_damage / rounds;
        // Compute KAST from round_stats
        let kast_rounds = stats.round_stats.iter().filter(|r| r.kills > 0 || r.assists > 0 || r.survived).count() as f32;
        let kast = kast_rounds / rounds;
        // Compute Impact
        let impact = 1.0 + (stats.opening_kills as f32 * 0.5 + stats.multi_kills as f32 * 0.3);
        let rating = (0.0073 * kpr + 0.3591 * kast + 0.0032 * adr + 0.0073 * impact + 0.0032 * apr) / 1.0;

        client.execute(
            "INSERT INTO player_stats (match_id, steam_id, name, kills, deaths, hltv_rating, adr) VALUES ($1, $2, $3, $4, $5, $6, $7)",
            &[&match_id, &stats.steam_id, &stats.name, &stats.kills, &stats.deaths, &rating, &adr]
        ).map_err(|e| e.to_string())?;

        players_json.push(serde_json::json!({
            "name": stats.name,
            "kills": stats.kills,
            "deaths": stats.deaths,
            "rating": rating,
            "adr": adr
        }));
    }

    // Return JSON for the UI
    let result = serde_json::json!({
        "status": "success",
        "match_id": match_id,
        "map": map_name,
        "players": players_json
    });

    Ok(result.to_string())
}