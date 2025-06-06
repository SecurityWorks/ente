import "dart:async";
import "dart:io" show File;

import "package:flutter/foundation.dart" show kDebugMode;
import "package:flutter/material.dart" show BuildContext;
import "package:logging/logging.dart";
import "package:path_provider/path_provider.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/memories_db.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/events/memories_changed_event.dart";
import "package:photos/events/memories_setting_changed.dart";
import "package:photos/events/memory_seen_event.dart";
import "package:photos/extensions/stop_watch.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/memories/memories_cache.dart";
import "package:photos/models/memories/memory.dart";
import "package:photos/models/memories/smart_memory.dart";
import "package:photos/models/memories/smart_memory_constants.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/notification_service.dart";
import "package:photos/services/search_service.dart";
import "package:photos/ui/home/memories/full_screen_memory.dart";
import "package:photos/utils/navigation_util.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:synchronized/synchronized.dart";

class MemoriesCacheService {
  static const _lastMemoriesCacheUpdateTimeKey = "lastMemoriesCacheUpdateTime";
  static const _showAnyMemoryKey = "memories.enabled";
  static const _shouldUpdateCacheKey = "memories.shouldUpdateCache";

  /// Delay is for cache update to be done not during app init, during which a
  /// lot of other things are happening.
  static const _kCacheUpdateDelay = Duration(seconds: 5);

  final SharedPreferences _prefs;
  late final Logger _logger = Logger("MemoriesCacheService");

  final _memoriesDB = MemoriesDB.instance;

  List<SmartMemory>? _cachedMemories;
  bool _shouldUpdate = false;

  bool _isUpdatingMemories = false;
  bool get isUpdatingMemories => _isUpdatingMemories;

  final _memoriesUpdateLock = Lock();

  MemoriesCacheService(this._prefs) {
    _logger.fine("MemoriesCacheService constructor");

    Future.delayed(_kCacheUpdateDelay, () {
      _checkIfTimeToUpdateCache();
      _memoriesDB.clearMemoriesSeenBeforeTime(
        DateTime.now()
            .subtract(kMemoriesUpdateFrequency)
            .microsecondsSinceEpoch,
      );
    });

    Bus.instance.on<FilesUpdatedEvent>().where((event) {
      return event.type == EventType.deletedFromEverywhere;
    }).listen((event) {
      if (_cachedMemories == null) return;
      final generatedIDs = event.updatedFiles
          .where((element) => element.generatedID != null)
          .map((e) => e.generatedID!)
          .toSet();
      for (final memory in _cachedMemories!) {
        memory.memories
            .removeWhere((m) => generatedIDs.contains(m.file.generatedID));
      }
    });
  }

  Future<void> _resetLastMemoriesCacheUpdateTime() async {
    await _prefs.setInt(
      _lastMemoriesCacheUpdateTimeKey,
      DateTime.now().microsecondsSinceEpoch,
    );
  }

  int get lastMemoriesCacheUpdateTime {
    return _prefs.getInt(_lastMemoriesCacheUpdateTimeKey) ?? 0;
  }

  bool get showAnyMemories {
    return _prefs.getBool(_showAnyMemoryKey) ?? true;
  }

  Future<void> setShowAnyMemories(bool value) async {
    await _prefs.setBool(_showAnyMemoryKey, value);
    Bus.instance.fire(MemoriesSettingChanged());
  }

  bool get enableSmartMemories =>
      flagService.hasGrantedMLConsent &&
      localSettings.isMLLocalIndexingEnabled &&
      localSettings.isSmartMemoriesEnabled;

  bool get curatedMemoriesOption =>
      showAnyMemories &&
      flagService.hasGrantedMLConsent &&
      localSettings.isMLLocalIndexingEnabled;

  void _checkIfTimeToUpdateCache() {
    if (!enableSmartMemories) {
      return;
    }
    _shouldUpdate = _prefs.getBool(_shouldUpdateCacheKey) ?? _shouldUpdate;
    if (_timeToUpdateCache()) {
      queueUpdateCache();
    }
  }

  bool _timeToUpdateCache() {
    return lastMemoriesCacheUpdateTime <
        DateTime.now()
            .subtract(kMemoriesUpdateFrequency)
            .microsecondsSinceEpoch;
  }

  Future<String> _getCachePath() async {
    return (await getApplicationSupportDirectory()).path +
        "/cache/memories_cache";
  }

  Future markMemoryAsSeen(Memory memory, bool lastInList) async {
    memory.markSeen();
    await _memoriesDB.markMemoryAsSeen(
      memory,
      DateTime.now().microsecondsSinceEpoch,
    );
    if (_cachedMemories != null && memory.file.generatedID != null) {
      final generatedID = memory.file.generatedID!;
      for (final smartMemory in _cachedMemories!) {
        for (final mem in smartMemory.memories) {
          if (mem.file.generatedID == generatedID) {
            mem.markSeen();
          }
        }
      }
    }
    if (lastInList) Bus.instance.fire(MemorySeenEvent());
  }

