use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use postgres::{Client, NoTls};
use source2_demo::{FieldValue, prelude::*};
use source2_demo::proto::CDemoFileHeader;
use memmap2::Mmap;

// --- Data Structures ---

#[derive(Default)]
struct PlayerStats {
    steam_id: String,
    name: String,
    kills: i32,
    deaths: i32,
    assists: i32,
    total_damage: i32,
    mvps: i32,
}

#[derive(Default)]
struct MatchCollector {
    players: HashMap<u64, PlayerStats>, // Key: UserID
    score_ct: i32,
    score_t: i32,
    map_name: String,
}

fn extract_id(val: Option<&EventValue>) -> u64 {
    match val {
        Some(EventValue::Int(v)) => *v as u64,
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
                let victim = extract_id(event.get_value("userid").ok());
                let attacker = extract_id(event.get_value("attacker").ok());
                let assister = extract_id(event.get_value("assister").ok());

                if attacker != 0 && attacker != victim {
                    let p = self.get_player(ctx, attacker);
                    p.kills += 1;
                }
                if victim != 0 {
                    let p = self.get_player(ctx, victim);
                    p.deaths += 1;
                }
                if assister != 0 {
                    let p = self.get_player(ctx, assister);
                    p.assists += 1;
                }
            },
            "round_end" => {
                let winner = extract_i32(event.get_value("winner").ok());
                if winner == 2 { self.score_t += 1; }      // T Win
                if winner == 3 { self.score_ct += 1; }     // CT Win
            },
            "round_mvp" => {
                let userid = extract_id(event.get_value("userid").ok());
                if userid != 0 {
                    let p = self.get_player(ctx, userid);
                    p.mvps += 1;
                }
            },
            "player_hurt" => {
                let attacker = extract_id(event.get_value("attacker").ok());
                let dmg = extract_i32(event.get_value("dmg_health").ok());
                
                if attacker != 0 {
                    let p = self.get_player(ctx, attacker);
                    p.total_damage += dmg;
                }
            },
            _ => {}
        }
        Ok(())
    }

    fn get_player<'a>(&'a mut self, ctx: &Context, userid: u64) -> &'a mut PlayerStats {
        self.players.entry(userid).or_insert_with(|| {
            let mut name = format!("User {}", userid);
            let mut steam_id = "BOT".to_string();

            if let Ok(player) = ctx.entities().get_by_class_id((userid as i32).try_into().unwrap()) {
                if let Ok(field_val) = player.get_property_by_name("m_iszPlayerName") {
                    if let FieldValue::String(n) = field_val {
                        name = n.to_string();
                    }
                } else if let Ok(field_val) = player.get_property_by_name("m_szName") {
                    if let FieldValue::String(n) = field_val {
                        name = n.to_string();
                    }
                }
                
                if let Ok(field_val) = player.get_property_by_name("m_iSteamID") {
                    match field_val {
                        FieldValue::Signed32(s) => steam_id = s.to_string(),
                        FieldValue::Unsigned64(s) => steam_id = s.to_string(),
                        _ => {}
                    }
                }
            }
            
            PlayerStats { name, steam_id, ..Default::default() }
        })
    }
}

// --- Internal Processing ---

fn process_demo(path: &str, db_url: &str) -> Result<String, Box<dyn std::error::Error>> {
    let file = std::fs::File::open(path)?;
    let mmap = unsafe { Mmap::map(&file)? };
    
    let mut parser = Parser::new(&mmap)?;
    let collector = parser.register_observer::<MatchCollector>();
    parser.run_to_end()?;

    let collector = collector.borrow();
    
    let mut client = Client::connect(db_url, NoTls)?;
    
    let row = client.query_one(
        "INSERT INTO matches (map_name, score_ct, score_t, file_name) VALUES ($1, $2, $3, $4) RETURNING id",
        &[&collector.map_name, &collector.score_ct, &collector.score_t, &path]
    )?;
    let match_id: i32 = row.get(0);

    for stats in collector.players.values() {
        if stats.steam_id == "BOT" { continue; }
        
        let rounds = (collector.score_ct + collector.score_t).max(1) as f32;
        let adr = stats.total_damage as f32 / rounds;
        
        let kill_rating = stats.kills as f32 / rounds / 0.679;
        let survival_rating = (rounds - stats.deaths as f32) / rounds / 0.317;
        let rating = (kill_rating + 0.7 * survival_rating) / 2.7; 

        client.execute(
            "INSERT INTO player_stats (match_id, steam_id, name, kills, deaths, adr, hltv_rating) VALUES ($1, $2, $3, $4, $5, $6, $7)",
            &[&match_id, &stats.steam_id, &stats.name, &stats.kills, &stats.deaths, &adr, &rating]
        )?;
    }

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