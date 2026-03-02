import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef AnalyzeDemoC = Pointer<Utf8> Function(Pointer<Utf8> path, Pointer<Utf8> dbUrl);
typedef AnalyzeDemoDart = Pointer<Utf8> Function(Pointer<Utf8> path, Pointer<Utf8> dbUrl);

typedef FreeStringC = Void Function(Pointer<Utf8> str);
typedef FreeStringDart = void Function(Pointer<Utf8> str);

class DemoResult {
  final bool success;
  final int? matchId;
  final String? error;

  DemoResult({required this.success, this.matchId, this.error});
}

class DemoRequest {
  final String filePath;
  final String dbUser;
  final String dbPassword;

  DemoRequest(this.filePath, this.dbUser, this.dbPassword);
}

Future<DemoResult> _analyzeInIsolate(DemoRequest request) async {
  DynamicLibrary _lib;
  try {
    if (Platform.isWindows) {
      _lib = DynamicLibrary.open('demo_core.dll'); 
    } else if (Platform.isLinux) {
      _lib = DynamicLibrary.open('libdemo_core.so');
    } else {
      return DemoResult(success: false, error: "Unsupported Platform");
    }
  } catch (e) {
    return DemoResult(success: false, error: "Failed to load DLL: $e");
  }

  try {
    final analyzeDemo = _lib.lookupFunction<AnalyzeDemoC, AnalyzeDemoDart>('analyze_demo');
    final freeString = _lib.lookupFunction<FreeStringC, FreeStringDart>('free_string');

    final pathPtr = request.filePath.toNativeUtf8();
    final encodedPassword = Uri.encodeComponent(request.dbPassword);
    final dbUrl = "postgresql://${request.dbUser}:$encodedPassword@localhost:5432/eden_db";
    final dbPtr = dbUrl.toNativeUtf8();
    
    Pointer<Utf8>? resultPtr;

    try {
      resultPtr = analyzeDemo(pathPtr, dbPtr);
      
      final resultJsonString = resultPtr.toDartString();
      final Map<String, dynamic> result = jsonDecode(resultJsonString);

      if (result['success'] == true) {
        return DemoResult(
          success: true, 
          matchId: result['match_id'] as int?
        );
      } else {
        return DemoResult(
          success: false, 
          error: result['error'] ?? "Unknown error from native library"
        );
      }
    } finally {
      calloc.free(pathPtr);
      calloc.free(dbPtr);
      if (resultPtr != null) freeString(resultPtr);
    }
  } catch (e) {
    return DemoResult(success: false, error: "Native Execution Error: $e");
  }
}

class DemoService {
  String _dbUser = "postgres";
  String _dbPassword = "password";

  void setDatabaseUser(String user) => _dbUser = user;
  void setDatabasePassword(String password) => _dbPassword = password;

  Future<DemoResult> processDemo(String filePath) async {
    return await compute(_analyzeInIsolate, DemoRequest(filePath, _dbUser, _dbPassword));
  }
}