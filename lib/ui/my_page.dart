import 'package:material_ui/material_ui.dart';

import '../account/account.dart';
import '../account/account_page.dart';
import '../account/kugou/kugou_auth.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/playback.dart';
import 'appearance.dart';
import 'cover.dart';
import 'discover_page.dart';
import 'history_page.dart';
import 'import_page.dart';
import 'personal_music_page.dart';
import 'playlist_actions.dart';
import 'playlist_list_tile.dart';
import 'settings_page.dart';
import 'workspace_page.dart';

/// 「我的」页提供账号和收藏内容的入口。
class MyPage extends StatelessWidget {
  const MyPage({
    super.key,
    required this.account,
    required this.library,
    required this.player,
    this.appearance,
  });

  final Account account;
  final MusicLibrary library;
  final Playback player;
  final Appearance? appearance;

  Future<void> _openAccount(BuildContext context) => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => AccountPage(account: account, returnToMyPage: true)),
  );

  Widget _settingsTile(BuildContext context) => ListTile(
    leading: const Icon(Icons.settings_outlined),
    title: const Text('设置'),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => SettingsPage(account: account, player: player, appearance: appearance),
    )),
  );

  Future<void> _openLikedSongs(BuildContext context) => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        final session = account.session;
        if (session == null) {
          return WorkspacePage(
            title: const Text('我的喜欢'),
            body: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: _SignInPrompt(onTap: () => _openAccount(context)),
            ),
          );
        }
        return SongListPage(
          // 会话变化时重新加载，避免显示上一个账号的收藏。
          key: ObjectKey(session),
          title: '我的喜欢',
          loader: library.likedSongs,
          library: library,
          player: player,
          reloadOnFavoriteChange: true,
        );
      },
    )),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) {
      final session = account.session;
      final Widget body;
      if (account.loading || session == null) {
        // 在悬浮底栏上方的可见区域居中，小屏或大字号时仍可滚动。
        body = Padding(
          padding: pageScrollPadding(context, const EdgeInsets.symmetric(horizontal: 20)),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: account.loading
                  ? const CircularProgressIndicator()
                  : _SignInPrompt(onTap: () => _openAccount(context), label: '立即登录'),
            ),
          ),
        );
      } else {
        body = ListView(
          padding: pageScrollPadding(
            context,
            const EdgeInsets.fromLTRB(20, 16, 20, 24),
          ),
          children: [
            _AccountCard(account: account, onTap: () => _openAccount(context)),
            ListTile(
              leading: const Icon(Icons.favorite_border_rounded),
              title: const Text('我的喜欢'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openLikedSongs(context),
            ),
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: const Text('最近播放'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => HistoryPage(
                    player: player,
                    library: library,
                  ),
                ),
              ),
            ),
            for (final (cloud, label, icon) in [
              (true, '音乐云盘', Icons.cloud_outlined),
              (false, '已购音乐', Icons.shopping_bag_outlined),
            ])
              ListTile(
                leading: Icon(icon), title: Text(label),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
                  builder: (_) => PersonalMusicPage(
                    library: library, player: player, cloud: cloud,
                  ),
                )),
              ),
            ListTile(
              leading: const Icon(Icons.playlist_play_rounded),
              title: const Text('我的歌单'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
                builder: (_) => MyPlaylistsPage(account: account, library: library, player: player),
              )),
            ),
            _settingsTile(context),
          ],
        );
      }
      return body;
    },
  );
}

/// 桌面侧栏和手机「我的」共用歌单列表及管理操作。
class MyPlaylistsPage extends StatefulWidget {
  const MyPlaylistsPage({
    super.key, required this.account, required this.library, required this.player,
  });

  final Account account;
  final MusicLibrary library;
  final Playback player;

  @override
  State<MyPlaylistsPage> createState() => _MyPlaylistsPageState();
}

class _MyPlaylistsPageState extends State<MyPlaylistsPage> {
  List<Playlist> _playlists = const [];
  bool _loading = false;
  String? _error;

  /// 换账号或重新登录后，只显示当前会话返回的歌单。
  (int, String)? _loadedFor;
  int _loadAttempt = 0;

  @override
  void initState() {
    super.initState();
    widget.account.addListener(_onAccountChanged);
    _onAccountChanged();
  }

  @override
  void dispose() {
    widget.account.removeListener(_onAccountChanged);
    super.dispose();
  }