  void queueUpdateCache() {
    _shouldUpdate = true;
    unawaited(_prefs.setBool(_shouldUpdateCacheKey, true));
  }

  Future<void> _cacheUpdated() async {
    _shouldUpdate = false;
    unawaited(_prefs.setBool(_shouldUpdateCacheKey, false));
    await _resetLastMemoriesCacheUpdateTime();
    Bus.instance.fire(MemoriesChangedEvent());
  }

  Future<void> updateCache({bool forced = false}) async {
    if (!showAnyMemories) {
      return;
    }
    if (!enableSmartMemories) {
      await _calculateRegularFillers();
      return;
    }
    _checkIfTimeToUpdateCache();

    return _memoriesUpdateLock.synchronized(() async {
      if ((!_shouldUpdate && !forced)) {
        _logger.info(
          "No update needed (shouldUpdate: $_shouldUpdate, forced: $forced)",
        );
        return;
      }
      _logger.info(
        "Updating memories cache (shouldUpdate: $_shouldUpdate, forced: $forced)",
      );
      _isUpdatingMemories = true;
      try {
        final EnteWatch? w =
            kDebugMode ? EnteWatch("MemoriesCacheService") : null;
        w?.start();
        final oldCache = await _readCacheFromDisk();
        w?.log("gotten old cache");
        final MemoriesCache newCache = _processOldCache(oldCache);
        w?.log("processed old cache");
        // calculate memories for this period and for the next period
        final now = DateTime.now();
        final next = now.add(kMemoriesUpdateFrequency);
        final nowResult =
            await smartMemoriesService.calcSmartMemories(now, newCache);
        if (nowResult.isEmpty) {
          _cachedMemories = [];
          _logger.warning(
            "No memories found for now, not updating cache and returning early",
          );
          return;
        }
        final nextResult =
            await smartMemoriesService.calcSmartMemories(next, newCache);
        w?.log("calculated new memories");
        for (final nowMemory in nowResult.memories) {
          newCache.toShowMemories
              .add(ToShowMemory.fromSmartMemory(nowMemory, now));
        }
        for (final nextMemory in nextResult.memories) {
          newCache.toShowMemories
              .add(ToShowMemory.fromSmartMemory(nextMemory, next));
        }
        newCache.baseLocations.addAll(nowResult.baseLocations);
        w?.log("added memories to cache");
        final file = File(await _getCachePath());
        if (!file.existsSync()) {
          file.createSync(recursive: true);
        }
        _cachedMemories = nowResult.memories
            .where((memory) => memory.shouldShowNow())
            .toList();
        await _scheduleOnThisDayNotifications(
          [...nowResult.memories, ...nextResult.memories],
        );
        locationService.baseLocations = nowResult.baseLocations;
        await file.writeAsBytes(
          MemoriesCache.encodeToJsonString(newCache).codeUnits,
        );
        w?.log("cacheWritten");
        await _cacheUpdated();
        w?.logAndReset('_cacheUpdated method done');
      } catch (e, s) {
        _logger.info("Error updating memories cache", e, s);
      } finally {
        _isUpdatingMemories = false;
      }
    });
  }

  /// WARNING: Use for testing only, TODO: lau: remove later
  Future<MemoriesCache> debugCacheForTesting() async {
    final oldCache = await _readCacheFromDisk();
    final MemoriesCache newCache = _processOldCache(oldCache);
    return newCache;
  }

  Future<void> _scheduleOnThisDayNotifications(
    List<SmartMemory> allMemories,
  ) async {
    await NotificationService.instance
        .clearAllScheduledNotifications(containingPayload: "onThisDay");
    final scheduledDates = <DateTime>{};
    for (final memory in allMemories) {
      if (memory.type != MemoryType.onThisDay) {
        continue;
      }
      final numberOfMemories = memory.memories.length;
      if (numberOfMemories < 5) continue;
      final firstDateToShow =
          DateTime.fromMicrosecondsSinceEpoch(memory.firstDateToShow);
      final scheduleTime = DateTime(
        firstDateToShow.year,
        firstDateToShow.month,
        firstDateToShow.day,
        8,
      );
      if (scheduleTime.isBefore(DateTime.now())) {
        _logger.info(
          "Skipping scheduling notification for memory ${memory.id} because the date is in the past",
        );
        continue;
      }
      if (scheduledDates.contains(scheduleTime)) {
        _logger.info(
          "Skipping scheduling notification for memory ${memory.id} because the date is already scheduled",
        );
        continue;
      }
      await NotificationService.instance.scheduleNotification(
        "On this day",
        "Look back on $numberOfMemories memories 🌄",
        id: memory.id.hashCode,
        channelID: "onThisDay",
        channelName: "On this day",
        payload: memory.id,
        dateTime: scheduleTime,
        timeoutDurationAndroid: const Duration(hours: 16),
      );
      scheduledDates.add(scheduleTime);
    }
  }

