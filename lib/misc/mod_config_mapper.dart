/*
    Eden
    Copyright (C) 2026 LukaKrajina

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/
enum GameMode { matchmaking, tournaments, deathmatch, one_one }

class ModeConfig {
  final String gameType;
  final String gameMode;
  final String maxPlayers;
  final String friendlyFire;

  ModeConfig(this.gameType, this.gameMode, this.maxPlayers, this.friendlyFire);
}

final Map<GameMode, ModeConfig> modeConfigurations = {
  GameMode.matchmaking: ModeConfig("0", "1", "10", "0"), 
  GameMode.tournaments: ModeConfig("0", "1", "12", "1"),           
  GameMode.deathmatch: ModeConfig("1", "2", "16", "0"),
  GameMode.one_one: ModeConfig("0", "0", "2", "0"), 
};