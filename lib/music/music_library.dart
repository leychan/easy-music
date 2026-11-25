import 'dart:async';
import 'dart:io' show File;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import '../account/account.dart';
import '../account/kugou/kugou_auth.dart';
import '../player/playback.dart';
import '../player/session_store.dart';
import '../player/lyrics.dart';
import '../player/track.dart';
import 'catalog.dart';
import 'discover_cache.dart';
import 'kugou_catalog_api.dart';
import 'kugou_cloud_upload.dart';
import 'kugou_music_api.dart';
import 'kugou_playlist_api.dart';
import 'playlist_import.dart';
import 'song.dart';

/// 「拿到可播放链接」这一步的结果。
///
/// 拆成独立类型是为了让界面能把「拿不到链接」和「拿到但播放失败」分开提示：
/// 前者通常是版权/VIP 限制，后者才是真正的播放错误。
class ResolvedTrack {
  const ResolvedTrack({required this.track, required this.song, this.url});

  final Track track;
  final Song song;
  final SongUrl? url;

  bool get blocked => url == null;
}

/// 音乐库的业务入口：搜索、歌单、把一首歌变成可播放的 [Track]。
///
/// 界面上所有与酷狗内容相关的动作都经过这里，好处是「取播放地址」这条最容
/// 易失败的链路只有一个实现，缓存与错误文案也只有一份。
class MusicLibrary extends ChangeNotifier {
  MusicLibrary(this._account, {SessionStore? store}) : discoverCache = DiscoverCache(store) {
    _account.addListener(_onAccountChanged);
  }

  final Account _account;
  final DiscoverCache discoverCache;

  /// 搜索结果缓存的条数上限，避免长时间滚动把内存吃满。
  static const _cacheLimit = 400;

  final _urlCache = <(String, int, AudioQuality), SongUrl>{};
  final _covers = <(bool, int), String>{};
  final _pendingCovers = <(bool, int), Future<Map<int, String>>>{};
  final _favoriteCommands = Lock();
  final _favoriteKeys = <String>{};
  final _favoriteRequests = <((int, String), String), Future<bool>>{};
  (int, String)? _favoriteOwner;
  Future<void>? _favoritesLoad;
  bool _favoritesLoaded = false;
  bool _disposed = false;

  KugouMusicApi? get api {
    final client = _account.client;
    return client == null ? null : KugouMusicApi(client);
  }

  @override
  void dispose() {
    _disposed = true;
    _account.removeListener(_onAccountChanged);
    super.dispose();
  }

  void _onAccountChanged() {
    // 换账号会改变会员权限，旧的播放地址可能已经是低音质了。
    _urlCache.clear();
    final owner = _favoriteScope(_account.session);
    if (owner != _favoriteOwner) {
      _favoriteOwner = owner;
      _favoriteKeys.clear();
      _favoritesLoad = null;
      _favoritesLoaded = false;
      notifyListeners();
      unawaited(loadFavorites());
    }
  }

  /// 搜索歌曲。关键字前后的空白由调用方负责清理。
  Future<List<Song>> search(String keyword, {int page = 1}) async {
    final api = this.api;
    if (api == null) return const [];
    return api.searchSongs(keyword, page: page);
  }

  Future<List<String>> suggest(String keyword) async =>
      await api?.searchSuggest(keyword) ?? const [];

  Future<CatalogSearchResult<List<CatalogHit>>> searchCatalogPage(
    String keyword,
    SearchType type, {
    required int page,
  }) async {
    final result = await api?.searchCatalogPage(keyword, type, page: page);
    if (result == null) return (hits: const <CatalogHit>[], hasMore: false);
    if (type != SearchType.song) return result;
    return (hits: await _completeSearchCovers(result.hits), hasMore: result.hasMore);
  }

  Future<CatalogSearchResult<Map<SearchType, List<CatalogHit>>>> searchComplex(
    String keyword, {
    required int page,
  }) async {
    final result = await _readyApi.searchComplex(keyword, page: page);
    final songs = result.hits[SearchType.song];
    if (songs == null) return result;
    return (
      hits: {...result.hits, SearchType.song: await _completeSearchCovers(songs)},
      hasMore: result.hasMore,
    );
  }

  Future<List<CatalogHit>> _completeSearchCovers(List<CatalogHit> hits) async =>
      (await completeCovers(hits.map((hit) => hit.song).whereType<Song>().toList()))
          .map(CatalogHit.track).toList();

