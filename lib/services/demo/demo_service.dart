import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef AnalyzeDemoC = Pointer<Utf8> Function(Pointer<Utf8> path, Pointer<Utf8> dbUrl);
typedef AnalyzeDemoDart = Pointer<Utf8> Function(Pointer<Utf8> path, Pointer<Utf8> dbUrl);

class DemoResult {
  final bool success;
  final String? json;
  final String? error;

  DemoResult({required this.success, this.json, this.error});
}

class DemoService {
  late DynamicLibrary _lib;
  late AnalyzeDemoDart _analyzeDemo;
  bool _isLoaded = false;

  final String dbUrl = "postgresql://postgres:114357@hJ@localhost:5432/eden_db";

  DemoService() {
    try {
      if (Platform.isWindows) {
        _lib = DynamicLibrary.open('demo_core.dll');
      } else if (Platform.isLinux) {
        _lib = DynamicLibrary.open('libdemo_core.so');
      }
      
      _analyzeDemo = _lib.lookupFunction<AnalyzeDemoC, AnalyzeDemoDart>('analyze_demo');
      _isLoaded = true;
    } catch (e) {
      print("[DemoService] Failed to load library: $e");
    }
  }

  Future<DemoResult> processDemo(String filePath) async {
    if (!_isLoaded) return DemoResult(success: false, error: "Library not loaded");

    return Future<DemoResult>.sync(() {
      final pathPtr = filePath.toNativeUtf8();
      final dbPtr = dbUrl.toNativeUtf8();

      try {
        final resultPtr = _analyzeDemo(pathPtr, dbPtr);
        final resultJson = resultPtr.toDartString();
        
        // Note: In production, you should expose a Rust 'free_string' function 
        // to free resultPtr to avoid memory leaks.
        
        if (resultJson.contains('"error"')) {
          return DemoResult(success: false, error: resultJson);
        }
        return DemoResult(success: true, json: resultJson);
      } catch (e) {
        return DemoResult(success: false, error: e.toString());
      } finally {
        calloc.free(pathPtr);
        calloc.free(dbPtr);
      }
    });
  }
}