import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Central SQLite database helper for the Zabbix mobile app.
///
/// The schema is designed around the Zabbix **Low-Level Discovery (LLD)**
/// protocol.  LLD macros (e.g. `{#IFNAME}`, `{#SAPID}`, `{#SNMPINDEX}`,
/// `{#FSNAME}`) are the **key elements** that uniquely identify each
/// discovered entity within a host.
///
/// Data flow:  Relay server -> JSON -> [convertAndStoreXxx] -> SQLite
///
/// Every table includes indexes on columns used in WHERE, JOIN, or ORDER BY
/// so that lookups stay fast even as the cached dataset grows.
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

  // ===========================================================================
  // Schema creation
  // ===========================================================================

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    // -- host_groups ----------------------------------------------------------
    //
    // Relay endpoint:  /api/hostgroups
    batch.execute('''
      CREATE TABLE host_groups (
        groupid  TEXT PRIMARY KEY,
        name     TEXT NOT NULL
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_host_groups_name ON host_groups (name)');

    // -- hosts ----------------------------------------------------------------
    //
    // Relay endpoint:  /api/hosts
    batch.execute('''
      CREATE TABLE hosts (
        hostid  TEXT PRIMARY KEY,
        host    TEXT NOT NULL DEFAULT '',
        name    TEXT NOT NULL DEFAULT '',
        status  TEXT NOT NULL DEFAULT '0'
      )
    ''');
    batch.execute('CREATE INDEX idx_hosts_name   ON hosts (name)');
    batch.execute('CREATE INDEX idx_hosts_status ON hosts (status)');

    // -- host_group_members ---------------------------------------------------
    //
    // Many-to-many: hosts <-> host_groups.
    batch.execute('''
      CREATE TABLE host_group_members (
        hostid   TEXT NOT NULL,
        groupid  TEXT NOT NULL,
        PRIMARY KEY (hostid, groupid),
        FOREIGN KEY (hostid)  REFERENCES hosts (hostid),
        FOREIGN KEY (groupid) REFERENCES host_groups (groupid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_hgm_groupid ON host_group_members (groupid)');

    // -- host_interfaces ------------------------------------------------------
    //
    // Zabbix agent/SNMP/JMX/IPMI interfaces per host.
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
    batch.execute(
        'CREATE INDEX idx_host_ifaces_hostid ON host_interfaces (hostid)');
    batch.execute(
        'CREATE INDEX idx_host_ifaces_ip     ON host_interfaces (ip)');

    // =========================================================================
    //  LLD (Low-Level Discovery) tables
    //
    //  These are the core of the Zabbix discovery protocol.  An LLD rule
    //  periodically discovers entities (interfaces, SAPs, filesystems, ...).
    //  Each discovered entity is a unique combination of LLD macro values.
    //  Items, triggers, and graphs are then auto-created from prototypes
    //  by substituting the macro values.
    // =========================================================================

    // -- discovery_rules ------------------------------------------------------
    //
    // Relay endpoint:  /api/lld-rules?hostid=X
    //
    // An LLD rule defines WHAT to discover on a host.
    // Examples:
    //   "Network interface discovery"  key_=net.if.discovery
    //   "SAP discovery"                key_=sap.discovery
    //   "Filesystem discovery"         key_=vfs.fs.discovery
    batch.execute('''
      CREATE TABLE discovery_rules (
        itemid    TEXT PRIMARY KEY,
        hostid    TEXT NOT NULL,
        name      TEXT NOT NULL DEFAULT '',
        key_      TEXT NOT NULL DEFAULT '',
        type      TEXT NOT NULL DEFAULT '0',
        status    TEXT NOT NULL DEFAULT '0',
        lifetime  TEXT NOT NULL DEFAULT '30d',
        FOREIGN KEY (hostid) REFERENCES hosts (hostid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_drules_hostid ON discovery_rules (hostid)');
    batch.execute(
        'CREATE INDEX idx_drules_key    ON discovery_rules (key_)');

    // -- lld_macro_definitions ------------------------------------------------
    //
    // Which macros a discovery rule produces.
    // Example: rule "net.if.discovery" -> {#IFNAME}, {#IFALIAS}, {#SNMPINDEX}
    batch.execute('''
      CREATE TABLE lld_macro_definitions (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        rule_id  TEXT NOT NULL,
        macro    TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (rule_id) REFERENCES discovery_rules (itemid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_lld_macrodefs_rule ON lld_macro_definitions (rule_id)');
    batch.execute(
        'CREATE INDEX idx_lld_macrodefs_macro ON lld_macro_definitions (macro)');

    // -- discovered_entities --------------------------------------------------
    //
    // Each row is ONE discovered instance (interface, SAP, filesystem, ...).
    // The entity is uniquely identified by the combination of its parent
    // discovery rule and the resolved LLD macro values.
    //
    // macro_hash is a deterministic hash of sorted macro key=value pairs
    // that acts as a dedup / lookup key.
    batch.execute('''
      CREATE TABLE discovered_entities (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        rule_id      TEXT NOT NULL,
        hostid       TEXT NOT NULL,
        entity_name  TEXT NOT NULL DEFAULT '',
        macro_hash   TEXT NOT NULL DEFAULT '',
        first_seen   TEXT NOT NULL DEFAULT '',
        last_seen    TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (rule_id) REFERENCES discovery_rules (itemid),
        FOREIGN KEY (hostid)  REFERENCES hosts (hostid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_entities_rule   ON discovered_entities (rule_id)');
    batch.execute(
        'CREATE INDEX idx_entities_host   ON discovered_entities (hostid)');
    batch.execute(
        'CREATE INDEX idx_entities_hash   ON discovered_entities (macro_hash)');
    batch.execute(
        'CREATE INDEX idx_entities_host_rule ON discovered_entities (hostid, rule_id)');
    batch.execute(
        'CREATE INDEX idx_entities_name   ON discovered_entities (entity_name)');

    // -- lld_macro_values -----------------------------------------------------
    //
    // The **key element** of the LLD protocol: resolved macro name -> value
    // pairs for each discovered entity.
    //
    // Examples for entity "1/1/c1/1" (a Nokia SAP):
    //   macro="{#SAPID}"       value="1/1/c1/1:3070.1569"
    //   macro="{#SAPPORT}"     value="1/1/c1/1"
    //   macro="{#SAPVLAN}"     value="3070"
    batch.execute('''
      CREATE TABLE lld_macro_values (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_id  INTEGER NOT NULL,
        macro      TEXT NOT NULL DEFAULT '',
        value      TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (entity_id) REFERENCES discovered_entities (id)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_macval_entity      ON lld_macro_values (entity_id)');
    batch.execute(
        'CREATE INDEX idx_macval_macro       ON lld_macro_values (macro)');
    batch.execute(
        'CREATE INDEX idx_macval_macro_value ON lld_macro_values (macro, value)');

    // -- item_prototypes ------------------------------------------------------
    //
    // Item prototypes define the template for items that are auto-created
    // for each discovered entity.  The key_ contains unresolved LLD macros.
    //
    // Example:
    //   name="Interface {#IFNAME}: Bits received"
    //   key_="net.if.in[{#IFNAME}]"
    batch.execute('''
      CREATE TABLE item_prototypes (
        itemid      TEXT PRIMARY KEY,
        rule_id     TEXT NOT NULL,
        name        TEXT NOT NULL DEFAULT '',
        key_        TEXT NOT NULL DEFAULT '',
        units       TEXT NOT NULL DEFAULT '',
        value_type  TEXT NOT NULL DEFAULT '0',
        FOREIGN KEY (rule_id) REFERENCES discovery_rules (itemid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_iproto_rule ON item_prototypes (rule_id)');
    batch.execute(
        'CREATE INDEX idx_iproto_key  ON item_prototypes (key_)');

    // -- trigger_prototypes ---------------------------------------------------
    //
    // Trigger prototypes are templates for alerts on discovered entities.
    //
    // Example:
    //   description="Interface {#IFNAME}: Link down"
    //   expression="{host:net.if.status[{#IFNAME}].last()}=2"
    batch.execute('''
      CREATE TABLE trigger_prototypes (
        triggerid    TEXT PRIMARY KEY,
        rule_id      TEXT NOT NULL,
        description  TEXT NOT NULL DEFAULT '',
        expression   TEXT NOT NULL DEFAULT '',
        priority     TEXT NOT NULL DEFAULT '0',
        status       TEXT NOT NULL DEFAULT '0',
        FOREIGN KEY (rule_id) REFERENCES discovery_rules (itemid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_tproto_rule     ON trigger_prototypes (rule_id)');
    batch.execute(
        'CREATE INDEX idx_tproto_priority ON trigger_prototypes (priority)');

    // -- items ----------------------------------------------------------------
    //
    // Relay endpoint:  /api/items?hostid=X
    //
    // Resolved items -- created from prototypes by substituting LLD macros.
    // entity_id links back to the discovered entity this item belongs to
    // (NULL for non-LLD items).
    batch.execute('''
      CREATE TABLE items (
        itemid       TEXT PRIMARY KEY,
        hostid       TEXT NOT NULL,
        entity_id    INTEGER,
        prototype_id TEXT,
        name         TEXT NOT NULL DEFAULT '',
        key_         TEXT NOT NULL DEFAULT '',
        units        TEXT NOT NULL DEFAULT '',
        value_type   TEXT NOT NULL DEFAULT '0',
        lastvalue    TEXT NOT NULL DEFAULT '',
        lastclock    TEXT NOT NULL DEFAULT '0',
        FOREIGN KEY (hostid)       REFERENCES hosts (hostid),
        FOREIGN KEY (entity_id)    REFERENCES discovered_entities (id),
        FOREIGN KEY (prototype_id) REFERENCES item_prototypes (itemid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_items_hostid     ON items (hostid)');
    batch.execute(
        'CREATE INDEX idx_items_entity     ON items (entity_id)');
    batch.execute(
        'CREATE INDEX idx_items_key        ON items (key_)');
    batch.execute(
        'CREATE INDEX idx_items_name       ON items (name)');
    batch.execute(
        'CREATE INDEX idx_items_value_type ON items (value_type)');
    batch.execute(
        'CREATE INDEX idx_items_host_vtype ON items (hostid, value_type)');
    batch.execute(
        'CREATE INDEX idx_items_prototype  ON items (prototype_id)');

    // -- item_tags ------------------------------------------------------------
    //
    // Tags on items -- carry metadata like VRF, Customer, component type.
    batch.execute('''
      CREATE TABLE item_tags (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        itemid  TEXT NOT NULL,
        tag     TEXT NOT NULL DEFAULT '',
        value   TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (itemid) REFERENCES items (itemid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_itag_itemid    ON item_tags (itemid)');
    batch.execute(
        'CREATE INDEX idx_itag_tag       ON item_tags (tag)');
    batch.execute(
        'CREATE INDEX idx_itag_tag_value ON item_tags (tag, value)');

    // -- problems -------------------------------------------------------------
    //
    // Relay endpoint:  /api/triggers
    //
    // Active triggers / problems.
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
    batch.execute(
        'CREATE INDEX idx_prob_priority   ON problems (priority)');
    batch.execute(
        'CREATE INDEX idx_prob_lastchange ON problems (lastchange)');
    batch.execute(
        'CREATE INDEX idx_prob_prio_time  ON problems (priority, lastchange)');
    batch.execute(
        'CREATE INDEX idx_prob_triggerid  ON problems (triggerid)');

    // -- problem_hosts --------------------------------------------------------
    batch.execute('''
      CREATE TABLE problem_hosts (
        eventid  TEXT NOT NULL,
        hostid   TEXT NOT NULL,
        PRIMARY KEY (eventid, hostid),
        FOREIGN KEY (eventid) REFERENCES problems (eventid),
        FOREIGN KEY (hostid)  REFERENCES hosts (hostid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_ph_hostid ON problem_hosts (hostid)');

    // -- problem_tags ---------------------------------------------------------
    batch.execute('''
      CREATE TABLE problem_tags (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        eventid  TEXT NOT NULL,
        tag      TEXT NOT NULL DEFAULT '',
        value    TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (eventid) REFERENCES problems (eventid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_ptag_eventid   ON problem_tags (eventid)');
    batch.execute(
        'CREATE INDEX idx_ptag_tag       ON problem_tags (tag)');
    batch.execute(
        'CREATE INDEX idx_ptag_tag_value ON problem_tags (tag, value)');

    // -- problem_items --------------------------------------------------------
    //
    // Items attached to a problem (from trigger items array).
    // Links a problem back to the discovered entity via item->entity_id.
    batch.execute('''
      CREATE TABLE problem_items (
        eventid  TEXT NOT NULL,
        itemid   TEXT NOT NULL,
        PRIMARY KEY (eventid, itemid),
        FOREIGN KEY (eventid) REFERENCES problems (eventid),
        FOREIGN KEY (itemid)  REFERENCES items (itemid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_pi_itemid ON problem_items (itemid)');

    // -- history --------------------------------------------------------------
    //
    // Relay endpoint:  /api/history?itemids=X&from=Y&to=Z
    batch.execute('''
      CREATE TABLE history (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        itemid  TEXT NOT NULL,
        clock   INTEGER NOT NULL,
        value   TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (itemid) REFERENCES items (itemid)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_hist_item_clock ON history (itemid, clock)');

    // -- devices --------------------------------------------------------------
    //
    // Relay endpoint:  /devices/register
    batch.execute('''
      CREATE TABLE devices (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        token     TEXT NOT NULL UNIQUE,
        platform  TEXT NOT NULL DEFAULT 'android',
        filter    TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_dev_platform ON devices (platform)');

    await batch.commit(noResult: true);
  }

  // ---------------------------------------------------------------------------
  // Schema migration
  // ---------------------------------------------------------------------------

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Future migrations go here.
  }

  // ===========================================================================
  // Convenience helpers
  // ===========================================================================

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
    // Order matters: children before parents (FK constraints).
    for (final table in [
      'history',
      'problem_items',
      'problem_tags',
      'problem_hosts',
      'problems',
      'item_tags',
      'items',
      'trigger_prototypes',
      'item_prototypes',
      'lld_macro_values',
      'discovered_entities',
      'lld_macro_definitions',
      'discovery_rules',
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

  // ===========================================================================
  //  CONVERSION METHODS  -- Relay server JSON -> SQLite
  //
  //  Each method takes the raw JSON list/map returned by the relay server
  //  and converts + upserts it into the local SQLite cache.
  // ===========================================================================

  // -- Host groups (/api/hostgroups) ------------------------------------------

  /// Converts and stores host groups from the relay.
  ///
  /// Expected relay payload (each element):
  /// ```json
  /// { "groupid": "5", "name": "BNG PE" }
  /// ```
  Future<void> convertAndStoreHostGroups(List<dynamic> rawGroups) async {
    final db = await database;
    final batch = db.batch();
    for (final g in rawGroups) {
      batch.insert('host_groups', {
        'groupid': _s(g, 'groupid'),
        'name': _s(g, 'name'),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  // -- Hosts (/api/hosts) -----------------------------------------------------

  /// Converts and stores hosts along with their group memberships and
  /// SNMP/agent interfaces.
  Future<void> convertAndStoreHosts(List<dynamic> rawHosts) async {
    final db = await database;
    final batch = db.batch();
    for (final h in rawHosts) {
      final hostid = _s(h, 'hostid');
      batch.insert('hosts', {
        'hostid': hostid,
        'host': _s(h, 'host'),
        'name': _s(h, 'name'),
        'status': _s(h, 'status', fallback: '0'),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Group memberships
      final groups = h['groups'] ?? h['hostgroups'];
      if (groups is List) {
        for (final g in groups) {
          final gid = _s(g, 'groupid');
          if (gid.isNotEmpty) {
            batch.insert('host_group_members', {
              'hostid': hostid,
              'groupid': gid,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // Interfaces (agent/SNMP/JMX/IPMI)
      final ifaces = h['interfaces'];
      if (ifaces is List) {
        for (final iface in ifaces) {
          final ifid = _s(iface, 'interfaceid');
          if (ifid.isNotEmpty) {
            batch.insert('host_interfaces', {
              'interfaceid': ifid,
              'hostid': hostid,
              'ip': _s(iface, 'ip'),
              'dns': _s(iface, 'dns'),
              'port': _s(iface, 'port'),
              'type': _s(iface, 'type', fallback: '1'),
              'main': _s(iface, 'main', fallback: '1'),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }
    }
    await batch.commit(noResult: true);
  }

  // -- LLD rules (/api/lld-rules?hostid=X) ------------------------------------

  /// Converts and stores LLD discovery rules for a host.
  ///
  /// Also extracts macro definitions and, if the relay provides inline
  /// prototype data, stores item prototypes and trigger prototypes.
  Future<void> convertAndStoreLldRules(
    String hostid,
    List<dynamic> rawRules,
  ) async {
    final db = await database;
    final batch = db.batch();

    for (final r in rawRules) {
      final ruleId = _s(r, 'itemid');
      if (ruleId.isEmpty) continue;

      batch.insert('discovery_rules', {
        'itemid': ruleId,
        'hostid': hostid,
        'name': _s(r, 'name'),
        'key_': _s(r, 'key_'),
        'type': _s(r, 'type', fallback: '0'),
        'status': _s(r, 'status', fallback: '0'),
        'lifetime': _s(r, 'lifetime', fallback: '30d'),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // -- Macro definitions --
      batch.delete('lld_macro_definitions',
          where: 'rule_id = ?', whereArgs: [ruleId]);

      final macroPaths = r['lld_macro_paths'] ?? r['macros'];
      if (macroPaths is List) {
        for (final m in macroPaths) {
          final macroName = _s(m, 'lld_macro').isNotEmpty
              ? _s(m, 'lld_macro')
              : _s(m, 'macro');
          if (macroName.isNotEmpty) {
            batch.insert('lld_macro_definitions', {
              'rule_id': ruleId,
              'macro': macroName,
            });
          }
        }
      }

      // -- Item prototypes --
      final itemProtos = r['item_prototypes'];
      if (itemProtos is List) {
        for (final ip in itemProtos) {
          final ipId = _s(ip, 'itemid');
          if (ipId.isEmpty) continue;
          batch.insert('item_prototypes', {
            'itemid': ipId,
            'rule_id': ruleId,
            'name': _s(ip, 'name'),
            'key_': _s(ip, 'key_'),
            'units': _s(ip, 'units'),
            'value_type': _s(ip, 'value_type', fallback: '0'),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }

      // -- Trigger prototypes --
      final trigProtos = r['trigger_prototypes'];
      if (trigProtos is List) {
        for (final tp in trigProtos) {
          final tpId = _s(tp, 'triggerid');
          if (tpId.isEmpty) continue;
          batch.insert('trigger_prototypes', {
            'triggerid': tpId,
            'rule_id': ruleId,
            'description': _s(tp, 'description'),
            'expression': _s(tp, 'expression'),
            'priority': _s(tp, 'priority', fallback: '0'),
            'status': _s(tp, 'status', fallback: '0'),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }
    await batch.commit(noResult: true);
  }

  // -- Items (/api/items?hostid=X) --------------------------------------------

  /// Converts and stores items for a host.
  ///
  /// For each item whose key_ contains a bracket value (e.g.
  /// `net.if.in[1/1/c1/1]`), the bracket content is extracted as the
  /// primary **LLD macro value** and used to find or create a discovered
  /// entity linked to the appropriate discovery rule.
  Future<void> convertAndStoreItems(
    String hostid,
    List<dynamic> rawItems,
  ) async {
    final db = await database;

    // Pre-load discovery rules for this host so we can link items->entities.
    final rules = await db.query('discovery_rules',
        where: 'hostid = ?', whereArgs: [hostid]);

    // Build a map:  key-prefix -> rule
    final prefixToRule = <String, Map<String, dynamic>>{};
    for (final rule in rules) {
      final ruleKey = rule['key_'] as String;
      // "net.if.discovery" -> stem "net.if"
      final stem = ruleKey
          .replaceAll('.discovery', '')
          .replaceAll('_discovery', '');
      if (stem.isNotEmpty) {
        prefixToRule['$stem.'] = rule;
        prefixToRule[stem] = rule;
      }
    }

    // Cache: macro_hash -> entity_id  (built incrementally during iteration)
    final entityCache = <String, int>{};
    final now = DateTime.now().toIso8601String();

    final batch = db.batch();
    for (final item in rawItems) {
      final itemid = _s(item, 'itemid');
      if (itemid.isEmpty) continue;

      final key = _s(item, 'key_');
      int? entityId;
      String? prototypeId;

      // Extract bracket content -> resolved LLD macro value
      final bracketMatch = RegExp(r'\[([^\]]+)\]').firstMatch(key);
      final macroValue = bracketMatch?.group(1)?.trim() ?? '';

      if (macroValue.isNotEmpty) {
        // Find the discovery rule that owns this item key
        final keyPrefix = key.substring(0, key.indexOf('['));
        final matchedRule = _findRuleForKey(prefixToRule, keyPrefix);

        if (matchedRule != null) {
          final ruleId = matchedRule['itemid'] as String;
          final hash = _macroHash({'value': macroValue, 'rule': ruleId});

          if (entityCache.containsKey(hash)) {
            entityId = entityCache[hash];
          } else {
            // Check if entity already exists in DB
            final existing = await db.query('discovered_entities',
                where: 'macro_hash = ? AND hostid = ?',
                whereArgs: [hash, hostid],
                limit: 1);
            if (existing.isNotEmpty) {
              entityId = existing.first['id'] as int;
              // Update last_seen timestamp
              batch.update('discovered_entities',
                  {'last_seen': now},
                  where: 'id = ?', whereArgs: [entityId]);
            } else {
              // Insert new discovered entity
              entityId = await db.insert('discovered_entities', {
                'rule_id': ruleId,
                'hostid': hostid,
                'entity_name': macroValue,
                'macro_hash': hash,
                'first_seen': now,
                'last_seen': now,
              });
              // Insert the LLD macro value for this entity
              await db.insert('lld_macro_values', {
                'entity_id': entityId,
                'macro': _guessMacroName(
                    matchedRule['key_'] as String, key),
                'value': macroValue,
              });
            }
            entityCache[hash] = entityId;
          }

          // Try to find a matching item prototype
          final protos = await db.query('item_prototypes',
              where: 'rule_id = ?',
              whereArgs: [ruleId]);
          for (final proto in protos) {
            final protoKey = (proto['key_'] as String).toLowerCase();
            if (protoKey.startsWith(keyPrefix.toLowerCase())) {
              prototypeId = proto['itemid'] as String;
              break;
            }
          }
        }
      }

      batch.insert('items', {
        'itemid': itemid,
        'hostid': hostid,
        'entity_id': entityId,
        'prototype_id': prototypeId,
        'name': _s(item, 'name'),
        'key_': key,
        'units': _s(item, 'units'),
        'value_type': _s(item, 'value_type', fallback: '0'),
        'lastvalue': _s(item, 'lastvalue'),
        'lastclock': _s(item, 'lastclock', fallback: '0'),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Tags
      final tags = item['tags'];
      if (tags is List) {
        batch.delete('item_tags', where: 'itemid = ?', whereArgs: [itemid]);
        for (final t in tags) {
          batch.insert('item_tags', {
            'itemid': itemid,
            'tag': _s(t, 'tag'),
            'value': _s(t, 'value'),
          });
        }
      }
    }
    await batch.commit(noResult: true);
  }

  // -- Problems / triggers (/api/triggers) ------------------------------------

  /// Converts and stores problems (active triggers) from the relay.
  Future<void> convertAndStoreProblems(List<dynamic> rawProblems) async {
    final db = await database;
    final batch = db.batch();

    for (final p in rawProblems) {
      final eventid =
          _s(p, 'eventid').isNotEmpty ? _s(p, 'eventid') : _s(p, 'triggerid');
      if (eventid.isEmpty) continue;

      batch.insert('problems', {
        'eventid': eventid,
        'triggerid': _s(p, 'triggerid'),
        'description': _s(p, 'description'),
        'priority': _s(p, 'priority', fallback: '0'),
        'lastchange': _s(p, 'lastchange', fallback: '0'),
        'value': _s(p, 'value', fallback: '1'),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Linked hosts
      final hosts = p['hosts'];
      if (hosts is List) {
        for (final h in hosts) {
          final hid = _s(h, 'hostid');
          if (hid.isNotEmpty) {
            batch.insert('problem_hosts', {
              'eventid': eventid,
              'hostid': hid,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // Tags
      final tags = p['tags'];
      if (tags is List) {
        batch.delete('problem_tags',
            where: 'eventid = ?', whereArgs: [eventid]);
        for (final t in tags) {
          batch.insert('problem_tags', {
            'eventid': eventid,
            'tag': _s(t, 'tag'),
            'value': _s(t, 'value'),
          });
        }
      }

      // Linked items (connects problems to discovered entities via items)
      final items = p['items'];
      if (items is List) {
        for (final it in items) {
          final iid = _s(it, 'itemid');
          if (iid.isNotEmpty) {
            batch.insert('problem_items', {
              'eventid': eventid,
              'itemid': iid,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }
    }
    await batch.commit(noResult: true);
  }

  // -- History (/api/history) -------------------------------------------------

  /// Converts and stores history data points from the relay.
  ///
  /// The relay may return either a keyed map or a flat list.
  Future<void> convertAndStoreHistory(dynamic rawHistory) async {
    final db = await database;
    final batch = db.batch();

    if (rawHistory is Map) {
      for (final entry in rawHistory.entries) {
        final itemid = entry.key.toString();
        final points = entry.value;
        if (points is! List) continue;
        for (final dp in points) {
          batch.insert('history', {
            'itemid': itemid,
            'clock': dp['clock'] is int
                ? dp['clock']
                : int.tryParse(dp['clock']?.toString() ?? '0') ?? 0,
            'value': (dp['value'] ?? '').toString(),
          });
        }
      }
    } else if (rawHistory is List) {
      for (final dp in rawHistory) {
        batch.insert('history', {
          'itemid': _s(dp, 'itemid'),
          'clock': dp['clock'] is int
              ? dp['clock']
              : int.tryParse(dp['clock']?.toString() ?? '0') ?? 0,
          'value': (dp['value'] ?? '').toString(),
        });
      }
    }

    await batch.commit(noResult: true);
  }

  // -- Device registration (/devices/register) --------------------------------

  /// Converts and stores a device token.
  Future<void> convertAndStoreDevice(
    String token,
    String platform,
    Map<String, dynamic> filter,
  ) async {
    final db = await database;
    await db.insert('devices', {
      'token': token,
      'platform': platform,
      'filter': jsonEncode(filter),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ===========================================================================
  //  QUERY METHODS  -- Read from SQLite
  // ===========================================================================

  // -- Host groups ------------------------------------------------------------

  /// Returns all host groups sorted by name.
  Future<List<Map<String, dynamic>>> getAllHostGroups() async {
    final db = await database;
    return db.query('host_groups', orderBy: 'name');
  }

  // -- Hosts ------------------------------------------------------------------

  /// Finds a host by its ID.
  Future<Map<String, dynamic>?> getHostById(String hostid) async {
    final db = await database;
    final rows = await db.query('hosts',
        where: 'hostid = ?', whereArgs: [hostid], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Returns hosts belonging to a specific group.
  Future<List<Map<String, dynamic>>> getHostsByGroup(String groupid) async {
    final db = await database;
    return db.rawQuery('''
      SELECT h.* FROM hosts h
        JOIN host_group_members hgm ON h.hostid = hgm.hostid
       WHERE hgm.groupid = ?
       ORDER BY h.name
    ''', [groupid]);
  }

  /// Searches hosts whose name matches a query string.
  Future<List<Map<String, dynamic>>> searchHosts(String query) async {
    final db = await database;
    return db.query('hosts',
        where: 'name LIKE ?',
        whereArgs: ['%$query%'],
        orderBy: 'name');
  }

  // -- Discovery rules --------------------------------------------------------

  /// Returns LLD discovery rules for a host.
  Future<List<Map<String, dynamic>>> getDiscoveryRules(
      String hostid) async {
    final db = await database;
    return db.query('discovery_rules',
        where: 'hostid = ?', whereArgs: [hostid], orderBy: 'name');
  }

  /// Returns the macro definitions for a discovery rule.
  Future<List<Map<String, dynamic>>> getMacroDefinitions(
      String ruleId) async {
    final db = await database;
    return db.query('lld_macro_definitions',
        where: 'rule_id = ?', whereArgs: [ruleId]);
  }

  // -- Discovered entities (keyed by LLD macros) ------------------------------

  /// All entities for a discovery rule, ordered by entity name.
  Future<List<Map<String, dynamic>>> getEntitiesForRule(
      String ruleId) async {
    final db = await database;
    return db.query('discovered_entities',
        where: 'rule_id = ?', whereArgs: [ruleId], orderBy: 'entity_name');
  }

  /// All entities for a host across all discovery rules.
  Future<List<Map<String, dynamic>>> getEntitiesForHost(
      String hostid) async {
    final db = await database;
    return db.query('discovered_entities',
        where: 'hostid = ?', whereArgs: [hostid], orderBy: 'entity_name');
  }

  /// Find entities by a specific LLD macro value.
  Future<List<Map<String, dynamic>>> findEntitiesByMacro(
    String macro,
    String value,
  ) async {
    final db = await database;
    return db.rawQuery('''
      SELECT de.* FROM discovered_entities de
        JOIN lld_macro_values mv ON de.id = mv.entity_id
       WHERE mv.macro = ? AND mv.value = ?
       ORDER BY de.entity_name
    ''', [macro, value]);
  }

  /// Returns the LLD macro values for a discovered entity.
  Future<List<Map<String, dynamic>>> getMacroValues(int entityId) async {
    final db = await database;
    return db.query('lld_macro_values',
        where: 'entity_id = ?', whereArgs: [entityId]);
  }

  /// Returns entities for a host, filtered by a discovery rule key pattern.
  Future<List<Map<String, dynamic>>> getEntitiesByRuleKey(
    String hostid,
    String ruleKeyPattern,
  ) async {
    final db = await database;
    return db.rawQuery('''
      SELECT de.* FROM discovered_entities de
        JOIN discovery_rules dr ON de.rule_id = dr.itemid
       WHERE dr.hostid = ? AND dr.key_ LIKE ?
       ORDER BY de.entity_name
    ''', [hostid, '%$ruleKeyPattern%']);
  }

  // -- Item prototypes --------------------------------------------------------

  /// Returns item prototypes for a discovery rule.
  Future<List<Map<String, dynamic>>> getItemPrototypes(
      String ruleId) async {
    final db = await database;
    return db.query('item_prototypes',
        where: 'rule_id = ?', whereArgs: [ruleId], orderBy: 'name');
  }

  /// Returns trigger prototypes for a discovery rule.
  Future<List<Map<String, dynamic>>> getTriggerPrototypes(
      String ruleId) async {
    final db = await database;
    return db.query('trigger_prototypes',
        where: 'rule_id = ?', whereArgs: [ruleId],
        orderBy: 'priority DESC');
  }

  // -- Items ------------------------------------------------------------------

  /// All items for a host.
  Future<List<Map<String, dynamic>>> getItemsForHost(
      String hostid) async {
    final db = await database;
    return db.query('items',
        where: 'hostid = ?', whereArgs: [hostid], orderBy: 'name');
  }

  /// Items belonging to a discovered entity.
  Future<List<Map<String, dynamic>>> getItemsForEntity(
      int entityId) async {
    final db = await database;
    return db.query('items',
        where: 'entity_id = ?', whereArgs: [entityId], orderBy: 'name');
  }

  /// Numeric items for a host.
  Future<List<Map<String, dynamic>>> getNumericItemsForHost(
      String hostid) async {
    final db = await database;
    return db.query('items',
        where: "hostid = ? AND value_type IN ('0', '3')",
        whereArgs: [hostid],
        orderBy: 'name');
  }

  /// Items matching a key pattern for a host.
  Future<List<Map<String, dynamic>>> getItemsByKeyPattern(
    String hostid,
    String keyPattern,
  ) async {
    final db = await database;
    return db.query('items',
        where: 'hostid = ? AND key_ LIKE ?',
        whereArgs: [hostid, '%$keyPattern%'],
        orderBy: 'name');
  }

  // -- Problems ---------------------------------------------------------------

  /// All problems sorted by severity then time.
  Future<List<Map<String, dynamic>>> getAllProblems() async {
    final db = await database;
    return db.query('problems',
        orderBy: 'priority DESC, lastchange DESC');
  }

  /// Problems at or above a minimum severity.
  Future<List<Map<String, dynamic>>> getProblemsBySeverity(
      int minSeverity) async {
    final db = await database;
    return db.query('problems',
        where: 'CAST(priority AS INTEGER) >= ?',
        whereArgs: [minSeverity],
        orderBy: 'priority DESC, lastchange DESC');
  }

  /// Problems affecting a specific host.
  Future<List<Map<String, dynamic>>> getProblemsForHost(
      String hostid) async {
    final db = await database;
    return db.rawQuery('''
      SELECT p.* FROM problems p
        JOIN problem_hosts ph ON p.eventid = ph.eventid
       WHERE ph.hostid = ?
       ORDER BY p.priority DESC, p.lastchange DESC
    ''', [hostid]);
  }

  /// Problems for hosts in a specific group.
  Future<List<Map<String, dynamic>>> getProblemsForGroup(
      String groupid) async {
    final db = await database;
    return db.rawQuery('''
      SELECT DISTINCT p.* FROM problems p
        JOIN problem_hosts ph ON p.eventid = ph.eventid
        JOIN host_group_members hgm ON ph.hostid = hgm.hostid
       WHERE hgm.groupid = ?
       ORDER BY p.priority DESC, p.lastchange DESC
    ''', [groupid]);
  }

  /// Problems linked to a specific discovered entity (via items).
  Future<List<Map<String, dynamic>>> getProblemsForEntity(
      int entityId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT DISTINCT p.* FROM problems p
        JOIN problem_items pi ON p.eventid = pi.eventid
        JOIN items i ON pi.itemid = i.itemid
       WHERE i.entity_id = ?
       ORDER BY p.priority DESC, p.lastchange DESC
    ''', [entityId]);
  }

  /// Builds VRF->Customer mapping from problem tags.
  Future<Map<String, String>> buildVrfToCustomerMap() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT pt.eventid, pt.tag, pt.value
        FROM problem_tags pt
       WHERE LOWER(pt.tag) IN ('vrf','vrfname','vrf_name',
                                'customer','cust','customer_name')
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

  // -- History ----------------------------------------------------------------

  /// History for items within a time range.
  Future<List<Map<String, dynamic>>> getHistory({
    required List<String> itemIds,
    required int from,
    required int to,
  }) async {
    final db = await database;
    final placeholders = List.filled(itemIds.length, '?').join(', ');
    return db.rawQuery('''
      SELECT * FROM history
       WHERE itemid IN ($placeholders)
         AND clock BETWEEN ? AND ?
       ORDER BY clock ASC
    ''', [...itemIds, from, to]);
  }

  /// Deletes history older than a given epoch timestamp.
  Future<int> pruneHistory(int olderThanEpoch) async {
    final db = await database;
    return db.delete('history',
        where: 'clock < ?', whereArgs: [olderThanEpoch]);
  }

  // ===========================================================================
  //  Internal helpers
  // ===========================================================================

  /// Safely extract a string from a dynamic map entry.
  static String _s(dynamic obj, String key, {String fallback = ''}) {
    if (obj is! Map) return fallback;
    final v = obj[key];
    if (v == null) return fallback;
    final s = v.toString().trim();
    return s.isEmpty ? fallback : s;
  }

  /// Generates a deterministic hash for a set of macro key=value pairs,
  /// used to dedup discovered entities.
  static String _macroHash(Map<String, String> pairs) {
    final sorted = pairs.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final canonical =
        sorted.map((e) => '${e.key}=${e.value}').join('|');
    // Simple djb2 hash -> hex string
    var hash = 5381;
    for (final c in canonical.codeUnits) {
      hash = ((hash << 5) + hash) ^ c;
    }
    return hash.toUnsigned(32).toRadixString(16);
  }

  /// Guesses the LLD macro name from the rule key and item key.
  ///
  /// Example:
  ///   ruleKey = "net.if.discovery"  -> "{#IFNAME}"
  ///   ruleKey = "sap.discovery"     -> "{#SAPID}"
  ///   ruleKey = "vfs.fs.discovery"  -> "{#FSNAME}"
  static String _guessMacroName(String ruleKey, String itemKey) {
    final rk = ruleKey.toLowerCase();
    if (rk.contains('sap')) return '{#SAPID}';
    if (rk.contains('net.if') || rk.contains('if.discovery')) {
      return '{#IFNAME}';
    }
    if (rk.contains('vfs.fs')) return '{#FSNAME}';
    if (rk.contains('snmp')) return '{#SNMPINDEX}';
    if (rk.contains('vm.block') || rk.contains('vfs.dev')) {
      return '{#DEVNAME}';
    }
    if (rk.contains('sensor')) return '{#SENSOR_ID}';
    if (rk.contains('process') || rk.contains('proc')) return '{#PNAME}';
    // Fallback: derive from item key prefix
    final prefix = itemKey.contains('[')
        ? itemKey
            .substring(0, itemKey.indexOf('['))
            .split('.')
            .last
            .toUpperCase()
        : 'ENTITY';
    return '{#$prefix}';
  }

  /// Finds the best matching rule for an item key prefix by trying
  /// progressively shorter prefixes.
  static Map<String, dynamic>? _findRuleForKey(
    Map<String, Map<String, dynamic>> prefixToRule,
    String keyPrefix,
  ) {
    // Direct match first
    if (prefixToRule.containsKey('$keyPrefix.')) {
      return prefixToRule['$keyPrefix.'];
    }
    if (prefixToRule.containsKey(keyPrefix)) {
      return prefixToRule[keyPrefix];
    }
    // Try progressively shorter prefixes
    final parts = keyPrefix.split('.');
    for (var i = parts.length; i > 0; i--) {
      final candidate = '${parts.sublist(0, i).join('.')}.';
      if (prefixToRule.containsKey(candidate)) {
        return prefixToRule[candidate];
      }
      final candidateNoTrail = parts.sublist(0, i).join('.');
      if (prefixToRule.containsKey(candidateNoTrail)) {
        return prefixToRule[candidateNoTrail];
      }
    }
    return null;
  }
}
