CREATE TABLE IF NOT EXISTS matches (
    id SERIAL PRIMARY KEY,
    map_name VARCHAR(255) NOT NULL,
    score_ct INTEGER NOT NULL,
    score_t INTEGER NOT NULL,
    file_name VARCHAR(255),
    played_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS player_stats (
    id SERIAL PRIMARY KEY,
    match_id INTEGER REFERENCES matches(id) ON DELETE CASCADE,
    steam_id VARCHAR(64) NOT NULL,
    name VARCHAR(255) NOT NULL,
    kills INTEGER NOT NULL DEFAULT 0,
    deaths INTEGER NOT NULL DEFAULT 0,
    adr REAL NOT NULL DEFAULT 0.0,
    hltv_rating REAL NOT NULL DEFAULT 0.0,
    
    CONSTRAINT unique_player_match UNIQUE (match_id, steam_id)
);

CREATE INDEX idx_player_stats_match_id ON player_stats(match_id);