  MemoriesCache _processOldCache(MemoriesCache? oldCache) {
    final List<PeopleShownLog> peopleShownLogs = [];
    final List<ClipShownLog> clipShownLogs = [];
    final List<TripsShownLog> tripsShownLogs = [];
    if (oldCache != null) {
      final now = DateTime.now();
      for (final peopleLog in oldCache.peopleShownLogs) {
        if (now.difference(
              DateTime.fromMicrosecondsSinceEpoch(peopleLog.lastTimeShown),
            ) <
            maxShowTimeout) {
          peopleShownLogs.add(peopleLog);
        }
      }
      for (final tripsLog in oldCache.tripsShownLogs) {
        if (now.difference(
              DateTime.fromMicrosecondsSinceEpoch(tripsLog.lastTimeShown),
            ) <
            maxShowTimeout) {
          tripsShownLogs.add(tripsLog);
        }
      }
      for (final clipLog in oldCache.clipShownLogs) {
        if (now.difference(
              DateTime.fromMicrosecondsSinceEpoch(clipLog.lastTimeShown),
            ) <
            maxShowTimeout) {
          clipShownLogs.add(clipLog);
        }
      }
      for (final oldMemory in oldCache.toShowMemories) {
        if (oldMemory.isOld) {
          if (oldMemory.type == MemoryType.people) {
            peopleShownLogs.add(PeopleShownLog.fromOldCacheMemory(oldMemory));
          } else if (oldMemory.type == MemoryType.clip) {
            clipShownLogs.add(ClipShownLog.fromOldCacheMemory(oldMemory));
          } else if (oldMemory.type == MemoryType.trips) {
            tripsShownLogs.add(TripsShownLog.fromOldCacheMemory(oldMemory));
          }
        }
      }
    }
    return MemoriesCache(
      toShowMemories: [],
      peopleShownLogs: peopleShownLogs,
      clipShownLogs: clipShownLogs,
      tripsShownLogs: tripsShownLogs,
      baseLocations: [],
    );
  }

  Future<List<SmartMemory>> _fromCacheToMemories(MemoriesCache cache) async {
    try {
      _logger.info('Processing disk cache memories to smart memories');
      final List<SmartMemory> memories = [];
      final allFiles = Set<EnteFile>.from(
        await SearchService.instance.getAllFilesForSearch(),
      );
      final allFileIdsToFile = <int, EnteFile>{};
      for (final file in allFiles) {
        if (file.uploadedFileID != null) {
          allFileIdsToFile[file.uploadedFileID!] = file;
        }
      }
      final seenTimes = await _memoriesDB.getSeenTimes();

      for (final ToShowMemory memory in cache.toShowMemories) {
        if (memory.shouldShowNow()) {
          final smartMemory = SmartMemory(
            memory.fileUploadedIDs
                .where((fileID) => allFileIdsToFile.containsKey(fileID))
                .map(
                  (fileID) =>
                      Memory.fromFile(allFileIdsToFile[fileID]!, seenTimes),
                )
                .toList(),
            memory.type,
            memory.title,
            memory.firstTimeToShow,
            memory.lastTimeToShow,
            id: memory.id,
          );
          if (smartMemory.memories.isNotEmpty) {
            memories.add(smartMemory);
          }
        }
      }
      locationService.baseLocations = cache.baseLocations;
      _logger.info('Processing of disk cache memories done');
      return memories;
    } catch (e, s) {
      _logger.severe("Error converting cache to memories", e, s);
      return [];
    }
  }

  Future<List<SmartMemory>?> _getMemoriesFromCache() async {
    final cache = await _readCacheFromDisk();
    if (cache == null) {
      return null;
    }
    final result = await _fromCacheToMemories(cache);
    return result;
  }

  Future<void> _calculateRegularFillers() async {
    if (_cachedMemories == null) {
      _cachedMemories = await smartMemoriesService.calcSimpleMemories();
      Bus.instance.fire(MemoriesChangedEvent());
    }
    return;
  }