  void _onAccountChanged() {
    final session = widget.account.session;
    final owner = session == null ? null : (session.userid, session.token);
    if (owner == _loadedFor) {
      // 只是刷新昵称之类的变化，不必重拉歌单。
      if (mounted) setState(() {});
      return;
    }
    _loadedFor = owner;
    _playlists = const [];
    if (owner == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _load();
  }

  Future<void> _load() async {
    final session = widget.account.session;
    if (session == null) return;
    final attempt = ++_loadAttempt;
    bool isCurrent() => mounted && _loadAttempt == attempt &&
        widget.account.session?.userid == session.userid &&
        widget.account.session?.token == session.token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final playlists = await widget.library.myPlaylists();
      if (!isCurrent()) return;
      setState(() {
        _playlists = playlists;
        _loading = false;
      });
    } on KugouFailure catch (error) {
      if (!isCurrent()) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } on Object {
      if (!isCurrent()) return;
      setState(() {
        _loading = false;
        _error = '加载歌单失败，请稍后重试。';
      });
    }
  }

  Future<void> _openAccount() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AccountPage(account: widget.account),
      ),
    );
  }

  Future<void> _openPlaylist(Playlist playlist) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SongListPage(
          title: playlist.name,
          subtitle: playlist.songCount > 0 ? '${playlist.songCount} 首' : null,
          loader: () => widget.library.playlistSongs(playlist),
          player: widget.player,
          library: widget.library,
          playlist: playlist,
          cover: playlist.cover,
          description: playlist.description,
        ),
      ),
    );
  }

  Future<void> _editPlaylist([Playlist? playlist]) async {
    if (await showPlaylistEditor(context, widget.library, playlist: playlist) && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = widget.account.session != null;
    final status = signedIn
        ? _playlistStatus(Theme.of(context))
        : Padding(
            padding: const EdgeInsets.only(top: 24),
            child: _SignInPrompt(onTap: _openAccount),
          );
    return WorkspacePage(
      title: const Text('我的歌单'),
      actions: [
        if (signedIn) ...[
          IconButton(
            tooltip: '新建歌单',
            icon: const Icon(Icons.playlist_add_rounded),
            onPressed: _loading ? null : () => _editPlaylist(),
          ),
          IconButton(
            tooltip: '导入歌单',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => ImportPlaylistPage(library: widget.library),
            )).then((_) { if (mounted) _load(); }),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ],
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.fromLTRB(16, 0, 16, 20)),
            itemCount: status == null ? _playlists.length : 1,
            itemBuilder: (context, index) {
              if (status != null) return status;
              final playlist = _playlists[index];
              return PlaylistListTile(
                playlist: playlist,
                subtitle: playlist.songCount > 0 ? '${playlist.songCount} 首' : null,
                onTap: () => _openPlaylist(playlist),
                onEdit: !playlist.isDefault && widget.library.canEditPlaylist(playlist)
                    ? () => _editPlaylist(playlist)
                    : null,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget? _playlistStatus(ThemeData theme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error case final error?) {
      return Column(
        children: [
          const SizedBox(height: 16),
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton.tonal(onPressed: _load, child: const Text('重试')),
        ],
      );
    }
    if (_playlists.isNotEmpty) return null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Text(
        '这个账号还没有歌单。点击「新建歌单」开始。',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.onTap});

  final Account account;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: account,
        builder: (context, _) {
          final current = account.session;
          return ListTile(
            onTap: onTap,
            contentPadding: const EdgeInsets.all(12),
            leading: Cover(
              url: current?.avatar ?? '',
              size: 52,
              radius: 26,
              icon: Icons.person_rounded,
            ),
            title: Text(
              current?.nickname ?? '未登录',
              style: theme.textTheme.titleMedium,
            ),
            subtitle: Text(
              current == null
                  ? '点击登录酷狗账号，解锁歌单与高音质'
                  : 'UID ${current.userid}${current.vipType > 0 ? ' · VIP' : ''}',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
          );
        },
      ),
    );
  }
}

class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt({required this.onTap, this.label = '去登录'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.headphones_rounded,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Text('登录后可以同步歌单', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          '登录还能拿到更高音质的播放链接，以及按口味生成的每日推荐。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: onTap, child: Text(label)),
      ],
    );
  }
}

/// 供外部复用的空状态。
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleLarge),
            if (message case final message?) ...[
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action case final action?) ...[
              const SizedBox(height: 16),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
