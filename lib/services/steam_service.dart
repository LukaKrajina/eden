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
import 'dart:async';
import 'dart:ffi';
import 'dart:math';
import 'package:ffi/ffi.dart';
import 'package:steamworks/steamworks.dart';

String generateRandomSuffix() {
  final random = Random();
  int length = random.nextInt(6) + 1; 
  
  return List.generate(length, (_) => random.nextInt(10)).join();
}

class SteamService {
  static final SteamService _instance = SteamService._internal();
  bool _isInitialized = false;
  CSteamId? _myCSteamID;
  String _playerName = "user${generateRandomSuffix()}";
  Pointer<UnsignedChar>? _playerAvatarBytes;

  factory SteamService() {
    return _instance;
  }
  
  SteamService._internal();
  
  Future<void> init() async {
    try {
      SteamClient.init(appId: 730);
      _isInitialized = true;
      print("Steam API Initialized Successfully");

      await _fetchSteamPlayerData();

    } catch (e) {
      _isInitialized = false;
      print("Steam Init failed: $e. ");
    }
  }

  Future<void> _fetchSteamPlayerData() async {
    if (!_isInitialized) return;

    try {
      _myCSteamID = SteamClient.instance.steamUser.getSteamId();

      
      Pointer<Utf8> namePtr = SteamClient.instance.steamFriends.getPersonaName();
      _playerName = namePtr.toDartString();

      int imageHandle = SteamClient.instance.steamFriends.getLargeFriendAvatar(_myCSteamID!);
      
      if (imageHandle > 0) {
        _playerAvatarBytes = await _getImageBytes(imageHandle);
      }
    } catch (e) {
      print("Error fetching player data: $e");
    }
  }

  Future<Pointer<UnsignedChar>?> _getImageBytes(int imageHandle) async {
  final Pointer<UnsignedInt> pnWidth = calloc<UnsignedInt>();
  final Pointer<UnsignedInt> pnHeight = calloc<UnsignedInt>();

  try {
    final bool gotSize = SteamClient.instance.steamUtils.getImageSize(
      imageHandle,
      pnWidth,
      pnHeight,
    );

    if (!gotSize) return null;

    final int width = pnWidth.value;
    final int height = pnHeight.value;
    final int bufferSize = width * height * 4;

    final Pointer<UnsignedChar> pRGBA = calloc<UnsignedChar>(bufferSize);

    final bool success = SteamClient.instance.steamUtils.getImageRGBA(
      imageHandle,
      pRGBA,
      bufferSize,
    );

    if (success) {
      return pRGBA;
    }
  } catch (e) {
    print("Failed to convert avatar bytes: $e");
  } finally {
    calloc.free(pnWidth);
    calloc.free(pnHeight);
  }
  return null;
}

  String getPlayerName() {
    return _playerName;
  }

  int getSteamID() {
    return _myCSteamID ?? 0;
  }

  Pointer<UnsignedChar>? getAvatarBytes() {
    return _playerAvatarBytes;
  }

  void shutdown() {
    if (_isInitialized) {
      SteamShutdown();
      _isInitialized = false;
    }
  }
}