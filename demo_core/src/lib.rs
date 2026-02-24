use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use postgres::{Client, NoTls};
use source2_demo::{FieldValue, prelude::*};
use source2_demo::proto::CDemoFileHeader;
use memmap2::Mmap;

// --- Data Structures ---

#[derive(Default, Clone)] // Added Clone for safer handling
struct PlayerStats {
    steam_id: String,
    name: String,
    kills: i32,
    deaths: i32,
    assists: i32,
    total_damage: i32,
    mvps: i32,
    team_num: i32, // Added to track team for Friendly Fire checks
}

#[derive(Default)]
struct MatchCollector {
    players: HashMap<u64, PlayerStats>, // Key: UserID
    score_ct: i32,
    score_t: i32,
    map_name: String,
}

// --- Helper Functions ---

fn extract_id(val: Option<&EventValue>) -> u64 {
    match val {
        Some(EventValue::Int(v)) => *v as u64,
        Some(EventValue::U64(v)) => *v,
        _ => 0,
    }
}

fn extract_i32(val: Option<&EventValue>) -> i32 {
    match val {
        Some(EventValue::Int(v)) => *v,
        Some(EventValue::Int(v)) => *v as i32,
        Some(EventValue::Float(v)) => *v as i32,
        Some(EventValue::Byte(v)) => *v as i32, // Critical fix for round_end
        _ => 0,
    }
}

// --- Observer Implementation ---

#[observer(all)]
impl MatchCollector {
    #[on_message]
    fn handle_header(&mut self, _ctx: &Context, header: &CDemoFileHeader) -> ObserverResult {
        self.map_name = header.map_name.clone().unwrap_or_default();
        Ok(())
    }

    #[on_game_event]
    fn handle_event(&mut self, ctx: &Context, event: &GameEvent) -> ObserverResult {
        match event.name().as_ref() {
            "player_death" => {
                let victim_id = extract_id(event.get_value("userid").ok());
                let attacker_id = extract_id(event.get_value("attacker").ok());
                let assister_id = extract_id(event.get_value("assister").ok());

                // FIX #2: Factional Integrity (No Team Kills counting as kills)
                let attacker_team = self.get_player_team(ctx, attacker_id);
                let victim_team = self.get_player_team(ctx, victim_id);

                if attacker_id != 0 && attacker_id != victim_id && attacker_team != victim_team {
                    let p = self.get_player(ctx, attacker_id);
                    p.kills += 1;
                }
                
                if victim_id != 0 {
                    let p = self.get_player(ctx, victim_id);
                    p.deaths += 1;
                }
                
                // Assist logic implies distinct players
                if assister_id != 0 && assister_id != attacker_id {
                    let p = self.get_player(ctx, assister_id);
                    p.assists += 1;
                }
            },
            "round_end" => {
                // FIX #1 Usage: winner is parsed correctly as byte -> i32
                let winner = extract_i32(event.get_value("winner").ok());
                
                // Source 2 Team IDs: 2 = T, 3 = CT
                if winner == 2 { self.score_t += 1; }      
                if winner == 3 { self.score_ct += 1; }     
            },
            "round_mvp" => {
                let userid = extract_id(event.get_value("userid").ok());
                if userid != 0 {
                    let p = self.get_player(ctx, userid);
                    p.mvps += 1;
                }
            },
            "player_hurt" => {
                let attacker_id = extract_id(event.get_value("attacker").ok());
                let victim_id = extract_id(event.get_value("userid").ok()); // Need victim to check team
                let dmg = extract_i32(event.get_value("dmg_health").ok());
                
                let attacker_team = self.get_player_team(ctx, attacker_id);
                let victim_team = self.get_player_team(ctx, victim_id);

                // FIX #2: Only count damage against enemies
                if attacker_id != 0 && attacker_id != victim_id && attacker_team != victim_team {
                    let p = self.get_player(ctx, attacker_id);
                    p.total_damage += dmg;
                }
            },
            _ => {}
        }
        Ok(())
    }

    // Helper to peek team without creating a full entry if not needed
    fn get_player_team(&self, ctx: &Context, userid: u64) -> i32 {
        if let Some(p) = self.players.get(&userid) {
            return p.team_num;
        }
        // Fallback: try to peek entity
        if let Ok(controller) = ctx.entities().get_by_class_id((userid as i32).try_into().unwrap()) {
             // Try standard TeamNum property
             if let Ok(FieldValue::Signed32(t)) = controller.get_property_by_name("m_iTeamNum") {
                 return *t;
             }
        }
        0
    }