  Future<List<SmartMemory>> getMemoriesForWidget({
    required bool onThisDay,
    required bool pastYears,
    required bool smart,
  }) async {
    if (!onThisDay && !pastYears && !smart) {
      _logger.info(
        'No memories requested, returning empty list',
      );
      return [];
    }
    final allMemories = await getMemories();
    if (onThisDay && pastYears && smart) {
      return allMemories;
    }
    final filteredMemories = <SmartMemory>[];
    for (final memory in allMemories) {
      if (!memory.shouldShowNow()) continue;
      if (memory.type == MemoryType.onThisDay) {
        if (!onThisDay) continue;
      } else if (memory.type == MemoryType.filler) {
        if (!pastYears) continue;
      } else {
        if (!smart) continue;
      }
      filteredMemories.add(memory);
    }
    return filteredMemories;
  }

  Future<List<SmartMemory>> getMemories() async {
    if (!showAnyMemories) {
      _logger.info('Showing memories is disabled in settings, showing none');
      return [];
    }
    if (_cachedMemories != null && _cachedMemories!.isNotEmpty) {
      return _cachedMemories!;
    }
    try {
      if (!enableSmartMemories) {
        await _calculateRegularFillers();
        return _cachedMemories!;
      }
      _cachedMemories = await _getMemoriesFromCache();
      if (_cachedMemories == null || _cachedMemories!.isEmpty) {
        _logger.warning(
          "No memories found in cache, force updating cache. Possible severe caching issue",
        );
        await updateCache(forced: true);
      } else {
        _logger.info("Found memories in cache");
      }
      if (_cachedMemories == null || _cachedMemories!.isEmpty) {
        _logger
            .severe("No memories found in (computed) cache, getting fillers");
        await _calculateRegularFillers();
      }
      return _cachedMemories!;
    } catch (e, s) {
      _logger.severe("Error in getMemories", e, s);
      return [];
    }
  }

  Future<List<SmartMemory>?> getCachedMemories() async {
    return _cachedMemories;
  }

  Future<void> goToMemoryFromGeneratedFileID(
    BuildContext context,
    int generatedFileID,
  ) async {
    final allMemories = await getMemories();
    if (allMemories.isEmpty) return;
    int memoryIdx = 0;
    int fileIdx = 0;
    bool found = false;
    memoryLoop:
    for (final memory in _cachedMemories!) {
      for (final mem in memory.memories) {
        if (mem.file.generatedID == generatedFileID) {
          found = true;
          break memoryLoop;
        }
        fileIdx++;
      }
      memoryIdx++;
      fileIdx = 0;
    }
    if (!found) {
      _logger.warning(
        "Could not find memory with generatedFileID: $generatedFileID",
      );
      return;
    }
    await routeToPage(
      context,
      FullScreenMemoryDataUpdater(
        initialIndex: fileIdx,
        memories: allMemories[memoryIdx].memories,
        child: FullScreenMemory(allMemories[memoryIdx].title, fileIdx),
      ),
      forceCustomPageRoute: true,
    );
  }

  Future<void> goToMemoryFromMemoryID(
    BuildContext context,
    String memoryID,
  ) async {
    final allMemories = await getMemories();
    if (allMemories.isEmpty) return;
    int memoryIdx = 0;
    bool found = false;
    memoryLoop:
    for (final memory in _cachedMemories!) {
      if (memory.id == memoryID) {
        found = true;
        break memoryLoop;
      }
      memoryIdx++;
    }
    if (!found) {
      _logger.warning(
        "Could not find memory with memoryID: $memoryID",
      );
      return;
    }
    await routeToPage(
      context,
      FullScreenMemoryDataUpdater(
        initialIndex: 0,
        memories: allMemories[memoryIdx].memories,
        child: FullScreenMemory(allMemories[memoryIdx].title, 0),
      ),
      forceCustomPageRoute: true,
    );
  }

  Future<MemoriesCache?> _readCacheFromDisk() async {
    _logger.info("Reading memories cache result from disk");
    final file = File(await _getCachePath());
    if (!file.existsSync()) {
      _logger.info("No memories cache found");
      return null;
    }
    final allFiles = Set<EnteFile>.from(
      await SearchService.instance.getAllFilesForSearch(),
    );
    final allFileIdsToFile = <int, EnteFile>{};
    for (final file in allFiles) {
      if (file.uploadedFileID != null) {
        allFileIdsToFile[file.uploadedFileID!] = file;
      }
    }
    try {
      final bytes = await file.readAsBytes();
      final jsonString = String.fromCharCodes(bytes);
      final cache =
          MemoriesCache.decodeFromJsonString(jsonString, allFileIdsToFile);
      _logger.info("Reading memories cache result from disk done");
      return cache;
    } catch (e, s) {
      _logger.severe("Error reading or decoding cache file", e, s);
      await file.delete();
      return null;
    }
  }

  Future<void> clearMemoriesCache({bool fromDisk = true}) async {
    if (fromDisk) {
      final file = File(await _getCachePath());
      if (file.existsSync()) {
        await file.delete();
      }
    }
    _cachedMemories = null;
  }
}
