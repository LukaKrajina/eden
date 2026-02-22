import 'dart:convert';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors/shelf_cors.dart';

class ApiServer {
  final String dbHost = 'localhost';
  final String dbName = 'eden_db';
  final String dbUser = 'postgres';
  final String dbPass = 'password';

  Future<void> start() async {
    final handler = const Pipeline()
      .addMiddleware(corsHeaders())
      .addHandler(_handleRequest);

    await shelf_io.serve(handler, 'localhost', 3000);
    print('API Server running on localhost:3000');
  }

  Future<Response> _handleRequest(Request request) async {
    final conn = await Connection.open(
      Endpoint(host: dbHost, database: dbName, username: dbUser, password: dbPass),
      settings: ConnectionSettings(sslMode: SslMode.disable),
    );

    try {
      // Endpoint: /matches
      if (request.url.path == 'matches') {
        final res = await conn.execute("SELECT id, map_name, score_ct, score_t, file_name FROM matches ORDER BY id DESC LIMIT 10");
        final data = res.map((r) => {
          'id': r[0], 'map': r[1], 'ct': r[2], 't': r[3], 'date': "Today" 
        }).toList();
        return Response.ok(jsonEncode(data), headers: {'content-type': 'application/json'});
      }
      
      // Endpoint: /match/<id>
      if (request.url.pathSegments.length == 2 && request.url.pathSegments[0] == 'match') {
        final id = int.tryParse(request.url.pathSegments[1]);
        if (id != null) {
          final res = await conn.execute(
            Sql.named("SELECT name, kills, deaths, adr, hltv_rating FROM player_stats WHERE match_id = @id ORDER BY hltv_rating DESC"),
            parameters: {'id': id}
          );
          final data = res.map((r) => {
            'name': r[0], 'kills': r[1], 'deaths': r[2], 'adr': r[3], 'rating': r[4]
          }).toList();
          return Response.ok(jsonEncode(data), headers: {'content-type': 'application/json'});
        }
      }
      
      return Response.notFound('Not Found');
    } catch (e) {
      return Response.internalServerError(body: "DB Error: $e");
    } finally {
      await conn.close();
    }
  }
}