    fn get_player<'a>(&'a mut self, ctx: &Context, userid: u64) -> &'a mut PlayerStats {
        self.players.entry(userid).or_insert_with(|| {
            let mut name = format!("User {}", userid);
            let mut steam_id = "BOT".to_string();
            let mut team_num = 0;

            if let Ok(entity) = ctx.entities().get_by_class_id((userid as i32).try_into().unwrap()) {
                
                let class = entity.class();
                if class.name() == "CCSPlayerController" {
                     // Extract Name
                        if let Ok(FieldValue::String(n)) = entity.get_property_by_name("m_iszPlayerName") {
                            name = n.to_string();
                        } else if let Ok(FieldValue::String(n)) = entity.get_property_by_name("m_szName") {
                            name = n.to_string();
                        }

                        // Extract SteamID
                        if let Ok(field_val) = entity.get_property_by_name("m_steamID") {
                            match field_val {
                                FieldValue::Unsigned64(s) => steam_id = s.to_string(),
                                FieldValue::Signed32(s) => steam_id = s.to_string(), // Sometimes maps to 32
                                _ => {}
                            }
                        }

                         // Extract Team
                        if let Ok(FieldValue::Signed32(t)) = entity.get_property_by_name("m_iTeamNum") {
                            team_num = *t;
                        }
                    }
            }

            if steam_id == "BOT" {
                steam_id = format!("BOT_{}", name);
            }

            PlayerStats { name, steam_id, team_num, ..Default::default() }
        })
    }
}


fn process_demo(path: &str, db_url: &str) -> Result<String, Box<dyn std::error::Error>> {
    let file = std::fs::File::open(path)?;
    let mmap = unsafe { Mmap::map(&file)? };
    
    let mut parser = Parser::new(&mmap)?;
    let collector = parser.register_observer::<MatchCollector>();
    parser.run_to_end()?;

    let collector = collector.borrow();
    
    let mut client = Client::connect(db_url, NoTls)?;
    
    let mut transaction = client.transaction()?;

    let row = transaction.query_one(
        "INSERT INTO matches (map_name, score_ct, score_t, file_name) VALUES ($1, $2, $3, $4) RETURNING id",
        &[&collector.map_name, &collector.score_ct, &collector.score_t, &path]
    )?;
    let match_id: i32 = row.get(0);

    // Calculated valid rounds (Avoid divide by zero)
    let total_rounds = (collector.score_ct + collector.score_t).max(1) as f32;

    for stats in collector.players.values() {

        if stats.steam_id == "BOT" { continue; }
        
        // Basic calculations
        let adr = stats.total_damage as f32 / total_rounds;
        
        // Simplified HLTV 2.0 approximation
        let kill_rating = stats.kills as f32 / total_rounds / 0.679;
        let survival_rating = (total_rounds - stats.deaths as f32) / total_rounds / 0.317;
        let rating = (kill_rating + 0.7 * survival_rating) / 2.7; 

        transaction.execute(
            "INSERT INTO player_stats (match_id, steam_id, name, kills, deaths, adr, hltv_rating) VALUES ($1, $2, $3, $4, $5, $6, $7)",
            &[&match_id, &stats.steam_id, &stats.name, &stats.kills, &stats.deaths, &adr, &rating]
        )?;
    }

    // Commit the transaction
    transaction.commit()?;

    Ok(format!("{{ \"success\": true, \"match_id\": {} }}", match_id))
}


#[unsafe(no_mangle)]
pub extern "C" fn analyze_demo(path_ptr: *const c_char, db_url_ptr: *const c_char) -> *mut c_char {
    let c_path = unsafe { CStr::from_ptr(path_ptr) };
    let c_db = unsafe { CStr::from_ptr(db_url_ptr) };
    
    let path = c_path.to_str().unwrap_or("");
    let db = c_db.to_str().unwrap_or("");

    let result = match process_demo(path, db) {
        Ok(json) => json,
        Err(e) => format!("{{ \"success\": false, \"error\": \"{}\" }}", e),
    };

    CString::new(result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn free_string(s: *mut c_char) {
    unsafe {
        if !s.is_null() {
            let _ = CString::from_raw(s);
        }
    }
}