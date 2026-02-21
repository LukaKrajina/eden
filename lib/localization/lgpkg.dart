class Lgpkg {
  String currentLanguage = "English";

  static const Map<String, Map<String, String>> _localizedValues = {
    "English": {
      "RankMatch": "Rank Match",
      "TeamMatch": "Team Match",
      "RealMatch": "Real Match",
      "DeathMatch": "Death Match",
      "One-on-One": "1 vs 1",
      "Status": "Status",
      "Idle": "Idle",
      "StartMatching": "START MATCHING",
      "CancelMatching": "CANCEL MATCHING",
      "StopServer": "STOP SERVER",
      "Map": "Map",
      "ID": "ID?",
      "Score": "Score",
      "Lvl": "Lvl",
      "Ready": "Ready",
      "Waiting": "Waiting",
      "Welcome": "Welcome",
      "PasteID": "Paste Host Peer ID",
      "Connect": "CONNECT",
      "Cancel": "CANCEL",
      "AddConnect": "ADD & CONNECT",
      "DirectConnect": "Direct Connect",
    },
    "Chinese": {
      "RankMatch": "排位赛",
      "TeamMatch": "团队赛",
      "RealMatch": "电竞模式",
      "DeathMatch": "死斗模式",
      "One-on-One": "单挑模式",
      "Status": "状态",
      "Idle": "空闲",
      "StartMatching": "开始匹配",
      "CancelMatching": "取消匹配",
      "StopServer": "停止服务器",
      "Map": "地图",
      "ID": "身份证?",
      "Score": "分数",
      "Lvl": "等级",
      "Ready": "已准备",
      "Waiting": "等待中",
      "Welcome": "欢迎",
      "PasteID": "粘贴ID",
      "Connect": "连接",
      "Cancel": "取消",
      "AddConnect": "添加并连接",
      "DirectConnect": "直接连接",
    }
  };

  String get(String key) {
    if (_localizedValues.containsKey(currentLanguage)) {
      return _localizedValues[currentLanguage]![key] ?? key;
    }
    
    return _localizedValues["English"]?[key] ?? key;
  }
}