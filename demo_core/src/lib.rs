use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use postgres::{Client, NoTls};
use source2_demo::prelude::*;
use source2_demo::proto::CDemoFileHeader;
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


//  ROUND & PLAYER DATA

#[derive(Default)]
struct RoundStat {
    kills: i32,
    assists: i32,
    survived: bool,
}

#[derive(Default)]
struct PlayerStats {
    kills: i32,
    deaths: i32,
    assists: i32,
    total_damage: f32,
    name: String,
    steam_id: String,
    round_stats: Vec<RoundStat>,
    opening_kills: i32,
    multi_kills: i32,
}

#[derive(Default)]
struct StatsCollector {
    players: HashMap<u32, PlayerStats>,   // key = userid (u32)
    total_rounds: u32,
    score_ct: i32,
    score_t: i32,
    map_name: String,
    round_first_kill: bool,
}

//  OBSERVER – now compiles reliably

#[observer(all)]
impl StatsCollector {
    // Header (map name) – runs once at start
    #[on_message]
    fn handle_header(&mut self, _ctx: &Context, header: &CDemoFileHeader) -> ObserverResult {
        self.map_name = header.map_name.clone();
        Ok(())
    }

    // Single dispatcher – the safest way with the macro
    #[on_game_event]
    fn on_game_event(&mut self, ctx: &Context, event: &GameEvent) -> ObserverResult {
        match event.name().as_str() {
            "round_start" => self.handle_round_start(ctx, event),
            "round_end"   => self.handle_round_end(ctx, event),
            "player_death" => self.handle_player_death(ctx, event),
            "player_hurt"  => self.handle_player_hurt(ctx, event),
            "player_spawn" => self.handle_player_spawn(ctx, event),
            _ => Ok(()),
        }
    }

    fn handle_round_start(&mut self, _ctx: &Context, _event: &GameEvent) -> ObserverResult {
        self.total_rounds += 1;
        self.round_first_kill = true;
        for stats in self.players.values_mut() {
            stats.round_stats.push(RoundStat::default());
        }
        Ok(())
    }

    fn handle_round_end(&mut self, _ctx: &Context, event: &GameEvent) -> ObserverResult {
        if let Ok(val) = event.get_value("winner") {
            if let Some(winner) = val.as_i32() {
                if winner == 3 { self.score_ct += 1; }
                else if winner == 2 { self.score_t += 1; }
            }
        }

        for stats in self.players.values_mut() {
            if let Some(r) = stats.round_stats.last_mut() {
                if r.kills > 1 {
                    stats.multi_kills += 1;
                }
            }
        }
        Ok(())
    }

    fn handle_player_death(&mut self, ctx: &Context, event: &GameEvent) -> ObserverResult {
        let victim_id   = event.get_value("userid").ok().and_then(|v| v.as_u32()).unwrap_or(0);
        let attacker_id = event.get_value("attacker").ok().and_then(|v| v.as_u32()).unwrap_or(0);
        let assister_id = event.get_value("assister").ok().and_then(|v| v.as_u32()).unwrap_or(0);

        for &id in &[victim_id, attacker_id, assister_id] {
            if id == 0 { continue; }
            let stats = self.players.entry(id).or_default();
            if !stats.name.is_empty() { continue; }
            if let Some(pr) = ctx.entities().get_by_class_name("CCSPlayerResource") {
                let idx = (id - 1) as usize;
                stats.name = property!(pr, "m_szPlayerName.{:04}", idx)
                    .unwrap_or_default()
                    .to_string();
                if let Some(sid) = try_property!(pr, "m_iSteamID.{:04}", idx) {
                    stats.steam_id = sid.to_string();
                }
            }
        }

        if let Some(stats) = self.players.get_mut(&victim_id) {
            stats.deaths += 1;
            if let Some(r) = stats.round_stats.last_mut() { r.survived = false; }
        }

        if attacker_id != 0 && attacker_id != victim_id {
            if let Some(stats) = self.players.get_mut(&attacker_id) {
                stats.kills += 1;
                if let Some(r) = stats.round_stats.last_mut() { r.kills += 1; }
                if self.round_first_kill {
                    stats.opening_kills += 1;
                    self.round_first_kill = false;
                }
            }
        }

        if assister_id != 0 {
            if let Some(stats) = self.players.get_mut(&assister_id) {
                stats.assists += 1;
                if let Some(r) = stats.round_stats.last_mut() { r.assists += 1; }
            }
        }
        Ok(())
    }

