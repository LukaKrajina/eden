class Lgpkg {
  String currentLanguage = "English";

  static const Map<String, Map<String, String>> _localizedValues = {

    // English Localization
    "English": {
      // --- Top Navigation & Titles ---
      "AppTitle": "EDEN Client",
      "PlayTitle": "PLAY",
      "SocialTitle": "Social",
      "ProConfigTitle": "PRO Config",
      "Play": "PLAY",
      
      // --- Game Modes ---
      "Matchmaking": "MATCHMAKING",
      "Tournaments": "TOURNAMENTS",
      "Deathmatch": "DEATHMATCH",
      "1v1Hubs": "1V1 HUBS",
      
      // --- Status & Engine ---
      "Status": "Status",
      "Idle": "Idle",
      "WaitingAction": "WAITING FOR ACTION",
      "InitializingAC": "INITIALIZING AC...",
      "ACActive": "ANTI-CHEAT ACTIVE",
      "EdenACActive": "EDEN AC ACTIVE",
      "TunnelSecured": "SECURED",
      "TunnelWaiting": "WAITING",
      "SessionConnected": "CONNECTED",
      "SessionIdle": "IDLE",
      "AntiCheat": "ANTI-CHEAT",
      
      // --- Match Flow ---
      "StartMatching": "START MATCHING",
      "CancelMatching": "CANCEL MATCHING",
      "Searching": "SEARCHING",
      "SearchingMsg": "SEARCHING FOR MATCH...",
      "MatchFound": "MATCH FOUND!",
      "MatchCancelled": "MATCH CANCELLED",
      "StopServer": "STOP SERVER",
      "StartingServer": "STARTING SERVER",
      "ServerOnline": "SERVER ONLINE (WAITING)",
      "CreateCustomLobby": "CREATE CUSTOM LOBBY",
      "CancelSearch": "CANCEL SEARCH",
      
      // --- In-Game/Scoreboard ---
      "Score": "Score",
      "Warmup": "WARMUP",
      "HalfTime": "HALF TIME",
      "Final": "FINAL",
      "MatchEndedMining": "Match Ended. Mining Block...",
      "Lobby": "LOBBY",
      "TeamRoster": "TEAM ROSTER",
      "VS": "VS",
      "EmptySlot": "Empty Slot",
      
      // --- Errors & Dialogs ---
      "ConfigError": "CONFIG ERROR",
      "ConfigWriteError": "Could not write GSI config.",
      "ACRequired": "ANTI-CHEAT REQUIRED",
      "ShieldRequiredMsg": "Active Shield required to host games.",
      "EnableShieldMsg": "You must enable the Eden Anti-Cheat shield.",
      "InsufficientFunds": "INSUFFICIENT FUNDS",
      "TransactionFailed": "TRANSACTION FAILED",
      "ProcessDeductionFailed": "Could not process deduction.",
      "Error": "Error",
      "OK": "OK",
      
      // --- Friends & Social ---
      "FriendsList": "FRIENDS LIST",
      "AddFriend": "ADD FRIEND",
      "EnterFriendCode": "Enter Friend Code / Peer ID",
      "NoFriendsMsg": "No friends yet. Add one using their Peer ID.",
      "Invite": "INVITE",
      "InvitedMsg": "Invited to Lobby",
      "Trade": "TRADE",
      "FriendCode": "FRIEND CODE",
      "PeerID": "PEER ID",
      "Level": "LEVEL",
      "Skill": "Skill",
      
      // --- Profile ---
      "ChangeIdentity": "CHANGE IDENTITY",
      "ChangeIdentityCost": "Changing your platform alias costs 10 EDN.",
      "NewAlias": "New Alias",
      "Pay10EDN": "PAY 10 EDN",
      "Loading": "LOADING",
      "Close": "CLOSE",
      
      // --- Wallet ---
      "EdenWallet": "EDEN WALLET",
      "LiveBalance": "Live Balance",
      "Send": "SEND",
      "Receive": "RECEIVE",
      "SendEDN": "SEND EDN",
      "ReceiveEDN": "RECEIVE EDN",
      "ReceiverID": "Receiver Peer ID",
      "Amount": "Amount",
      "ShareIDMsg": "Share this Peer ID to receive funds:",
      "Copy": "COPY",
      "MiningRewardsMsg": "Mining rewards are deposited after every match.",
      "TransferFailed": "Transfer Failed.",
      "CopiedClipboard": "Copied to Clipboard",
      
      // --- Trade Overlay ---
      "SecureTradeOffer": "SECURE TRADE OFFER",
      "Holdings": "Holdings",
      "EstRemaining": "Est. Remaining:",
      "EstTotal": "Est. Total:",
      "TradingAmount": "TRADING AMOUNT",
      "CancelTrade": "CANCEL TRADE",
      "ConfirmAccept": "CONFIRM & ACCEPT",
      "TradeSuccessful": "Trade Successful!",
      "TradeFailed": "Trade Failed.",
      
      // --- Settings & Misc ---
      "Settings": "SETTINGS",
      "CS2Path": "CS2 Installation Path",
      "Save": "SAVE",
      "MapSelection": "MAP SELECTION",
      "PasteHubID": "Paste Hub ID / IP",
      "Map": "Map",
      "Connect": "CONNECT",
      "Cancel": "CANCEL",
    },
    
    // Chinese Localization
    "Chinese": {
      "AppTitle": "EDEN客户端",
      "PlayTitle": "开始游戏",
      "SocialTitle": "社交",
      "ProConfigTitle": "职业配置",
      "Play": "开始",
      
      "Matchmaking": "排位赛",
      "Tournaments": "锦标赛",
      "Deathmatch": "死斗模式",
      "1v1Hubs": "单挑模式",
      
      "Status": "状态",
      "Idle": "空闲",
      "WaitingAction": "等待操作",
      "InitializingAC": "正在初始化反作弊...",
      "ACActive": "反作弊已激活",
      "EdenACActive": "EDEN反作弊运行中",
      "TunnelSecured": "安全",
      "TunnelWaiting": "等待中",
      "SessionConnected": "已连接",
      "SessionIdle": "空闲",
      "AntiCheat": "反作弊",
      
      "StartMatching": "开始匹配",
      "CancelMatching": "取消匹配",
      "Searching": "搜索中",
      "SearchingMsg": "正在寻找比赛...",
      "MatchFound": "找到比赛!",
      "MatchCancelled": "比赛取消",
      "StopServer": "停止服务器",
      "StartingServer": "正在启动服务器",
      "ServerOnline": "服务器在线 (等待中)",
      "CreateCustomLobby": "创建自定义房间",
      "CancelSearch": "取消搜索",
      
      "Score": "分数",
      "Warmup": "热身",
      "HalfTime": "半场",
      "Final": "最终",
      "MatchEndedMining": "比赛结束. 正在挖掘区块...",
      "Lobby": "大厅",
      "TeamRoster": "队伍名单",
      "VS": "VS",
      "EmptySlot": "空位",
      
      "ConfigError": "配置错误",
      "ConfigWriteError": "无法写入GSI配置.",
      "ACRequired": "需要反作弊",
      "ShieldRequiredMsg": "主机游戏需要激活护盾.",
      "EnableShieldMsg": "您必须启用Eden反作弊护盾.",
      "InsufficientFunds": "资金不足",
      "TransactionFailed": "交易失败",
      "ProcessDeductionFailed": "无法处理扣款.",
      "Error": "错误",
      "OK": "确定",
      
      "FriendsList": "好友列表",
      "AddFriend": "添加好友",
      "EnterFriendCode": "输入好友代码 / Peer ID",
      "NoFriendsMsg": "暂无好友. 使用ID添加.",
      "Invite": "邀请",
      "InvitedMsg": "已邀请至大厅",
      "Trade": "交易",
      "FriendCode": "好友代码",
      "PeerID": "PEER ID",
      "Level": "等级",
      "Skill": "技术分",
      
      "ChangeIdentity": "更改身份",
      "ChangeIdentityCost": "更改平台别名需花费 10 EDN.",
      "NewAlias": "新别名",
      "Pay10EDN": "支付 10 EDN",
      "Loading": "加载中",
      "Close": "关闭",
      
      "EdenWallet": "EDEN 钱包",
      "LiveBalance": "实时余额",
      "Send": "发送",
      "Receive": "接收",
      "SendEDN": "发送 EDN",
      "ReceiveEDN": "接收 EDN",
      "ReceiverID": "接收者 Peer ID",
      "Amount": "数量",
      "ShareIDMsg": "分享此ID以接收资金:",
      "Copy": "复制",
      "MiningRewardsMsg": "比赛结束后发放挖矿奖励.",
      "TransferFailed": "转账失败.",
      "CopiedClipboard": "已复制到剪贴板",
      
      "SecureTradeOffer": "安全交易提议",
      "Holdings": "持有量",
      "EstRemaining": "预计剩余:",
      "EstTotal": "预计总计:",
      "TradingAmount": "交易数量",
      "CancelTrade": "取消交易",
      "ConfirmAccept": "确认并接受",
      "TradeSuccessful": "交易成功!",
      "TradeFailed": "交易失败.",
      
      "Settings": "设置",
      "CS2Path": "CS2 安装路径",
      "Save": "保存",
      "MapSelection": "地图选择",
      "PasteHubID": "粘贴 Hub ID / IP",
      "Map": "地图",
      "Connect": "连接",
      "Cancel": "取消",
    }
  };

  String get(String key) {
    if (_localizedValues.containsKey(currentLanguage)) {
      return _localizedValues[currentLanguage]![key] ?? key;
    }
    
    return _localizedValues["English"]?[key] ?? key;
  }
}