import "dart:convert";
import "dart:ffi";
import "dart:io";
import "package:ffi/ffi.dart";

typedef AnalyzeDemoC = Pointer<Utf8> Function(Pointer<Utf8> path, Pointer<Utf8> dbUrl);
typedef AnalyzeDemoDart = Pointer<Utf8> Function(Pointer<Utf8> path, Pointer<Utf8> dbUrl);

typedef FreeStringC = Void Function(Pointer<Utf8> str);
typedef FreeStringDart = void Function(Pointer<Utf8> str);

class DemoService {
  late DynamicLibrary _lib;
  late AnalyzeDemoDart _analyzeDemo;
  late FreeStringDart _freeString;

  final String dbUrl = "";

  DemoService(){
    if(Platform.isWindows){
      _lib = DynamicLibrary.open('demo_core.dll');
    } else {
      _lib = DynamicLibrary.open('libdemo_core.so');
    }

    _analyzeDemo = _lib.lookupFunction<AnalyzeDemoC, AnalyzeDemoDart>('analyze_demo');
    _freeString = _lib.lookupFunction<FreeStringC, FreeStringDart>('free_string');
  }

  Future<Map<String, dynamic>> analyze(String filePath) async {
    return Future.sync(() {
      final pathPtr = filePath.toNativeUtf8();
      final dbPtr = dbUrl.toNativeUtf8();
      
      try {
        final resultPtr = _analyzeDemo(pathPtr, dbPtr);
        final jsonString = resultPtr.toDartString();
        _freeString(resultPtr);
        return {"raw": jsonDecode(jsonString)}; 
      } catch (e) {
        return {"success": false, "error": "$e"};
      } finally {
        calloc.free(pathPtr);
        calloc.free(dbPtr);
      }
    });
  }
}