  Future<List<Song>> artistTracks(String id) async =>
      await api?.artistTracks(id) ?? const [];

  Future<List<Song>> albumTracks(String id, {bool purchased = false}) async =>
      await api?.albumTracks(id, purchased: purchased) ?? const [];

  Future<List<Song>> purchasedSongs(int page) async =>
      completeCovers(await _readyApi.purchasedSongs(page));

  Future<List<CatalogHit>> purchasedAlbums(int page) => _readyApi.purchasedAlbums(page);

  Future<List<CloudTrack>> cloudTracks(int page) => _readyApi.cloudTracks(page);

  Future<void> uploadCloudFile(
    String fileName, Stream<Uint8List> Function() open,
    void Function(int uploaded, int total) progress,
  ) => _readyApi.uploadCloudFile(fileName, open, progress);

  Future<void> deleteCloudTrack(CloudTrack track) => _readyApi.deleteCloudTrack(track);

  Future<PlaybackOutcome> playCloud(CloudTrack item, Playback player, {bool resumeCurrent = false}) async {
    try {
      final address = await _readyApi.cloudAddress(item);
      if (_account.session?.userid != item.userid) {
        return const PlaybackOutcome.failed('账号已变化，请重新点播。');
      }
      await player.playTracks([
        Track(
          id: item.id, title: item.song.title, source: address,
          artist: item.song.artist, duration: item.song.duration,
          artUri: _coverUri(item.song.albumImage),
          albumAudioId: item.song.albumAudioId, albumId: item.song.albumId,
        ),
      ], resumeCurrent: resumeCurrent);
      return const PlaybackOutcome.started();
    } on KugouFailure catch (error) {
      return PlaybackOutcome.failed(error.message);
    } catch (_) {
      return const PlaybackOutcome.failed('无法播放这首云盘音乐。');
    }
  }

  Future<List<Song>> freeListenSongs() async =>
      await api?.freeListenSongs() ?? const [];

  Future<List<Song>> personalFmSongs({Set<String> excludeIds = const {}}) async =>
      completeCovers(await api?.personalFmSongs(excludeIds: excludeIds) ?? const []);

  final _startupFmPagination = Lock();
  int? _startupFmExhaustedFor;
  final _recommendedPlaylists = <(int?, int), Future<List<Playlist>>>{};
  late final int? _discoverStartupOwner = _account.session?.userid;
  final _discoverFmLoads = <int, Future<List<Song>>>{};
  final _discoverPlaylistLoads = <int?, Future<List<Playlist>>>{};

  bool get startupFmExhausted => _startupFmExhaustedFor != null &&
      _account.session?.userid == _startupFmExhaustedFor;

  Future<List<Song>> startupFmSongs() => _loadStartupFm(refresh: false);

  /// 首次打开发现页时刷新，后续路由重建共用请求和缓存中的分页结果。
  Future<List<Song>> discoverFmSongs() async {
    final owner = _account.session?.userid;
    if (owner == null) return const [];
    final refresh = owner == _discoverStartupOwner;
    final firstBatch = await _discoverFmLoads.putIfAbsent(owner, () => _loadStartupFm(refresh: refresh));
    return discoverCache.readFm(owner) ?? firstBatch;
  }

  /// 推荐首页每次启动只请求一次，与独立歌单页的分类请求各自管理。
  Future<List<Playlist>> discoverPlaylists() {
    final owner = _account.session?.userid;
    final refresh = owner == _discoverStartupOwner;
    return _discoverPlaylistLoads.putIfAbsent(owner, () async {
      // 中途切换账号时沿用该账号自己的缓存，仅在缺失时首次加载。
      final cached = discoverCache.readPlaylists(owner);
      if (!refresh && cached != null) return cached;
      final lists = await recommendedPlaylists(refresh: refresh);
      if (!_disposed) discoverCache.savePlaylists(owner, lists);
      return lists;
    });
  }

  Future<List<Song>> _loadStartupFm({required bool refresh}) async {
    final owner = _account.session?.userid;
    if (owner == null) return const [];
    // 刷新和分页串行处理，失败时保留上一批歌曲及其分页状态。
    return _startupFmPagination.synchronized(() async {
      if (_account.session?.userid != owner) return const [];
      final cached = discoverCache.readFm(owner);
      if (!refresh && cached != null) return cached;
      final songs = await personalFmSongs();
      if (_account.session?.userid != owner) return const [];
      discoverCache.saveFm(owner, songs);
      _startupFmExhaustedFor = null;
      return songs;
    });
  }