    fn handle_player_hurt(&mut self, _ctx: &Context, event: &GameEvent) -> ObserverResult {
        let attacker = event.get_value("attacker").ok().and_then(|v| v.as_u32()).unwrap_or(0);
        let victim   = event.get_value("userid").ok().and_then(|v| v.as_u32()).unwrap_or(0);
        let dmg      = event.get_value("dmg_health").ok().and_then(|v| v.as_f32()).unwrap_or(0.0);

        if attacker != 0 && attacker != victim {
            if let Some(stats) = self.players.get_mut(&attacker) {
                stats.total_damage += dmg;
            }
        }
        Ok(())
    }

    fn handle_player_spawn(&mut self, _ctx: &Context, event: &GameEvent) -> ObserverResult {
        let id = event.get_value("userid").ok().and_then(|v| v.as_u32()).unwrap_or(0);
        if id != 0 {
            self.players.entry(id).or_default();
        }
        Ok(())
    }
}


fn process_internal(path: &str, db_url: &str) -> Result<String, String> {
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mmap = unsafe { Mmap::map(&file).map_err(|e| e.to_string())? };
    let mut parser = Parser::new(&mmap).map_err(|e| e.to_string())?;

    let collector = parser.register_observer::<StatsCollector>();
    parser.run_to_end().map_err(|e| e.to_string())?;

    let coll = collector.borrow();
    let map_name = if coll.map_name.is_empty() { "unknown".into() } else { coll.map_name.clone() };

    let mut client = Client::connect(db_url, NoTls).map_err(|e| e.to_string())?;

    // Insert match
    let row = client.query_one(
        "INSERT INTO matches (file_name, map_name, score_ct, score_t) VALUES ($1, $2, $3, $4) RETURNING id",
        &[&path, &map_name, &coll.score_ct, &coll.score_t],
    ).map_err(|e| e.to_string())?;
    let match_id: i32 = row.get(0);

    let mut players_json = Vec::new();
    let rounds = coll.total_rounds.max(1) as f32;

    for stats in coll.players.values() {
        let kpr = stats.kills as f32 / rounds;
        let apr = stats.assists as f32 / rounds;
        let adr = stats.total_damage / rounds;
        let kast_rounds = stats.round_stats.iter().filter(|r| r.kills > 0 || r.assists > 0 || r.survived).count() as f32;
        let kast = kast_rounds / rounds;
        let impact = 1.0 + (stats.opening_kills as f32 * 0.5) + (stats.multi_kills as f32 * 0.3);

        let rating = 0.0073 * kpr + 0.3591 * kast + 0.0032 * adr + 0.0073 * impact + 0.0032 * apr;

        client.execute(
            "INSERT INTO player_stats (match_id, steam_id, name, kills, deaths, hltv_rating, adr) VALUES ($1, $2, $3, $4, $5, $6, $7)",
            &[&match_id, &stats.steam_id, &stats.name, &stats.kills, &stats.deaths, &rating, &adr],
        ).map_err(|e| e.to_string())?;

        players_json.push(serde_json::json!({
            "name": stats.name,
            "kills": stats.kills,
            "deaths": stats.deaths,
            "rating": rating,
            "adr": adr,
        }));
    }

    let result = serde_json::json!({
        "status": "success",
        "match_id": match_id,
        "map": map_name,
        "players": players_json
    });

    Ok(result.to_string())
}