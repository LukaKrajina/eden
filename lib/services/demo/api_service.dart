import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

class ApiServer {
  late Connection _connection;
  bool _isRunning = false;

  Future<void> start() async {
    if (_isRunning) return;

    _connection = await Connection.open(
      Endpoint(host: 'localhost', database: 'eden_db', username: 'postgres', password: 'password'),
      settings: ConnectionSettings(sslMode: SslMode.disable),
    );

    final handler = const Pipeline()
        .addMiddleware(corsHeaders())
        .addHandler(_handleRequest);

    final server = await shelf_io.serve(handler, 'localhost', 3000);
    print('[API] Serving at http://localhost:3000');
    _isRunning = true;
  }

  Future<Response> _handleRequest(Request request) async {
    if (request.url.path == 'recent-matches') {
      final results = await _connection.execute(
        "SELECT id, map_name, score_ct, score_t, played_at FROM matches ORDER BY played_at DESC LIMIT 10"
      );
      
      final matches = results.map((row) => {
        'id': row[0],
        'map': row[1],
        'score_ct': row[2],
        'score_t': row[3],
        'date': row[4].toString()
      }).toList();

      return Response.ok(jsonEncode(matches), headers: {'content-type': 'application/json'});
    }

    if (request.url.path.startsWith('match/')) {
      final id = int.tryParse(request.url.pathSegments.last);
      if (id != null) {
        final players = await _connection.execute(
          Sql.named("SELECT name, kills, deaths, hltv_rating, adr FROM player_stats WHERE match_id = @id ORDER BY hltv_rating DESC"),
          parameters: {'id': id}
        );

        final stats = players.map((row) => {
          'name': row[0],
          'kills': row[1],
          'deaths': row[2],
          'rating': row[3],
          'adr': row[4]
        }).toList();

        return Response.ok(jsonEncode(stats), headers: {'content-type': 'application/json'});
      }
    }

    return Response.notFound('Endpoint not found');
  }
}