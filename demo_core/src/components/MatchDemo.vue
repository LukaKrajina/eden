<template>
  <div class="faceit-container">
    <div class="match-sidebar">
      <div class="sidebar-header">MATCH HISTORY</div>
      <div 
        v-for="match in matches" 
        :key="match.id"
        class="match-card"
        :class="{ active: selectedMatchId === match.id }"
        @click="selectMatch(match.id)"
      >
        <div class="map-badge" :class="match.map"></div>
        <div class="match-info">
          <div class="match-map">{{ match.map }}</div>
          <div class="match-score">
            <span class="ct">{{ match.score_ct }}</span> - <span class="t">{{ match.score_t }}</span>
          </div>
        </div>
        <div class="match-date">{{ formatDate(match.date) }}</div>
      </div>
    </div>

    <div class="stats-panel" v-if="matchStats.length > 0">
      <div class="panel-header">
        <h1>SCOREBOARD</h1>
        <div class="actions">
          <button class="btn-orange">DOWNLOAD DEMO</button>
          <button class="btn-outline">WATCH ROOM</button>
        </div>
      </div>

      <table class="data-table">
        <thead>
          <tr>
            <th>PLAYER</th>
            <th>KILLS</th>
            <th>DEATHS</th>
            <th>K/D RATIO</th>
            <th>ADR</th>
            <th>RATING 2.0</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="player in matchStats" :key="player.name">
            <td class="player-cell">
              <div class="avatar-placeholder">{{ player.name.charAt(0) }}</div>
              {{ player.name }}
            </td>
            <td>{{ player.kills }}</td>
            <td>{{ player.deaths }}</td>
            <td :class="getKdColor(player.kills, player.deaths)">
              {{ (player.kills / Math.max(1, player.deaths)).toFixed(2) }}
            </td>
            <td>{{ player.adr.toFixed(1) }}</td>
            <td>
              <span class="rating-badge" :class="getRatingClass(player.rating)">
                {{ player.rating.toFixed(2) }}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    
    <div v-else class="empty-state">
      Select a match to view details
    </div>
  </div>
</template>

<script lang="ts" setup>
import { ref, onMounted } from 'vue';

interface Match {
  id: number;
  map: string;
  score_ct: number;
  score_t: number;
  date: string;
}

interface PlayerStat {
  name: string;
  kills: number;
  deaths: number;
  rating: number;
  adr: number;
}

const matches = ref<Match[]>([]);
const matchStats = ref<PlayerStat[]>([]);
const selectedMatchId = ref<number | null>(null);

// Fetch Match List
onMounted(async () => {
  try {
    const res = await fetch('http://localhost:3000/recent-matches');
    matches.value = await res.json();
  } catch (e) {
    console.error("API Error", e);
  }
});

// Fetch Details
const selectMatch = async (id: number) => {
  selectedMatchId.value = id;
  const res = await fetch(`http://localhost:3000/match/${id}`);
  matchStats.value = await res.json();
};

// Utils
const formatDate = (d: string) => new Date(d).toLocaleDateString();
const getKdColor = (k: number, d: number) => (k/d >= 1 ? 'text-green' : 'text-red');

const getRatingClass = (r: number) => {
  const val = Number(r) || 0;
  if (val >= 1.2) return 'rating-god';
  if (val >= 1.0) return 'rating-good';
  return 'rating-bad';
};
</script>

<style scoped>
/* Faceit/Eden Theme Variables */
:root {
  --bg-dark: #121212;
  --bg-panel: #1F1F1F;
  --primary: #FF5500;
  --text: #EEEEEE;
  --border: #333;
}

.faceit-container {
  display: flex;
  height: 100vh;
  background-color: #121212;
  color: #EEE;
  font-family: 'Inter', sans-serif;
}

/* Sidebar */
.match-sidebar {
  width: 300px;
  background: #181818;
  border-right: 1px solid #333;
  overflow-y: auto;
}

.sidebar-header {
  padding: 20px;
  font-weight: bold;
  font-family: 'Oswald', sans-serif;
  color: #666;
  letter-spacing: 1px;
}

.match-card {
  display: flex;
  align-items: center;
  padding: 15px 20px;
  border-bottom: 1px solid #222;
  cursor: pointer;
  transition: background 0.2s;
}

.match-card:hover { background: #252525; }
.match-card.active { background: #2A2A2A; border-left: 4px solid #FF5500; }

.match-info { flex: 1; margin-left: 12px; }
.match-map { font-weight: bold; font-size: 14px; color: #FFF; text-transform: uppercase; }
.match-score { font-family: 'Oswald'; font-size: 16px; margin-top: 2px; }
.ct { color: #5D79AE; } .t { color: #DE9B35; }

/* Stats Panel */
.stats-panel { flex: 1; padding: 40px; overflow-y: auto; }

.panel-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 30px;
}

h1 { font-family: 'Oswald'; font-size: 32px; margin: 0; }

.btn-orange {
  background: #FF5500; color: white; border: none;
  padding: 10px 20px; font-weight: bold; cursor: pointer;
  border-radius: 2px;
}

.data-table {
  width: 100%;
  border-collapse: collapse;
}

.data-table th {
  text-align: left;
  color: #666;
  font-size: 12px;
  padding: 10px 0;
  border-bottom: 1px solid #333;
}

.data-table td {
  padding: 15px 0;
  border-bottom: 1px solid #222;
  font-weight: 500;
}

.rating-badge {
  padding: 4px 8px;
  border-radius: 4px;
  font-size: 12px;
  font-weight: bold;
  color: #000;
}
.rating-god { background: #2ecc71; }
.rating-good { background: #f1c40f; }
.rating-bad { background: #e74c3c; color: white; }

.text-green { color: #2ecc71; }
.text-red { color: #e74c3c; }

.avatar-placeholder {
  width: 30px; height: 30px;
  background: #333;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  margin-right: 10px;
  font-size: 12px;
  color: #777;
}
</style>