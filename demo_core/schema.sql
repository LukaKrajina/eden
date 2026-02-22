CREATE TABLE IF NOT EXISTS matches (
    id SERIAL PRIMARY KEY,
    file_name VARCHAR(255) NOT NULL,
    map_name VARCHAR(64) NOT NULL,
    score_ct INT DEFAULT 0,
    score_t INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS player_stats (
    id SERIAL PRIMARY KEY,
    match_id INT REFERENCES matches(id) ON DELETE CASCADE,
    steam_id VARCHAR(64) NOT NULL,
    name VARCHAR(128) NOT NULL,
    kills INT DEFAULT 0,
    deaths INT DEFAULT 0,
    hltv_rating FLOAT DEFAULT 0.0,
    adr FLOAT DEFAULT 0.0
);