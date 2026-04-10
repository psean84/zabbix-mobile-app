import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Central SQLite database helper for the Zabbix mobile app.
///
/// Provides a local cache database whose schema mirrors the data entities
/// fetched from the Zabbix API.  Every table includes indexes on the columns
/// that the app queries via WHERE, JOIN, or ORDER BY so that lookups stay
/// fast even as the cached dataset grows.
class DbHelper {
  DbHelper._();
  static final DbHelper instance = DbHelper._();

  static const String _dbName = 'zbx_cache.db';
  static const int _dbVersion = 1;

  Database? _db;
  Completer<Database>? _initCompleter;

  /// Returns the singleton database instance, creating it on first access.
  /// Uses a [Completer] to ensure only one initialization runs even if
  /// multiple callers await [database] concurrently.
  Future<Database> get database async {
    if (_db != null) return _db!;
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<Database>();
    try {
      final db = await _initDb();
      _db = db;
      _initCompleter!.complete(db);
      return db;
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Schema creation
  // ---------------------------------------------------------------------------

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    // ── host_groups ──────────────────────────────────────────────────────────
    //
    // Stores Zabbix host-group metadata.
    //
    // Queries that hit this table:
    //   • WHERE groupid = ?           (load hosts for a group)
    //   • WHERE name = ?              (dashboard group-name lookup)
    //   • ORDER BY name               (group list display)
    batch.execute('''
      CREATE TABLE host_groups (
        groupid  TEXT PRIMARY KEY,
        name     TEXT NOT NULL
      )
    ''');

    // Index: sort & filter by group name
    batch.execute('''
      CREATE INDEX idx_host_groups_name ON host_groups (name)
    ''');

    // ── hosts ────────────────────────────────────────────────────────────────
    //
    // Stores Zabbix host records.
    //
    // Queries that hit this table:
    //   • WHERE hostid = ?            (AppCache.hostById, problem→host lookup)
    //   • WHERE name LIKE ?           (search bar)
    //   • WHERE status = ?            (enabled/disabled filter)
    //   • ORDER BY name               (host list display)
    batch.execute('''
      CREATE TABLE hosts (
        hostid  TEXT PRIMARY KEY,
        host    TEXT NOT NULL DEFAULT '',
        name    TEXT NOT NULL DEFAULT '',
        status  TEXT NOT NULL DEFAULT '0'
      )
    ''');

    // Index: search / sort by display name
    batch.execute('''
      CREATE INDEX idx_hosts_name ON hosts (name)
    ''');

    // Index: filter by enabled / disabled status
    batch.execute('''
      CREATE INDEX idx_hosts_status ON hosts (status)
    ''');

    // ── host_group_members ───────────────────────────────────────────────────
    //
    // Many-to-many relationship between hosts and host_groups.
    //
    // Queries that hit this table:
    //   • JOIN hosts ON host_group_members.hostid = hosts.hostid
    //     WHERE host_group_members.groupid = ?        (hosts in a group)
    //   • JOIN host_groups ON host_group_members.groupid = host_groups.groupid
    //     WHERE host_group_members.hostid = ?          (groups of a host)
    batch.execute('''
      CREATE TABLE host_group_members (
        hostid   TEXT NOT NULL,
        groupid  TEXT NOT NULL,
        PRIMARY KEY (hostid, groupid),
        FOREIGN KEY (hostid)  REFERENCES hosts (hostid),
        FOREIGN KEY (groupid) REFERENCES host_groups (groupid)
      )
    ''');

    // Index: look up all groups for a given host (reverse direction of PK)
    batch.execute('''
      CREATE INDEX idx_hgm_groupid ON host_group_members (groupid)
    ''');

    // ── host_interfaces ──────────────────────────────────────────────────────
    //
    // Network interfaces attached to a host (agent, SNMP, JMX, IPMI).
    //
    // Queries that hit this table:
    //   • WHERE hostid = ?            (extractIp helper, interface dashboard)
    //   • WHERE ip = ?                (reverse IP lookup)
    batch.execute('''
      CREATE TABLE host_interfaces (
        interfaceid  TEXT PRIMARY KEY,
        hostid       TEXT NOT NULL,
        ip           TEXT NOT NULL DEFAULT '',
        dns          TEXT NOT NULL DEFAULT '',
        port         TEXT NOT NULL DEFAULT '',
        type         TEXT NOT NULL DEFAULT '1',
        main         TEXT NOT NULL DEFAULT '1',
        FOREIGN KEY (hostid) REFERENCES hosts (hostid)
      )
    ''');

    // Index: fetch interfaces for a host
    batch.execute('''
      CREATE INDEX idx_host_interfaces_hostid ON host_interfaces (hostid)
    ''');

    // Index: reverse lookup by IP address
    batch.execute('''
      CREATE INDEX idx_host_interfaces_ip ON host_interfaces (ip)
    ''');

    // ── problems ─────────────────────────────────────────────────────────────
    //
    // Active triggers / problems from Zabbix.
    //
    // Queries that hit this table:
    //   • WHERE priority >= ?         (severity filter on dashboard)
    //   • WHERE priority = ?          (count by severity)
    //   • ORDER BY priority DESC      (severity-sorted list)
    //   • ORDER BY lastchange DESC    (most-recent-first list)
    //   • WHERE description LIKE ?    (search)
    batch.execute('''
      CREATE TABLE problems (
        eventid      TEXT PRIMARY KEY,
        triggerid    TEXT NOT NULL DEFAULT '',
        description  TEXT NOT NULL DEFAULT '',
        priority     TEXT NOT NULL DEFAULT '0',
        lastchange   TEXT NOT NULL DEFAULT '0',
        value        TEXT NOT NULL DEFAULT '1'
      )
    ''');

    // Index: severity filter & sort  (WHERE priority >= ? ORDER BY priority)
    batch.execute('''
      CREATE INDEX idx_problems_priority ON problems (priority)
    ''');

    // Index: time-based sort  (ORDER BY lastchange DESC)
    batch.execute('''
      CREATE INDEX idx_problems_lastchange ON problems (lastchange)
    ''');

    // Index: combined severity + time for the most common query pattern
    //   ORDER BY priority DESC, lastchange DESC
    batch.execute('''
      CREATE INDEX idx_problems_priority_lastchange
        ON problems (priority, lastchange)
    ''');

    // Index: full-text-like search on the description column
    batch.execute('''
      CREATE INDEX idx_problems_description ON problems (description)
    ''');

    // Index: lookup by triggerid for deduplication / updates
    batch.execute('''
      CREATE INDEX idx_problems_triggerid ON problems (triggerid)
    ''');

    // ── problem_hosts ────────────────────────────────────────────────────────
    //
    // Links problems to the hosts they affect.
    //
    // Queries that hit this table:
    //   • JOIN hosts ON problem_hosts.hostid = hosts.hostid
    //     WHERE problem_hosts.eventid = ?    (hosts affected by a problem)
    //   • JOIN problems ON problem_hosts.eventid = problems.eventid
    //     WHERE problem_hosts.hostid = ?     (problems affecting a host)
    batch.execute('''
      CREATE TABLE problem_hosts (
        eventid  TEXT NOT NULL,
        hostid   TEXT NOT NULL,
        PRIMARY KEY (eventid, hostid),
        FOREIGN KEY (eventid) REFERENCES problems (eventid),
        FOREIGN KEY (hostid)  REFERENCES hosts (hostid)
      )
    ''');

    // Index: find all problems for a given host
    batch.execute('''
      CREATE INDEX idx_problem_hosts_hostid ON problem_hosts (hostid)
    ''');

    // ── problem_tags ─────────────────────────────────────────────────────────
    //
    // Tags attached to problems (e.g. VRF, Customer).
    //
    // Queries that hit this table:
    //   • WHERE eventid = ?                   (tags for a problem)
    //   • WHERE tag = ? AND value = ?         (VRF→Customer mapping)
    //   • WHERE tag IN ('vrf','customer')     (AppCache.vrfToCustomer build)
    batch.execute('''
      CREATE TABLE problem_tags (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        eventid  TEXT NOT NULL,
        tag      TEXT NOT NULL DEFAULT '',
        value    TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (eventid) REFERENCES problems (eventid)
      )
    ''');

    // Index: fetch tags for a specific problem
    batch.execute('''
      CREATE INDEX idx_problem_tags_eventid ON problem_tags (eventid)
    ''');

    // Index: look up by tag name (VRF / Customer filter)
    batch.execute('''
      CREATE INDEX idx_problem_tags_tag ON problem_tags (tag)
    ''');

    // Index: combined tag + value for exact match queries
    batch.execute('''
      CREATE INDEX idx_problem_tags_tag_value ON problem_tags (tag, value)
    ''');

    // ── items ────────────────────────────────────────────────────────────────
    //
    // Zabbix monitoring items (metrics) belonging to hosts.
    //
    // Queries that hit this table:
    //   • WHERE hostid = ?            (fetchItems for a host)
    //   • WHERE itemid = ?            (single item lookup)
    //   • WHERE key_ LIKE ?           (ICMP / SAP / traffic key filtering)
    //   • WHERE name LIKE ?           (search)
    //   • WHERE value_type = ?        (numeric items filter)
    //   • ORDER BY name               (item list display)
    batch.execute('''
      CREATE TABLE items (
        itemid      TEXT PRIMARY KEY,
        hostid      TEXT NOT NULL,
        name        TEXT NOT NULL DEFAULT '',
        key_        TEXT NOT NULL DEFAULT '',
        units       TEXT NOT NULL DEFAULT '',
        value_type  TEXT NOT NULL DEFAULT '0',
        lastvalue   TEXT NOT NULL DEFAULT '',
        lastclock   TEXT NOT NULL DEFAULT '0',
        FOREIGN KEY (hostid) REFERENCES hosts (hostid)
      )
    ''');

    // Index: fetch all items for a host (most common query)
    batch.execute('''
      CREATE INDEX idx_items_hostid ON items (hostid)
    ''');

    // Index: filter by item key pattern (ICMP, SAP, traffic detection)
    batch.execute('''
      CREATE INDEX idx_items_key ON items (key_)
    ''');

    // Index: search / sort by item name
    batch.execute('''
      CREATE INDEX idx_items_name ON items (name)
    ''');

    // Index: filter numeric vs text items (value_type IN ('0','3'))
    batch.execute('''
      CREATE INDEX idx_items_value_type ON items (value_type)
    ''');

    // Index: composite for the common pattern:
    //   WHERE hostid = ? AND value_type IN ('0','3')
    batch.execute('''
      CREATE INDEX idx_items_hostid_value_type ON items (hostid, value_type)
    ''');

    // ── item_tags ────────────────────────────────────────────────────────────
    //
    // Tags attached to items (used for metadata indexing and host filtering).
    //
    // Queries that hit this table:
    //   • WHERE itemid = ?            (tags for an item)
    //   • WHERE tag = ?               (filter by tag name)
    //   • WHERE tag = ? AND value = ? (exact tag match)
    batch.execute('''
      CREATE TABLE item_tags (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        itemid  TEXT NOT NULL,
        tag     TEXT NOT NULL DEFAULT '',
        value   TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (itemid) REFERENCES items (itemid)
      )
    ''');

    // Index: fetch tags for a specific item
    batch.execute('''
      CREATE INDEX idx_item_tags_itemid ON item_tags (itemid)
    ''');

    // Index: look up items by tag name
    batch.execute('''
      CREATE INDEX idx_item_tags_tag ON item_tags (tag)
    ''');

    // Index: combined tag + value for exact match
    batch.execute('''
      CREATE INDEX idx_item_tags_tag_value ON item_tags (tag, value)
    ''');

    // ── history ──────────────────────────────────────────────────────────────
    //
    // Time-series data points for numeric items.
    //
    // Queries that hit this table:
    //   • WHERE itemid IN (?) AND clock BETWEEN ? AND ?
    //                                 (fetchHistory time-range query)
    //   • ORDER BY clock ASC          (chronological graph data)
    //   • WHERE itemid = ?            (single item history)
    batch.execute('''
      CREATE TABLE history (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        itemid  TEXT NOT NULL,
        clock   INTEGER NOT NULL,
        value   TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (itemid) REFERENCES items (itemid)
      )
    ''');

    // Index: the primary query pattern — time-range fetch for specific items
    //   WHERE itemid = ? AND clock BETWEEN ? AND ?  ORDER BY clock
    batch.execute('''
      CREATE INDEX idx_history_itemid_clock ON history (itemid, clock)
    ''');

    // ── devices ──────────────────────────────────────────────────────────────
    //
    // Registered FCM device tokens for push notifications.
    //
    // Queries that hit this table:
    //   • WHERE token = ?             (dedup on register)
    //   • WHERE platform = ?          (platform-specific push)
    batch.execute('''
      CREATE TABLE devices (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        token     TEXT NOT NULL UNIQUE,
        platform  TEXT NOT NULL DEFAULT 'android',
        filter    TEXT NOT NULL DEFAULT '{}'
      )
    ''');

    // Index: look up device by platform
    batch.execute('''
      CREATE INDEX idx_devices_platform ON devices (platform)
    ''');

    await batch.commit(noResult: true);
  }

  // ---------------------------------------------------------------------------
  // Schema migration
  // ---------------------------------------------------------------------------

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Future migrations go here.  Example:
    // if (oldVersion < 2) { db.execute('ALTER TABLE ...'); }
  }

