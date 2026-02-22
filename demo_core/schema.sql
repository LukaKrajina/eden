-- init_db.sql
CREATE TABLE IF NOT EXISTS matches (
    id SERIAL PRIMARY KEY,
    file_name VARCHAR(255) UNIQUE NOT NULL,
    map_name VARCHAR(64) NOT NULL,
    date_played TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    duration_sec INT,
    score_ct INT,
    score_t INT,
    winner VARCHAR(10) -- 'CT' or 'T'
);

CREATE TABLE IF NOT EXISTS player_stats (
    id SERIAL PRIMARY KEY,
    match_id INT REFERENCES matches(id) ON DELETE CASCADE,
    steam_id VARCHAR(64) NOT NULL,
    name VARCHAR(128) NOT NULL,
    kills INT DEFAULT 0,
    deaths INT DEFAULT 0,
    assists INT DEFAULT 0,
    mvps INT DEFAULT 0,
    headshot_percentage FLOAT DEFAULT 0.0,
    adr FLOAT DEFAULT 0.0, -- Average Damage per Round
    hltv_rating FLOAT DEFAULT 0.0,
    team VARCHAR(10) -- 'CT' or 'T'
);