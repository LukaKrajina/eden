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