  // ---------------------------------------------------------------------------
  // Convenience helpers
  // ---------------------------------------------------------------------------

  /// Closes the database.  Useful for testing or on logout.
  Future<void> close() async {
    final db = _db;
    if (db != null && db.isOpen) {
      await db.close();
      _db = null;
      _initCompleter = null;
    }
  }

  /// Deletes all cached data while keeping the schema intact.
  Future<void> clearAll() async {
    final db = await database;
    final batch = db.batch();
    for (final table in [
      'history',
      'item_tags',
      'items',
      'problem_tags',
      'problem_hosts',
      'problems',
      'host_interfaces',
      'host_group_members',
      'hosts',
      'host_groups',
      'devices',
    ]) {
      batch.delete(table);
    }
    await batch.commit(noResult: true);
  }

  // ---------------------------------------------------------------------------
  // Host-group operations
  // ---------------------------------------------------------------------------

  /// Upserts a list of host groups into the local cache.
  Future<void> upsertHostGroups(List<Map<String, dynamic>> groups) async {
    final db = await database;
    final batch = db.batch();
    for (final g in groups) {
      batch.insert(
        'host_groups',
        {'groupid': g['groupid']?.toString() ?? '', 'name': g['name']?.toString() ?? ''},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Returns all host groups sorted by name.
  ///   ORDER BY name
  Future<List<Map<String, dynamic>>> getAllHostGroups() async {
    final db = await database;
    return db.query('host_groups', orderBy: 'name');
  }

  // ---------------------------------------------------------------------------
  // Host operations
  // ---------------------------------------------------------------------------

  /// Upserts hosts and their group memberships.
  Future<void> upsertHosts(List<Map<String, dynamic>> hosts) async {
    final db = await database;
    final batch = db.batch();
    for (final h in hosts) {
      final hostid = h['hostid']?.toString() ?? '';
      batch.insert(
        'hosts',
        {
          'hostid': hostid,
          'host': h['host']?.toString() ?? '',
          'name': h['name']?.toString() ?? '',
          'status': h['status']?.toString() ?? '0',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // Group memberships
      final rawGroups = h['groups'] ?? h['hostgroups'];
      if (rawGroups is List) {
        for (final g in rawGroups) {
          final gid = g['groupid']?.toString() ?? '';
          if (gid.isNotEmpty) {
            batch.insert(
              'host_group_members',
              {'hostid': hostid, 'groupid': gid},
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      }

      // Interfaces
      final rawIfaces = h['interfaces'];
      if (rawIfaces is List) {
        for (final iface in rawIfaces) {
          final ifid = iface['interfaceid']?.toString() ?? '';
          if (ifid.isNotEmpty) {
            batch.insert(
              'host_interfaces',
              {
                'interfaceid': ifid,
                'hostid': hostid,
                'ip': iface['ip']?.toString() ?? '',
                'dns': iface['dns']?.toString() ?? '',
                'port': iface['port']?.toString() ?? '',
                'type': iface['type']?.toString() ?? '1',
                'main': iface['main']?.toString() ?? '1',
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      }
    }
    await batch.commit(noResult: true);
  }

  /// Finds a host by its ID.
  ///   WHERE hostid = ?
  Future<Map<String, dynamic>?> getHostById(String hostid) async {
    final db = await database;
    final rows = await db.query('hosts', where: 'hostid = ?', whereArgs: [hostid], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Returns hosts belonging to a specific group.
  ///   JOIN host_group_members ON hosts.hostid = host_group_members.hostid
  ///   WHERE host_group_members.groupid = ?
  ///   ORDER BY hosts.name
  Future<List<Map<String, dynamic>>> getHostsByGroup(String groupid) async {
    final db = await database;
    return db.rawQuery('''
      SELECT h.*
        FROM hosts h
        JOIN host_group_members hgm ON h.hostid = hgm.hostid
       WHERE hgm.groupid = ?
       ORDER BY h.name
    ''', [groupid]);
  }

  /// Searches hosts whose name matches a query string.
  ///   WHERE name LIKE ?
  ///   ORDER BY name
  Future<List<Map<String, dynamic>>> searchHosts(String query) async {
    final db = await database;
    return db.query(
      'hosts',
      where: 'name LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'name',
    );
  }

  // ---------------------------------------------------------------------------
  // Problem operations
  // ---------------------------------------------------------------------------

  /// Upserts problems along with their host links and tags.
  Future<void> upsertProblems(List<Map<String, dynamic>> problems) async {
    final db = await database;
    final batch = db.batch();
    for (final p in problems) {
      final eventid = p['eventid']?.toString() ?? p['triggerid']?.toString() ?? '';
      batch.insert(
        'problems',
        {
          'eventid': eventid,
          'triggerid': p['triggerid']?.toString() ?? '',
          'description': p['description']?.toString() ?? '',
          'priority': p['priority']?.toString() ?? '0',
          'lastchange': p['lastchange']?.toString() ?? '0',
          'value': p['value']?.toString() ?? '1',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // Linked hosts
      final trigHosts = p['hosts'];
      if (trigHosts is List) {
        for (final h in trigHosts) {
          final hid = h['hostid']?.toString() ?? '';
          if (hid.isNotEmpty) {
            batch.insert(
              'problem_hosts',
              {'eventid': eventid, 'hostid': hid},
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      }

      // Tags
      final tags = p['tags'];
      if (tags is List) {
        // Remove old tags for this problem first
        batch.delete('problem_tags', where: 'eventid = ?', whereArgs: [eventid]);
        for (final t in tags) {
          batch.insert('problem_tags', {
            'eventid': eventid,
            'tag': t['tag']?.toString() ?? '',
            'value': t['value']?.toString() ?? '',
          });
        }
      }
    }
    await batch.commit(noResult: true);
  }

  /// Returns all problems sorted by severity (highest first), then by time.
  ///   ORDER BY priority DESC, lastchange DESC
  Future<List<Map<String, dynamic>>> getAllProblems() async {
    final db = await database;
    return db.query('problems', orderBy: 'priority DESC, lastchange DESC');
  }

  /// Returns problems filtered by minimum severity.
  ///   WHERE CAST(priority AS INTEGER) >= ?
  ///   ORDER BY priority DESC, lastchange DESC
  Future<List<Map<String, dynamic>>> getProblemsBySeverity(int minSeverity) async {
    final db = await database;
    return db.query(
      'problems',
      where: 'CAST(priority AS INTEGER) >= ?',
      whereArgs: [minSeverity],
      orderBy: 'priority DESC, lastchange DESC',
    );
  }

  /// Returns problems affecting a specific host.
  ///   JOIN problem_hosts ON problems.eventid = problem_hosts.eventid
  ///   WHERE problem_hosts.hostid = ?
  ///   ORDER BY problems.priority DESC, problems.lastchange DESC
  Future<List<Map<String, dynamic>>> getProblemsForHost(String hostid) async {
    final db = await database;
    return db.rawQuery('''
      SELECT p.*
        FROM problems p
        JOIN problem_hosts ph ON p.eventid = ph.eventid
       WHERE ph.hostid = ?
       ORDER BY p.priority DESC, p.lastchange DESC
    ''', [hostid]);
  }

  /// Returns problems for hosts in a specific group.
  ///   JOIN problem_hosts ON problems.eventid = problem_hosts.eventid
  ///   JOIN host_group_members ON problem_hosts.hostid = host_group_members.hostid
  ///   WHERE host_group_members.groupid = ?
  ///   ORDER BY problems.priority DESC, problems.lastchange DESC
  Future<List<Map<String, dynamic>>> getProblemsForGroup(String groupid) async {
    final db = await database;
    return db.rawQuery('''
      SELECT DISTINCT p.*
        FROM problems p
        JOIN problem_hosts ph ON p.eventid = ph.eventid
        JOIN host_group_members hgm ON ph.hostid = hgm.hostid
       WHERE hgm.groupid = ?
       ORDER BY p.priority DESC, p.lastchange DESC
    ''', [groupid]);
  }

  /// Builds a VRF-to-Customer mapping from problem tags.
  ///   WHERE tag IN ('vrf', 'vrfname', 'vrf_name', 'customer', 'cust', 'customer_name')
  ///   JOIN on eventid
  Future<Map<String, String>> buildVrfToCustomerMap() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT pt.eventid, pt.tag, pt.value
        FROM problem_tags pt
       WHERE LOWER(pt.tag) IN ('vrf', 'vrfname', 'vrf_name',
                                'customer', 'cust', 'customer_name')
       ORDER BY pt.eventid
    ''');

    final perEvent = <String, Map<String, String>>{};
    for (final r in rows) {
      final eid = r['eventid'] as String;
      final tag = (r['tag'] as String).toLowerCase();
      final val = (r['value'] as String).trim();
      if (val.isEmpty) continue;
      perEvent.putIfAbsent(eid, () => <String, String>{});
      if (tag == 'vrf' || tag == 'vrfname' || tag == 'vrf_name') {
        perEvent[eid]!['vrf'] = val;
      }
      if (tag == 'customer' || tag == 'cust' || tag == 'customer_name') {
        perEvent[eid]!['customer'] = val;
      }
    }

    final map = <String, String>{};
    for (final entry in perEvent.values) {
      final vrf = entry['vrf'];
      if (vrf != null && vrf.isNotEmpty) {
        map[vrf] = entry['customer'] ?? map[vrf] ?? '';
      }
    }
    return map;
  }

  // ---------------------------------------------------------------------------
  // Item operations
  // ---------------------------------------------------------------------------

  /// Upserts items and their tags.
  Future<void> upsertItems(String hostid, List<Map<String, dynamic>> items) async {
    final db = await database;
    final batch = db.batch();
    for (final i in items) {
      final itemid = i['itemid']?.toString() ?? '';
      batch.insert(
        'items',
        {
          'itemid': itemid,
          'hostid': hostid,
          'name': i['name']?.toString() ?? '',
          'key_': i['key_']?.toString() ?? '',
          'units': i['units']?.toString() ?? '',
          'value_type': i['value_type']?.toString() ?? '0',
          'lastvalue': i['lastvalue']?.toString() ?? '',
          'lastclock': i['lastclock']?.toString() ?? '0',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // Tags
      final tags = i['tags'];
      if (tags is List) {
        batch.delete('item_tags', where: 'itemid = ?', whereArgs: [itemid]);
        for (final t in tags) {
          batch.insert('item_tags', {
            'itemid': itemid,
            'tag': t['tag']?.toString() ?? '',
            'value': t['value']?.toString() ?? '',
          });
        }
      }
    }
    await batch.commit(noResult: true);
  }

  /// Returns all items for a host.
  ///   WHERE hostid = ?
  ///   ORDER BY name
  Future<List<Map<String, dynamic>>> getItemsForHost(String hostid) async {
    final db = await database;
    return db.query('items', where: 'hostid = ?', whereArgs: [hostid], orderBy: 'name');
  }

  /// Returns only numeric items for a host.
  ///   WHERE hostid = ? AND value_type IN ('0', '3')
  ///   ORDER BY name
  Future<List<Map<String, dynamic>>> getNumericItemsForHost(String hostid) async {
    final db = await database;
    return db.query(
      'items',
      where: "hostid = ? AND value_type IN ('0', '3')",
      whereArgs: [hostid],
      orderBy: 'name',
    );
  }

  /// Returns items matching a key pattern for a host.
  ///   WHERE hostid = ? AND key_ LIKE ?
  Future<List<Map<String, dynamic>>> getItemsByKeyPattern(
    String hostid,
    String keyPattern,
  ) async {
    final db = await database;
    return db.query(
      'items',
      where: 'hostid = ? AND key_ LIKE ?',
      whereArgs: [hostid, '%$keyPattern%'],
      orderBy: 'name',
    );
  }

  // ---------------------------------------------------------------------------
  // History operations
  // ---------------------------------------------------------------------------

  /// Inserts history data points in bulk.
  Future<void> insertHistory(List<Map<String, dynamic>> dataPoints) async {
    final db = await database;
    final batch = db.batch();
    for (final dp in dataPoints) {
      batch.insert('history', {
        'itemid': dp['itemid']?.toString() ?? '',
        'clock': dp['clock'] is int ? dp['clock'] : int.tryParse(dp['clock']?.toString() ?? '0') ?? 0,
        'value': dp['value']?.toString() ?? '',
      });
    }
    await batch.commit(noResult: true);
  }

  /// Returns history for given item IDs within a time range.
  ///   WHERE itemid IN (?, ?, ...) AND clock BETWEEN ? AND ?
  ///   ORDER BY clock ASC
  Future<List<Map<String, dynamic>>> getHistory({
    required List<String> itemIds,
    required int from,
    required int to,
  }) async {
    final db = await database;
    final placeholders = List.filled(itemIds.length, '?').join(', ');
    return db.rawQuery(
      '''
      SELECT * FROM history
       WHERE itemid IN ($placeholders)
         AND clock BETWEEN ? AND ?
       ORDER BY clock ASC
      ''',
      [...itemIds, from, to],
    );
  }

  /// Deletes history older than a given epoch timestamp.
  ///   WHERE clock < ?
  Future<int> pruneHistory(int olderThanEpoch) async {
    final db = await database;
    return db.delete('history', where: 'clock < ?', whereArgs: [olderThanEpoch]);
  }

  // ---------------------------------------------------------------------------
  // Device operations
  // ---------------------------------------------------------------------------

  /// Registers or updates an FCM device token.
  Future<void> upsertDevice(String token, String platform, Map<String, dynamic> filter) async {
    final db = await database;
    await db.insert(
      'devices',
      {
        'token': token,
        'platform': platform,
        'filter': jsonEncode(filter),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