  /// 翻页只追加新歌曲，发现页和侧栏再次打开时共用已经加载的内容。
  Future<List<Song>> appendStartupFmSongs() async {
    final owner = _account.session?.userid;
    if (owner == null) return const [];
    return _startupFmPagination.synchronized(() async {
      if (_account.session?.userid != owner) return const [];
      final songs = discoverCache.readFm(owner) ?? const [];
      if (songs.isEmpty || startupFmExhausted) return songs;
      final more = await personalFmSongs(excludeIds: {for (final song in songs) song.id});
      if (_account.session?.userid != owner) return const [];
      _startupFmExhaustedFor = more.isEmpty ? owner : null;
      if (more.isEmpty) return songs;
      final combined = List<Song>.unmodifiable([...songs, ...more]);
      discoverCache.saveFm(owner, combined);
      return combined;
    });
  }

  Future<List<Playlist>> recommendedPlaylists({int category = 0, bool refresh = false}) {
    final key = (_account.session?.userid, category);
    if (refresh) _recommendedPlaylists.remove(key);
    return _recommendedPlaylists.putIfAbsent(key, () async =>
        await api?.recommendedPlaylists(category: category) ?? const [],
      );
  }

  Future<Uri> videoAddress(String hash) async =>
      await api?.videoAddress(hash) ??
      (throw const KugouFailure('音乐库尚未就绪。'));

  Future<List<String>> artistPortraits(Track track) async {
    if (track.kugouHash == null) return const [];
    final name = track.artist.split('、').first.trim();
    if (name.isEmpty || name == '未知歌手') return const [];
    return await api?.artistPortraits(name) ?? const [];
  }

  Future<List<Playlist>> ranks() async => await api?.rankList() ?? const [];

  Future<List<Song>> rankSongs(String rankId) async =>
      await api?.rankSongs(rankId) ?? const [];

  Future<List<Playlist>> myPlaylists() async =>
      await api?.userPlaylists() ?? const [];

  bool canEditPlaylist(Playlist playlist) {
    final session = _account.session;
    return session != null && (playlist.type == 0 || playlist.isDefault) &&
        playlist.cloudListIdFor(session.userid) != null;
  }

  KugouMusicApi get _readyApi =>
      api ?? (throw const KugouFailure('音乐库尚未就绪。'));

  Future<void> createPlaylist(String name) => _readyApi.createPlaylist(name);

  Future<void> editPlaylist(Playlist list, String name, String description) =>
      _readyApi.editPlaylist(list, name, description);

  Future<void> addPlaylistSong(Playlist list, Song song) async {
    if (list.isDefault) return _editLikedSong(list, song, add: true);
    await _readyApi.addPlaylistSong(list, song);
  }

  Future<void> removePlaylistSong(Playlist list, Song song) async {
    if (list.isDefault) return _editLikedSong(list, song, add: false);
    await _readyApi.removePlaylistSong(list, song);
  }

  Future<List<Song>> allPlaylistSongs(Playlist list) async {
    final result = <Song>[];
    await for (final page in _playlistPages(_readyApi, list)) {
      result.addAll(page);
    }
    return result;
  }

  Stream<List<Song>> _playlistPages(
    KugouMusicApi api, Playlist list, {
    (int, String)? favoriteScope,
  }) async* {
    const pageSize = 300;
    final seen = <String>{};
    for (var page = 1; ; page++) {
      if (favoriteScope != null) _requireFavoriteScope(favoriteScope);
      final rows = await api.playlistSongs(list, page: page, pageSize: pageSize);
      if (favoriteScope != null) _requireFavoriteScope(favoriteScope);
      if (rows.isEmpty || !seen.add(rows.first.id)) break;
      yield rows;
      if (rows.length < pageSize) break;
    }
  }

  Future<ImportPreview> previewPlaylistImport(String link) =>
      PublicPlaylistImport(allPlaylistSongs).read(link);

