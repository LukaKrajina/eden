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
import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

class ApiServer {
  late Connection _connection;
  bool _isRunning = false;

  Future<void> start(String dbUser, String dbPassword) async {
    if (_isRunning) return;

    try {
      _connection = await Connection.open(
        Endpoint(host: 'localhost', database: 'eden_db', username: dbUser, password: dbPassword),
        settings: ConnectionSettings(sslMode: SslMode.disable),
      );

      final handler = const Pipeline()
          .addMiddleware(corsHeaders())
          .addHandler(_handleRequest);

      final server = await shelf_io.serve(handler, '0.0.0.0', 3001);
      print('[API] Serving at http://0.0.0.0:3001');
      _isRunning = true;
    } catch (e) {
        print("[API] Failed to start server or connect to DB: $e");
        _isRunning = false;
        throw e; 
    }
  }

  Future<Response> _handleRequest(Request request) async {
    if (request.url.path == 'recent-matches') {
      try {
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
      } catch (e) {
        return Response.internalServerError(body: "Database Error: $e");
      }
    }

    if (request.url.path.startsWith('match/')) {
      final id = int.tryParse(request.url.pathSegments.last);
      if (id != null) {
        try {
          final players = await _connection.execute(
            Sql.named("SELECT name, kills, deaths, hltv_rating, adr FROM player_stats WHERE match_id = @id ORDER BY hltv_rating DESC"),
            parameters: {'id': id}
          );

          final stats = players.map((row) => {
            'name': row[0].toString(),
            'kills': int.tryParse(row[1].toString()) ?? 0,
            'deaths': int.tryParse(row[2].toString()) ?? 0,
            'rating': double.tryParse(row[3].toString()) ?? 0.0,
            'adr': double.tryParse(row[4].toString()) ?? 0.0
          }).toList();

          return Response.ok(jsonEncode(stats), headers: {'content-type': 'application/json'});
        } catch (e) {
          return Response.internalServerError(body: "Database Error: $e");
        }
      }
    }

    return Response.notFound('Endpoint not found');
  }
}