  Future<({int added, int unmatched, int duplicates})> importPlaylist(
    ImportPreview source,
    Playlist target, {
    required void Function(int done, int total) onProgress,
    required bool Function() isOpen,
  }) async {
    final api = _readyApi;
    final session = api.client.session;
    if (session == null || !canEditPlaylist(target)) {
      throw const KugouFailure('请选择当前账号的自建歌单。');
    }
    bool canContinue() => isOpen() && identical(api.client.session, session);
    final present = (await allPlaylistSongs(target)).map((song) => song.id).toSet();
    final songs = <Song>[];
    var unmatched = 0;
    var duplicates = 0;
    var added = 0;
    for (final (index, track) in source.tracks.indexed) {
      if (!canContinue()) break;
      final match = track.song ?? await _matchImportedTrack(track);
      if (match == null || !match.playable) {
        unmatched++;
      } else if (present.add(match.id)) {
        songs.add(match);
      } else {
        duplicates++;
      }
      onProgress(index + 1, source.tracks.length);
    }
    for (var index = 0; index < songs.length && canContinue(); index += 30) {
      final batch = songs.skip(index).take(30).toList();
      try {
        await api.addPlaylistSongs(target, batch);
      } on KugouFailure catch (error) {
        throw KugouFailure(added == 0 ? error.message : '已添加 $added 首。${error.message}');
      }
      added += batch.length;
    }
    return (added: added, unmatched: unmatched, duplicates: duplicates);
  }

  Future<Song?> _matchImportedTrack(ImportTrack track) async {
    String normalize(String input) =>
        input.toLowerCase().replaceAll(RegExp(r'[\s_\-·，,、]+'), '');
    final title = normalize(track.title);
    final artists = track.artists.split(RegExp(r'[、,&/，]'))
        .map(normalize).where((name) => name.isNotEmpty).toSet();
    final results = await search('${track.title} ${track.artists}'.trim());
    return results.where((song) =>
      song.playable && normalize(song.title) == title &&
      (artists.isEmpty || song.singers.map(normalize).any(artists.contains)),
    ).firstOrNull;
  }

  Playlist? likedPlaylist(Iterable<Playlist> playlists) {
    final editable = playlists.where((item) => item.isDefault && canEditPlaylist(item));
    return editable.where((item) => item.name == '我喜欢').firstOrNull ?? editable.firstOrNull;
  }

  static (int, String)? _favoriteScope(KugouSession? session) =>
      session == null ? null : (session.userid, session.token);

  bool _ownsFavorites((int, String)? scope) => !_disposed && scope != null &&
      scope == _favoriteScope(_account.session);

  void _requireFavoriteScope((int, String) scope) {
    if (!_ownsFavorites(scope)) throw const KugouFailure('账号已变化，请重试。');
  }

  static Iterable<String> _songKeys(Song song) sync* {
    yield song.id.toUpperCase();
    if (song.albumAudioId > 0) yield 'album-audio:${song.albumAudioId}';
  }

  bool isFavorite(Song song) => _ownsFavorites(_favoriteOwner) &&
      _songKeys(song).any(_favoriteKeys.contains);

  bool favoriteBusy(Song song) =>
      _favoriteRequests.containsKey((_favoriteScope(_account.session), song.id.toUpperCase()));

  Future<Playlist> _readLikedPlaylist(KugouMusicApi api, (int, String) scope) async {
    _requireFavoriteScope(scope);
    final playlists = await api.userPlaylists(pageSize: 200);
    _requireFavoriteScope(scope);
    final liked = likedPlaylist(playlists);
    if (liked == null) throw const KugouFailure('没有找到「我喜欢」歌单。');
    return liked;
  }

  /// 和红心按钮使用同一个酷狗歌单，按页读取当前账号的全部收藏。
  Future<List<Song>> likedSongs() async {
    final scope = _favoriteScope(_account.session);
    if (scope == null) throw const KugouFailure('请先登录酷狗账号。');
    final api = _readyApi;
    final playlist = await _readLikedPlaylist(api, scope);
    return _playlistPages(api, playlist, favoriteScope: scope)
        .expand((songs) => songs).toList();
  }

  /// 同一账号的多个红心共用收藏状态和一次后台读取。
  Future<void> loadFavorites() async {
    final owner = _favoriteScope(_account.session);
    if (owner == null || _disposed || _favoritesLoaded) return;
    final existing = _favoritesLoad;
    if (existing != null) return existing;
    final pending = _favoriteCommands.synchronized(() async {
      try {
        final api = _readyApi;
        final liked = await _readLikedPlaylist(api, owner);
        final keys = <String>{};
        await for (final songs in _playlistPages(api, liked, favoriteScope: owner)) {
          keys.addAll(songs.expand(_songKeys));
        }
        if (!_ownsFavorites(owner)) return;
        _favoriteOwner = owner;
        _favoriteKeys..clear()..addAll(keys);
        _favoritesLoaded = true;
        notifyListeners();
      } on Exception {
        // 读取失败时仍可按红心重试，写入会先核对服务端歌单。
      }
    });
    _favoritesLoad = pending;
    try {
      await pending;
    } finally {
      if (identical(_favoritesLoad, pending)) _favoritesLoad = null;
    }
  }

  void _updateFavoriteKeys((int, String)? scope, Song song, bool liked, {Song? stored}) {
    if (!_ownsFavorites(scope)) return;
    _favoriteOwner = scope;
    final keys = {..._songKeys(song), if (stored != null) ..._songKeys(stored)};
    if (liked) {
      _favoriteKeys.addAll(keys);
    } else {
      _favoriteKeys.removeAll(keys);
    }
    notifyListeners();
  }

  Future<bool> toggleFavorite(Song song, {bool? favorite}) async {
    final scope = _favoriteScope(_account.session);
    if (scope == null) throw const KugouFailure('请先登录酷狗账号。');
    final key = (scope, song.id.toUpperCase());
    final existing = _favoriteRequests[key];
    if (existing != null) return existing;
    final pending = _favoriteCommands.synchronized(() => _toggleFavorite(song, scope, favorite));
    _favoriteRequests[key] = pending;
    if (!_disposed) notifyListeners();
    try {
      return await pending;
    } finally {
      _favoriteRequests.remove(key);
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _editLikedSong(Playlist list, Song song, {required bool add}) async {
    final scope = _favoriteScope(_account.session);
    if (scope == null) throw const KugouFailure('请先登录酷狗账号。');
    await _favoriteCommands.synchronized(() async {
      _requireFavoriteScope(scope);
      if (add) {
        await _readyApi.addPlaylistSong(list, song);
      } else {
        await _readyApi.removePlaylistSong(list, song);
      }
      _updateFavoriteKeys(scope, song, add);
    });
  }

  Future<bool> _toggleFavorite(Song song, (int, String) scope, bool? favorite) async {
    final api = _readyApi;
    final liked = await _readLikedPlaylist(api, scope);
    await for (final songs in _playlistPages(api, liked, favoriteScope: scope)) {
      final existing = songs.where((candidate) =>
        candidate.hash.toUpperCase() == song.hash.toUpperCase() ||
        (song.albumAudioId > 0 && candidate.albumAudioId == song.albumAudioId),
      ).firstOrNull;
      if (existing != null) {
        // 显式收藏是幂等的，后台状态尚未读完时也不会误取消已收藏的歌曲。
        if (favorite == true) {
          _updateFavoriteKeys(scope, song, true, stored: existing);
          return true;
        }
        _requireFavoriteScope(scope);
        await api.removePlaylistSong(liked, existing);
        _requireFavoriteScope(scope);
        _updateFavoriteKeys(scope, song, false, stored: existing);
        return false;
      }
    }
    if (favorite == false) {
      _updateFavoriteKeys(scope, song, false);
      return false;
    }
    final target = song.playable ? song : (await api.searchSongs(song.title)).where(
      (item) => item.playable && item.hash.toUpperCase() == song.hash.toUpperCase(),
    ).firstOrNull;
    if (target == null) throw const KugouFailure('歌曲缺少酷狗曲目编号。');
    _requireFavoriteScope(scope);
    await api.addPlaylistSong(liked, target);
    _requireFavoriteScope(scope);
    _updateFavoriteKeys(scope, song, true, stored: target);
    return true;
  }

  Future<List<Song>> playlistSongs(Playlist playlist) async =>
      await api?.playlistSongs(playlist) ?? const [];

  Future<List<Song>> dailyRecommend() async =>
      completeCovers(await api?.dailyRecommend(userid: _account.session?.userid ?? 0) ?? const []);

  /// 歌单往往只有歌曲编号。一次查询一批缺图歌曲，并复用正在查询的编号。
  Future<List<Song>> completeCovers(List<Song> songs) async {
    final missing = songs.where((song) => song.coverUrl().isEmpty).toList();
    if (missing.isEmpty) return songs;
    final albums = await _loadCovers({for (final song in missing) song.albumId}, album: true);
    final tracks = await _loadCovers({
      for (final song in missing)
        if (!albums.containsKey(song.albumId)) song.albumAudioId,
    });
    if (albums.isEmpty && tracks.isEmpty) return songs;
    return [
      for (final song in songs)
        if (albums[song.albumId] ?? tracks[song.albumAudioId] case final cover?
            when song.coverUrl().isEmpty)
          song.withCover(cover)
        else
          song,
    ];
  }

  Future<Uri?> trackCover(Track track) async {
    final cover = _cachedCover(track.albumId, track.albumAudioId) ??
        (await _loadCovers({track.albumId}, album: true))[track.albumId] ??
        (await _loadCovers({track.albumAudioId}))[track.albumAudioId];
    return _coverUri(cover ?? '');
  }

  String? _cachedCover(int albumId, int albumAudioId) =>
      _covers[(true, albumId)] ?? _covers[(false, albumAudioId)];

  Future<Map<int, String>> _loadCovers(Set<int> ids, {bool album = false}) async {
    // 保留本次列表查到的封面，长歌单中前几批可能在查询结束前被缓存淘汰。
    final covers = <int, String>{for (final id in ids) id: ?_covers[(album, id)]};
    final source = api;
    if (source == null) return covers;
    final waiting = <Future<Map<int, String>>>{
      for (final id in ids) ?_pendingCovers[(album, id)],
    };
    final missing = ids.where((id) => id > 0 &&
      !covers.containsKey(id) && !_pendingCovers.containsKey((album, id)),
    ).toList();
    const batchSize = 50;
    for (var start = 0; start < missing.length; start += batchSize) {
      final batch = missing.skip(start).take(batchSize).toList();
      final request = _fetchCovers(source, batch, album: album);
      for (final id in batch) {
        _pendingCovers[(album, id)] = request;
      }
      waiting.add(request);
    }
    for (final batch in await Future.wait(waiting)) {
      for (final entry in batch.entries) {
        if (ids.contains(entry.key)) covers[entry.key] = entry.value;
      }
    }
    return covers;
  }

  Future<Map<int, String>> _fetchCovers(KugouMusicApi source, List<int> batch, {required bool album}) async {
    try {
      final result = await (album ? source.albumCovers(batch) : source.songCovers(batch));
      for (final id in batch) {
        if (result[id] case final cover?) _covers[(album, id)] = cover;
      }
      while (_covers.length > _cacheLimit) {
        _covers.remove(_covers.keys.first);
      }
      return result;
    } on Exception {
      // 封面接口失败时保留歌曲列表，下次进入仍可重试。
      return const {};
    } finally {
      for (final id in batch) {
        _pendingCovers.remove((album, id));
      }
    }
  }

  Uri? _coverUri(String image) {
    final url = resolveCoverUrl(image, 480);
    return url.isEmpty ? null : Uri.tryParse(url);
  }

  Uri? _songCover(Song song) =>
      _coverUri(song.albumImage) ?? _coverUri(_cachedCover(song.albumId, song.albumAudioId) ?? '');

  /// 取（并缓存）播放地址。
  ///
  /// 同一首歌在当前登录会话里反复播放时可以复用已取到的地址。
  Future<SongUrl?> songUrl(
    Song song, {
    bool refresh = false,
    AudioQuality quality = AudioQuality.standard,
  }) async {
    final key = (song.id, song.albumAudioId, quality);
    final cached = _urlCache[key];
    if (!refresh && cached != null) return cached;
    final api = this.api;
    if (api == null) return null;
    final url = await api.songUrl(song, quality: quality);
    if (url != null) {
      if (_urlCache.length >= _cacheLimit) _urlCache.clear();
      _urlCache[key] = url;
    }
    return url;
  }

  /// 把歌转换成播放队列里的条目。
  ///
  /// 返回 null 表示这首拿不到地址（无版权 / 需付费），调用方据此提示用户，
  /// 不要把它塞进队列——否则队列里会出现一首永远播不出来的歌。
  Future<ResolvedTrack?> resolve(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    final url = await songUrl(song, quality: quality);
    final track = Track(
      id: song.id,
      title: song.title,
      source: url == null
          // 占位地址：队列里仍保留条目（便于收藏/查看），但不会去播。
          ? Uri.parse('https://kugou.invalid/${song.hash}')
          : Uri.parse(url.url),
      duration: song.duration,
      artist: song.artist,
      artUri: _songCover(song),
      albumAudioId: song.albumAudioId,
      albumId: song.albumId,
      audioQuality: url?.quality,
    );
    return ResolvedTrack(track: track, song: song, url: url);
  }

  /// 从最近播放重播，酷狗歌曲先用当前会话获取新的地址。
  Future<PlaybackOutcome> replay(Track track, Playback player) async {
    try {
      if (track.isCloud) {
        final session = _account.session;
        if (session == null || !track.id.startsWith('cloud:${session.userid}:')) {
          return const PlaybackOutcome.failed('请登录保存这首歌的酷狗账号。');
        }
        final seen = <String>{};
        for (var page = 1; ; page++) {
          if (!identical(_account.session, session)) break;
          final rows = await cloudTracks(page);
          final item = rows.where((row) => row.id == track.id).firstOrNull;
          if (item != null) return await playCloud(item, player);
          if (rows.length < 30 || !seen.add(rows.first.id)) break;
        }
        return const PlaybackOutcome.failed('没有找到这首云盘歌曲。');
      }
      final hash = track.kugouHash;
      if (hash == null) {
        if (track.source.scheme == 'file' && !await File.fromUri(track.source).exists()) {
          return const PlaybackOutcome.failed('这首歌的本地文件已移动或删除。');
        }
        await player.playTracks([track]);
        return const PlaybackOutcome.started();
      }
      if (_account.session == null) {
        return const PlaybackOutcome.failed('请先登录酷狗账号后再播放。');
      }

      final song = await _findCatalogTrack(track, hash);
      if (song == null) {
        return const PlaybackOutcome.failed('找不到这条历史记录对应的酷狗歌曲。');
      }
      final url = await songUrl(
        song,
        refresh: true,
        quality: player.preferredQuality.value,
      );
      if (url == null) return const PlaybackOutcome.unavailable();
      await player.playTracks([
        track.copyWith(
          source: Uri.parse(url.url),
          artUri: _coverUri(song.albumImage),
          albumAudioId: song.albumAudioId,
          albumId: song.albumId,
          audioQuality: url.quality,
        ),
      ]);
      return const PlaybackOutcome.started();
    } on KugouFailure catch (error) {
      return PlaybackOutcome.failed(error.message);
    } catch (_) {
      return const PlaybackOutcome.failed('无法重播这首歌，请检查文件或链接。');
    }
  }

  Future<Song?> _findCatalogTrack(Track track, String hash) async {
    if (track.albumAudioId > 0) {
      return Song(
        hash: hash,
        title: track.title,
        albumAudioId: track.albumAudioId,
        albumId: track.albumId,
      );
    }
    // 恢复旧队列时按哈希匹配同一个版本，再补齐专辑音频编号。
    final matches = await search(track.title);
    return matches.where(
      (item) => item.playable && item.hash.toUpperCase() == hash.toUpperCase(),
    ).firstOrNull;
  }

  /// 保存首选音质，并在当前歌曲可切换时申请新地址。
  Future<String?> changeQuality(Playback player, AudioQuality quality) async {
    final selected = player.tracks.value.elementAtOrNull(player.index);
    final hash = selected?.kugouHash;
    try {
      await player.setPreferredQuality(quality);
      if (selected == null || hash == null) return null;
      if (_account.session == null) return '请先登录酷狗账号后再切换歌曲音质。';
      final song = await _findCatalogTrack(selected, hash);
      if (song == null) return '当前歌曲缺少切换音质所需的编号。';
      final url = await songUrl(song, refresh: true, quality: quality);
      if (url == null) return '酷狗未返回可切换的播放地址。';
      if (player.preferredQuality.value != quality) return null;
      final replaced = await player.replaceCurrentSource(
        selected, Uri.parse(url.url), url.quality,
      );
      if (replaced && url.quality != quality) {
        return '酷狗返回了${url.quality.label}音质。';
      }
      return null;
    } on KugouFailure catch (error) {
      return error.message;
    } catch (_) {
      return '无法切换播放音质，请重试。';
    }
  }

  /// 先确认音源可播，再追加到队尾。已在队列中的歌曲无需重新取地址。
  Future<bool> addSongToQueue(Song song, Playback player) async {
    if (player.tracks.value.any((track) => track.id == song.id)) return false;
    final resolved = await resolve(song, quality: player.preferredQuality.value);
    if (resolved == null || resolved.blocked) {
      throw const KugouFailure('酷狗暂未返回可播放的地址，请稍后重试。');
    }
    return player.addTracks([resolved.track]);
  }

  /// 播放单曲：先取地址，再交给播放器。
  Future<PlaybackOutcome> playSong(Song song, Playback player, {bool resumeCurrent = false}) async {
    try {
      final resolved = await resolve(song, quality: player.preferredQuality.value);
      if (resolved == null || resolved.blocked) {
        return const PlaybackOutcome.unavailable();
      }
      await player.playTracks([resolved.track], resumeCurrent: resumeCurrent);
      return const PlaybackOutcome.started();
    } on KugouFailure catch (error) {
      return PlaybackOutcome.failed(error.message);
    } catch (_) {
      return PlaybackOutcome.failed('无法获取播放地址，请稍后重试。');
    }
  }

  /// 取得可播音源后替换队列；整个列表都不可播时保留原队列。
  Future<PlaybackOutcome> playAll(List<Song> songs, Playback player, {bool privateFm = false}) async {
    if (songs.isEmpty) return const PlaybackOutcome.unavailable();
    try {
      final owner = _account.session?.userid;
      final first = songs.first;
      final resolved = _resolveTracks(songs, player.preferredQuality.value);
      final seen = {for (final song in songs) song.id};
      final started = await player.replaceTracks(
        resolved.then((result) => _disposed || _account.session?.userid != owner ? const [] : result.$1),
        preview: MediaItem(
          id: first.id, title: first.title, artist: first.artist, artUri: _songCover(first),
        ),
        loadMore: privateFm && owner != null ? () => _moreFmTracks(player, owner, seen) : null,
      );
      if (!started) return const PlaybackOutcome.unavailable();
      final (_, blocked) = await resolved;
      return blocked == 0
          ? const PlaybackOutcome.started()
          : PlaybackOutcome.partial(blocked);
    } on KugouFailure catch (error) {
      return PlaybackOutcome.failed(error.message);
    } catch (_) {
      return PlaybackOutcome.failed('无法获取播放地址，请稍后重试。');
    }
  }

  Future<(List<Track>, int)> _resolveTracks(List<Song> songs, AudioQuality quality) async {
    final resolved = <Track>[];
    var blocked = 0;
    for (final song in songs) {
      final item = await resolve(song, quality: quality);
      if (item == null || item.blocked) {
        blocked++;
      } else {
        resolved.add(item.track);
      }
    }
    return (resolved, blocked);
  }

  Future<List<Track>> _moreFmTracks(Playback player, int owner, Set<String> seen) async {
    // 续播属于播放队列，离开发现页后仍能接续，也不会读到其他账号的推荐。
    bool isCurrent() => !_disposed && _account.session?.userid == owner;
    for (var batch = 0; batch < 3 && isCurrent(); batch++) {
      final songs = await personalFmSongs(excludeIds: {
        ...seen, for (final track in player.tracks.value) track.id,
      });
      if (songs.isEmpty || !isCurrent()) break;
      final (tracks, _) = await _resolveTracks(songs, player.preferredQuality.value);
      if (!isCurrent()) break;
      seen.addAll(songs.map((song) => song.id));
      if (tracks.isNotEmpty) return tracks;
    }
    return const [];
  }

  /// 已经加入队列的 [Track] 对应哪首歌，用于显示歌词。
  Future<List<LyricVersion>> lyricVersions(Song song) async =>
      await api?.lyricVersions(song) ?? const [];

  Future<String?> trackLyrics(Track track, {Duration? duration}) async {
    final hash = track.lyricHash;
    if (hash == null) return null;
    return await api?.lyrics(Song(
      hash: hash, title: track.title, duration: duration ?? track.duration,
    ));
  }

  Future<String?> downloadLyrics(LyricVersion version) async =>
      await api?.downloadLyrics(version);
}

/// 播放请求的结果。用类型而不是抛异常表达「拿不到地址」，
/// 因为这是内容侧的常态，不是程序错误。
class PlaybackOutcome {
  const PlaybackOutcome.started()
    : state = PlaybackStateKind.started,
      message = null,
      blockedCount = 0;

  const PlaybackOutcome.unavailable()
    : state = PlaybackStateKind.unavailable,
      message = null,
      blockedCount = 0;

  const PlaybackOutcome.failed(this.message)
    : state = PlaybackStateKind.failed,
      blockedCount = 0;

  const PlaybackOutcome.partial(this.blockedCount)
    : state = PlaybackStateKind.started,
      message = null;

  final PlaybackStateKind state;
  final String? message;
  final int blockedCount;

  bool get ok => state == PlaybackStateKind.started;

  /// 给用户看的一句话说明，正常开始时返回 null。
  String? get notice => switch (state) {
    PlaybackStateKind.started => blockedCount == 0
        ? null
        : '有 $blockedCount 首未取得播放地址，已跳过。',
    PlaybackStateKind.unavailable =>
      '酷狗暂未返回可播放的地址，请稍后重试。',
    PlaybackStateKind.failed => message ?? '播放失败，请稍后重试。',
  };
}

enum PlaybackStateKind { started, unavailable, failed }
