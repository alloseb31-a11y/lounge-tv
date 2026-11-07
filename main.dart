import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:xml/xml.dart';

extension FirstOrNullX<T> on Iterable<T> { T? get firstOrNull => isEmpty ? null : first; }

void main() => runApp(const LoungeTvApp());

const navy = Color(0xFF090909);
const panel = Color(0xFF191516);
const accent = Color(0xFFB51F32);
const gold = Color(0xFFD6AE55);

class LoungeTvApp extends StatelessWidget {
  const LoungeTvApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Lounge Tv',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: navy,
          colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(secondary: gold, tertiary: gold),
          useMaterial3: true,
          cardColor: panel,
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: panel,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
        home: const HomePage(),
      );
}

enum ContentKind { live, movie, series, episode }

class IptvItem {
  IptvItem({required this.id, required this.name, required this.url, required this.kind,
    this.group = 'Autres', this.logo = '', this.epgId = '', this.description = ''});
  final String id, name, url, group, logo, epgId, description;
  final ContentKind kind;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'kind': kind.name,
    'group': group, 'logo': logo, 'epgId': epgId, 'description': description};
  factory IptvItem.fromJson(Map<String, dynamic> j) => IptvItem(
    id: j['id'] ?? '', name: j['name'] ?? 'Sans nom', url: j['url'] ?? '',
    kind: ContentKind.values.firstWhere((e) => e.name == j['kind'], orElse: () => ContentKind.live),
    group: j['group'] ?? 'Autres', logo: j['logo'] ?? '', epgId: j['epgId'] ?? '', description: j['description'] ?? '');
}

class Programme {
  Programme({required this.channelId, required this.title, required this.start, required this.end, this.description = ''});
  final String channelId, title, description;
  final DateTime start, end;
}

class XtreamConfig {
  XtreamConfig(this.host, this.username, this.password);
  final String host, username, password;
}

class IptvRepository {
  final List<IptvItem> items = [];
  final List<Programme> programmes = [];
  final Set<String> favorites = {};
  final Map<String, int> progressMs = {};
  String playlistName = 'Ma playlist';
  String? epgUrl;
  XtreamConfig? xtreamConfig;

  Future<void> restore() async {
    final p = await SharedPreferences.getInstance();
    playlistName = p.getString('playlistName') ?? playlistName;
    final raw = p.getString('items');
    if (raw != null) {
      try { items.addAll((jsonDecode(raw) as List).map((e) => IptvItem.fromJson(Map<String, dynamic>.from(e)))); } catch (_) {}
    }
    favorites.addAll(p.getStringList('favorites') ?? []);
    final progress = p.getString('progress');
    if (progress != null) {
      try { (jsonDecode(progress) as Map<String, dynamic>).forEach((k, v) => progressMs[k] = v as int); } catch (_) {}
    }
    epgUrl = p.getString('epgUrl');
  }

  Future<void> persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('playlistName', playlistName);
    await p.setString('items', jsonEncode(items.map((e) => e.toJson()).toList()));
    await p.setStringList('favorites', favorites.toList());
    await p.setString('progress', jsonEncode(progressMs));
    if (epgUrl != null) await p.setString('epgUrl', epgUrl!);
  }

  Future<int> loadM3u(String source, {bool isUrl = true}) async {
    final text = isUrl ? (await http.get(Uri.parse(source)).timeout(const Duration(seconds: 25))).body : source;
    final parsed = M3uParser.parse(text);
    if (parsed.isEmpty) throw Exception('Aucun flux reconnu dans cette playlist.');
    items
      ..clear()
      ..addAll(parsed);
    await persist();
    return parsed.length;
  }

  Future<int> loadXtream(XtreamConfig c) async {
    xtreamConfig = c;
    final host = c.host.replaceAll(RegExp(r'/+$'), '');
    final base = '$host/player_api.php?username=${Uri.encodeQueryComponent(c.username)}&password=${Uri.encodeQueryComponent(c.password)}';
    final client = http.Client();
    try {
      final responses = await Future.wait([
        client.get(Uri.parse('$base&action=get_live_streams')),
        client.get(Uri.parse('$base&action=get_vod_streams')),
        client.get(Uri.parse('$base&action=get_series')),
      ]).timeout(const Duration(seconds: 30));
      final result = <IptvItem>[];
      for (var i = 0; i < responses.length; i++) {
        if (responses[i].statusCode != 200) continue;
        final decoded = jsonDecode(responses[i].body);
        if (decoded is! List) continue;
        for (final row in decoded) {
          if (row is! Map) continue;
          final id = '${row['stream_id'] ?? row['series_id'] ?? ''}';
          if (id.isEmpty) continue;
          final kind = i == 0 ? ContentKind.live : (i == 1 ? ContentKind.movie : ContentKind.series);
          final ext = '${row['container_extension'] ?? 'ts'}';
          final path = kind == ContentKind.live ? 'live' : (kind == ContentKind.movie ? 'movie' : 'series');
          final url = '$host/$path/${Uri.encodeComponent(c.username)}/${Uri.encodeComponent(c.password)}/$id${kind == ContentKind.series ? '' : '.$ext'}';
          result.add(IptvItem(id: '${kind.name}_$id', name: '${row['name'] ?? row['title'] ?? 'Sans titre'}', url: url,
            kind: kind, group: '${row['category_name'] ?? kind.name}', logo: '${row['stream_icon'] ?? row['cover'] ?? ''}',
            description: '${row['plot'] ?? ''}'));
        }
      }
      if (result.isEmpty) throw Exception('Aucun contenu reçu. Vérifie les identifiants et l’adresse du serveur.');
      items..clear()..addAll(result);
      await persist();
      return result.length;
    } finally { client.close(); }
  }

  Future<List<IptvItem>> loadSeriesEpisodes(IptvItem series) async {
    final c = xtreamConfig;
    if (c == null) throw Exception('Reconnecte ton fournisseur Xtream Codes pour charger les épisodes.');
    final seriesId = series.id.replaceFirst('series_', '');
    final uri = Uri.parse('${c.host.replaceAll(RegExp(r'/+$'), '')}/player_api.php')
        .replace(queryParameters: {'username': c.username, 'password': c.password, 'action': 'get_series_info', 'series_id': seriesId});
    final response = await http.get(uri).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw Exception('Le fournisseur ne répond pas (${response.statusCode}).');
    final body = jsonDecode(response.body);
    if (body is! Map || body['episodes'] is! Map) throw Exception('Aucun épisode retourné pour cette série.');
    final episodes = <IptvItem>[];
    final seasons = body['episodes'] as Map;
    for (final season in seasons.values) {
      if (season is! List) continue;
      for (final raw in season) {
        if (raw is! Map) continue;
        final id = '${raw['id'] ?? ''}';
        if (id.isEmpty) continue;
        final ext = '${raw['container_extension'] ?? 'mp4'}';
        final name = '${raw['title'] ?? raw['name'] ?? 'Épisode'}';
        final cover = raw['info'] is Map ? '${raw['info']['movie_image'] ?? ''}' : '';
        final url = '${c.host.replaceAll(RegExp(r'/+$'), '')}/series/${Uri.encodeComponent(c.username)}/${Uri.encodeComponent(c.password)}/$id.$ext';
        episodes.add(IptvItem(id: 'episode_$id', name: name, url: url, kind: ContentKind.episode,
          group: series.name, logo: cover, description: raw['info'] is Map ? '${raw['info']['plot'] ?? ''}' : ''));
      }
    }
    if (episodes.isEmpty) throw Exception('Aucun épisode disponible.');
    return episodes;
  }

  Future<int> loadEpg(String url) async {
    final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw Exception('Impossible de télécharger le guide TV (${response.statusCode}).');
    final document = XmlDocument.parse(response.body);
    final parsed = <Programme>[];
    for (final node in document.findAllElements('programme')) {
      final start = _xmlDate(node.getAttribute('start'));
      final end = _xmlDate(node.getAttribute('stop'));
      if (start == null || end == null) continue;
      final title = node.findElements('title').firstOrNull?.innerText.trim() ?? '';
      if (title.isEmpty) continue;
      parsed.add(Programme(channelId: node.getAttribute('channel') ?? '', title: title,
        start: start, end: end, description: node.findElements('desc').firstOrNull?.innerText.trim() ?? ''));
    }
    programmes..clear()..addAll(parsed);
    epgUrl = url;
    await persist();
    return parsed.length;
  }

  DateTime? _xmlDate(String? raw) {
    if (raw == null) return null;
    try {
      final match = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?').firstMatch(raw);
      if (match == null) return DateTime.parse(raw);
      return DateTime(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!),
        int.parse(match[4]!), int.parse(match[5]!), int.parse(match[6] ?? '0'));
    } catch (_) { return null; }
  }
}

class M3uParser {
  static List<IptvItem> parse(String input) {
    final lines = const LineSplitter().convert(input);
    final out = <IptvItem>[];
    String? meta;
    for (final line in lines) {
      final l = line.trim();
      if (l.startsWith('#EXTINF')) { meta = l; continue; }
      if (l.isEmpty || l.startsWith('#') || meta == null) continue;
      final name = meta.split(',').length > 1 ? meta.substring(meta.indexOf(',') + 1).trim() : 'Chaîne';
      String attr(String key) => RegExp('$key="([^"]*)"').firstMatch(meta!)?.group(1) ?? '';
      final group = attr('group-title').isEmpty ? 'Autres' : attr('group-title');
      final logo = attr('tvg-logo');
      final epg = attr('tvg-id');
      final kind = _kind(group, name, l);
      final id = '${name}_${l.hashCode}';
      out.add(IptvItem(id: id, name: name, url: l, kind: kind, group: group, logo: logo, epgId: epg));
      meta = null;
    }
    return out;
  }
  static ContentKind _kind(String group, String name, String url) {
    final s = '$group $name $url'.toLowerCase();
    if (s.contains('series') || s.contains('série') || s.contains('season')) return ContentKind.series;
    if (s.contains('vod') || s.contains('film') || s.contains('movie')) return ContentKind.movie;
    return ContentKind.live;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final repo = IptvRepository();
  int tab = 0;
  bool loading = true;
  String search = '';
  String category = 'Toutes';
  String status = '';
  IptvItem? playing;
  VideoPlayerController? player;
  bool playerLoading = false;
  final tabs = const ['Accueil', 'En direct', 'Films', 'Séries', 'Favoris', 'Guide TV'];
  @override void initState() { super.initState(); _init(); }
  Future<void> _init() async { await repo.restore(); if (mounted) setState(() => loading = false); }
  @override void dispose() { player?.dispose(); super.dispose(); }

  List<IptvItem> get visibleItems {
    final kind = switch (tab) { 1 => ContentKind.live, 2 => ContentKind.movie, 3 => ContentKind.series, _ => null };
    return repo.items.where((e) {
      final matchKind = tab == 4 ? repo.favorites.contains(e.id) : (kind == null || e.kind == kind);
      return matchKind && (search.isEmpty || e.name.toLowerCase().contains(search.toLowerCase())) &&
        (category == 'Toutes' || e.group == category);
    }).toList();
  }

  void notify(String message) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message))); }
  Future<void> toggleFavorite(IptvItem item) async { setState(() { repo.favorites.contains(item.id) ? repo.favorites.remove(item.id) : repo.favorites.add(item.id); }); await repo.persist(); }

  Future<void> play(IptvItem item) async {
    if (item.kind == ContentKind.series) { await _chooseSeriesEpisode(item); return; }
    setState(() { playing = item; playerLoading = true; });
    await player?.dispose();
    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(item.url));
      player = controller;
      await controller.initialize().timeout(const Duration(seconds: 20));
      final saved = repo.progressMs[item.id] ?? 0;
      if (saved > 0 && item.kind != ContentKind.live) await controller.seekTo(Duration(milliseconds: saved));
      await controller.play();
      controller.addListener(() {
        if (!mounted || playing?.id != item.id) return;
        final pos = controller.value.position.inMilliseconds;
        if (item.kind != ContentKind.live && pos > 0) { repo.progressMs[item.id] = pos; repo.persist(); }
        if (mounted) setState(() {});
      });
    } catch (e) { notify('Lecture impossible : $e'); }
    if (mounted) setState(() => playerLoading = false);
  }

  Future<void> _chooseSeriesEpisode(IptvItem series) async {
    try {
      setState(() => status = 'Chargement des épisodes…');
      final episodes = await repo.loadSeriesEpisodes(series);
      if (!mounted) return;
      setState(() => status = '');
      final selected = await showModalBottomSheet<IptvItem>(context: context, isScrollControlled: true, backgroundColor: panel,
        builder: (ctx) => SafeArea(child: SizedBox(height: MediaQuery.sizeOf(ctx).height * .72, child: Column(children: [
          Padding(padding: const EdgeInsets.all(18), child: Row(children: [const Icon(Icons.video_library), const SizedBox(width: 10), Expanded(child: Text(series.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)))])),
          Expanded(child: ListView.builder(itemCount: episodes.length, itemBuilder: (_, i) { final ep = episodes[i]; return ListTile(leading: const Icon(Icons.play_circle_outline), title: Text(ep.name), subtitle: Text(ep.group), onTap: () => Navigator.pop(ctx, ep)); }))
        ]))));
      if (selected != null) await play(selected);
    } catch (e) { if (mounted) { setState(() => status = ''); notify('Impossible de charger les épisodes : $e'); } }
  }

  Future<void> openPlaylistDialog() async {
    final url = TextEditingController(); final name = TextEditingController(text: 'Ma playlist');
    final result = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Ajouter une playlist M3U'), content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom de la playlist')),
        const SizedBox(height: 12), TextField(controller: url, decoration: const InputDecoration(labelText: 'URL M3U', hintText: 'https://…'), keyboardType: TextInputType.url),
        const SizedBox(height: 8), const Text('Utilise uniquement une playlist et des flux auxquels tu es autorisé à accéder.', style: TextStyle(fontSize: 11, color: Colors.white60)),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Importer'))]));
    if (result != true) return;
    setState(() => status = 'Importation de la playlist…');
    try { final n = await repo.loadM3u(url.text.trim()); repo.playlistName = name.text.trim().isEmpty ? 'Ma playlist' : name.text.trim(); await repo.persist(); setState(() => status = '$n contenus importés.'); }
    catch (e) { setState(() => status = 'Erreur : $e'); }
  }

  Future<void> openXtreamDialog() async {
    final host = TextEditingController(), user = TextEditingController(), pass = TextEditingController();
    final result = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Connexion Xtream Codes'), content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: host, decoration: const InputDecoration(labelText: 'Adresse du serveur', hintText: 'https://serveur.example')),
        TextField(controller: user, decoration: const InputDecoration(labelText: 'Nom d’utilisateur')),
        TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Mot de passe')),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Connecter'))]));
    if (result != true) return;
    setState(() => status = 'Connexion au fournisseur…');
    try { final n = await repo.loadXtream(XtreamConfig(host.text.trim(), user.text.trim(), pass.text)); setState(() => status = '$n contenus importés.'); }
    catch (e) { setState(() => status = 'Erreur : $e'); }
  }

  Future<void> importFile() async {
    final f = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['m3u', 'm3u8'], withData: true);
    if (f == null || f.files.single.bytes == null) return;
    try { final n = await repo.loadM3u(utf8.decode(f.files.single.bytes!), isUrl: false); setState(() => status = '$n contenus importés.'); }
    catch (e) { setState(() => status = 'Erreur : $e'); }
  }

  Future<void> openEpgDialog() async {
    final url = TextEditingController(text: repo.epgUrl ?? '');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Guide TV XMLTV'),
      content: TextField(controller: url, decoration: const InputDecoration(labelText: 'URL du fichier XMLTV')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Charger'))]));
    if (ok != true) return;
    try { final n = await repo.loadEpg(url.text.trim()); setState(() => status = '$n programmes chargés.'); }
    catch (e) { setState(() => status = 'Erreur EPG : $e'); }
  }

  @override Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final wide = MediaQuery.sizeOf(context).width >= 850;
    return Scaffold(body: SafeArea(child: Row(children: [
      if (wide) _sidebar(),
      Expanded(child: Column(children: [
        _topbar(wide),
        Expanded(child: tab == 0 ? _home() : (tab == 5 ? _epg() : _catalogue())),
      ])),
    ])));
  }

  Widget _sidebar() => Container(width: 220, color: const Color(0xFF120D0F), padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _brand(), const SizedBox(height: 32), ...List.generate(tabs.length, (i) => _navButton(i)), const Spacer(),
    Text(repo.playlistName, style: const TextStyle(color: Colors.white54, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
    const SizedBox(height: 12), _settingsButton(),
  ]));

  Widget _brand() => Row(children: [Container(width: 38, height: 38, decoration: BoxDecoration(color: const Color(0xFF32131A), border: Border.all(color: gold, width: 1.2), borderRadius: BorderRadius.circular(11)), child: const Icon(Icons.play_arrow_rounded, size: 28)),
    const SizedBox(width: 10), const Text('Lounge Tv', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.1, color: gold))]);

  Widget _topbar(bool wide) => Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF1C2A3D)))), child: Row(children: [
    if (!wide) ...[_brand(), const SizedBox(width: 20)],
    if (!wide) Expanded(child: DropdownButton<int>(value: tab, isExpanded: true, underline: const SizedBox(), items: List.generate(tabs.length, (i) => DropdownMenuItem(value: i, child: Text(tabs[i]))), onChanged: (v) => setState(() => tab = v ?? 0))),
    if (wide) Text(tabs[tab], style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
    const Spacer(), IconButton(tooltip: 'Rechercher', onPressed: () => setState(() { if (tab == 0) tab = 1; }), icon: const Icon(Icons.search)),
    IconButton(tooltip: 'Paramètres', onPressed: _settings, icon: const Icon(Icons.settings_outlined)),
  ]));

  Widget _navButton(int i) => Padding(padding: const EdgeInsets.only(bottom: 6), child: InkWell(onTap: () => setState(() => tab = i), borderRadius: BorderRadius.circular(10), child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), decoration: BoxDecoration(color: tab == i ? accent.withOpacity(.18) : Colors.transparent, borderRadius: BorderRadius.circular(10)), child: Row(children: [Icon([Icons.home_outlined, Icons.live_tv_outlined, Icons.movie_outlined, Icons.video_library_outlined, Icons.favorite_border, Icons.calendar_month_outlined][i], color: tab == i ? const Color(0xFF72A9FF) : Colors.white60, size: 19), const SizedBox(width: 12), Text(tabs[i], style: TextStyle(color: tab == i ? Colors.white : Colors.white70, fontWeight: tab == i ? FontWeight.bold : FontWeight.normal))]))));

  Widget _settingsButton() => OutlinedButton.icon(onPressed: _settings, icon: const Icon(Icons.add), label: const Text('Ajouter une playlist'));
  void _settings() => showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: panel, builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.all(22), child: Wrap(runSpacing: 12, children: [
    const Text('Sources et paramètres', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
    ListTile(leading: const Icon(Icons.link), title: const Text('Importer une URL M3U'), onTap: () { Navigator.pop(ctx); openPlaylistDialog(); }),
    ListTile(leading: const Icon(Icons.file_open), title: const Text('Importer un fichier M3U'), onTap: () { Navigator.pop(ctx); importFile(); }),
    ListTile(leading: const Icon(Icons.cloud_outlined), title: const Text('Connexion Xtream Codes'), onTap: () { Navigator.pop(ctx); openXtreamDialog(); }),
    ListTile(leading: const Icon(Icons.calendar_month), title: const Text('Configurer le guide TV EPG'), onTap: () { Navigator.pop(ctx); openEpgDialog(); }),
    if (status.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(status, style: const TextStyle(color: Colors.lightBlueAccent))),
  ]))));

  Widget _home() => ListView(padding: const EdgeInsets.all(22), children: [
    Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: const LinearGradient(colors: [Color(0xFF49151F), Color(0xFF191516)], begin: Alignment.topLeft, end: Alignment.bottomRight)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('VOTRE UNIVERS DE DIVERTISSEMENT', style: TextStyle(color: gold, fontSize: 11, letterSpacing: 1.5)), const SizedBox(height: 12),
      const Text('Bienvenue sur Lounge Tv.', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)), const SizedBox(height: 8),
      Text(repo.items.isEmpty ? 'Ajoutez votre playlist pour commencer.' : '${repo.items.length} contenus dans ${repo.playlistName}', style: const TextStyle(color: Colors.white70)), const SizedBox(height: 18),
      FilledButton.icon(onPressed: _settings, icon: const Icon(Icons.add), label: const Text('Configurer mon IPTV')),
    ])),
    if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(status, style: const TextStyle(color: Colors.lightBlueAccent))),
    const SizedBox(height: 24), const Text('Explorer', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)), const SizedBox(height: 12),
    LayoutBuilder(builder: (context, c) { final count = c.maxWidth > 900 ? 4 : (c.maxWidth > 500 ? 2 : 1); return GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: count, childAspectRatio: 2.1, crossAxisSpacing: 12, mainAxisSpacing: 12, children: [
      _homeCard('TV en direct', Icons.live_tv, 1, '${repo.items.where((e) => e.kind == ContentKind.live).length} chaînes'),
      _homeCard('Films', Icons.movie, 2, '${repo.items.where((e) => e.kind == ContentKind.movie).length} films'),
      _homeCard('Séries', Icons.video_library, 3, '${repo.items.where((e) => e.kind == ContentKind.series).length} séries'),
      _homeCard('Favoris', Icons.favorite, 4, '${repo.favorites.length} contenus'),
    ]); }),
    const SizedBox(height: 24), const Text('Reprendre la lecture', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)), const SizedBox(height: 12),
    ...repo.items.where((e) => (repo.progressMs[e.id] ?? 0) > 0).take(5).map((e) => ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.play_circle_outline), title: Text(e.name), subtitle: Text(_duration(repo.progressMs[e.id] ?? 0)), onTap: () => play(e))),
    if (!repo.items.any((e) => (repo.progressMs[e.id] ?? 0) > 0)) const Text('Les films et épisodes commencés apparaîtront ici.', style: TextStyle(color: Colors.white54)),
  ]);

  Widget _homeCard(String title, IconData icon, int index, String subtitle) => InkWell(onTap: () => setState(() => tab = index), borderRadius: BorderRadius.circular(14), child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: panel, border: Border.all(color: const Color(0xFF493139)), borderRadius: BorderRadius.circular(14)), child: Row(children: [Icon(icon, color: gold, size: 28), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.bold)), Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11))]))])));

  Widget _catalogue() {
    final list = visibleItems;
    final groups = repo.items.where((e) => tab == 4 ? repo.favorites.contains(e.id) : e.kind == (tab == 1 ? ContentKind.live : tab == 2 ? ContentKind.movie : ContentKind.series)).map((e) => e.group).toSet().toList()..sort();
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 8), child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Rechercher un contenu…'), onChanged: (v) => setState(() => search = v))),
      if (tab != 4) SizedBox(height: 48, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: ['Toutes', ...groups].map((g) => Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(g), selected: category == g, onSelected: (_) => setState(() => category = g))).toList())),
      Expanded(child: list.isEmpty ? _emptyState() : LayoutBuilder(builder: (context, c) {
        final grid = tab == 2 || tab == 3 || c.maxWidth > 700;
        if (!grid) return ListView.builder(itemCount: list.length, itemBuilder: (_, i) => _listTile(list[i]));
        final count = c.maxWidth > 1100 ? 6 : (c.maxWidth > 750 ? 4 : 2);
        return GridView.builder(padding: const EdgeInsets.all(18), gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: count, childAspectRatio: .76, crossAxisSpacing: 14, mainAxisSpacing: 14), itemCount: list.length, itemBuilder: (_, i) => _poster(list[i]));
      })),
      if (playing != null) _miniPlayer(),
    ]);
  }

  Widget _emptyState() => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.playlist_add, size: 48, color: Colors.white38), const SizedBox(height: 12), const Text('Aucun contenu à afficher', style: TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 6), const Text('Ajoute une playlist M3U ou connecte ton fournisseur Xtream Codes.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)), const SizedBox(height: 14), FilledButton(onPressed: _settings, child: const Text('Ajouter une source'))])));

  Widget _listTile(IptvItem item) => ListTile(leading: _logo(item, 46), title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(item.group, style: const TextStyle(color: Colors.white54)), trailing: Row(mainAxisSize: MainAxisSize.min, children: [_favoriteButton(item), IconButton(onPressed: () => play(item), icon: const Icon(Icons.play_circle_fill, color: Color(0xFF78AFFF)))]), onTap: () => play(item));
  Widget _poster(IptvItem item) => InkWell(onTap: () => play(item), borderRadius: BorderRadius.circular(13), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Stack(fit: StackFit.expand, children: [ClipRRect(borderRadius: BorderRadius.circular(12), child: item.logo.isNotEmpty ? Image.network(item.logo, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _posterPlaceholder(item)) : _posterPlaceholder(item)), Positioned(top: 6, right: 6, child: _favoriteButton(item)), const Center(child: Icon(Icons.play_circle_fill, size: 42, color: Colors.white70))])), const SizedBox(height: 8), Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)), Text(item.group, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 11))]));
  Widget _posterPlaceholder(IptvItem item) => Container(color: const Color(0xFF2A1B1E), child: Center(child: Icon(item.kind == ContentKind.movie ? Icons.movie : Icons.live_tv, size: 42, color: Colors.white38)));
  Widget _logo(IptvItem item, double size) => ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: size, height: size, child: item.logo.isEmpty ? Container(color: panel, child: const Icon(Icons.tv)) : Image.network(item.logo, fit: BoxFit.contain, errorBuilder: (_, __, ___) => Container(color: panel, child: const Icon(Icons.tv)))));
  Widget _favoriteButton(IptvItem item) => IconButton(visualDensity: VisualDensity.compact, onPressed: () => toggleFavorite(item), icon: Icon(repo.favorites.contains(item.id) ? Icons.favorite : Icons.favorite_border, color: repo.favorites.contains(item.id) ? Colors.pinkAccent : Colors.white70, size: 20));

  Widget _miniPlayer() => Container(color: panel, padding: const EdgeInsets.all(12), child: Row(children: [const Icon(Icons.equalizer, color: accent), const SizedBox(width: 10), Expanded(child: Text(playing!.name, maxLines: 1, overflow: TextOverflow.ellipsis)), if (playerLoading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) else IconButton(onPressed: () => setState(() { player?.value.isPlaying == true ? player?.pause() : player?.play(); }), icon: Icon(player?.value.isPlaying == true ? Icons.pause : Icons.play_arrow)), IconButton(onPressed: () => _openPlayer(), icon: const Icon(Icons.open_in_full))]));

  void _openPlayer() => showDialog(context: context, builder: (ctx) => Dialog.fullscreen(child: SafeArea(child: Column(children: [Row(children: [IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)), Expanded(child: Text(playing?.name ?? 'Lecteur', style: const TextStyle(fontWeight: FontWeight.bold)))]), Expanded(child: Center(child: playerLoading ? const CircularProgressIndicator() : (player?.value.isInitialized == true ? AspectRatio(aspectRatio: player!.value.aspectRatio, child: VideoPlayer(player!)) : const Text('Aucun flux vidéo chargé.')))), if (player?.value.isInitialized == true) VideoProgressIndicator(player!, allowScrubbing: true), Row(mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(onPressed: () => player?.seekTo(player!.value.position - const Duration(seconds: 10)), icon: const Icon(Icons.replay_10)), IconButton(onPressed: () => setState(() { player!.value.isPlaying ? player!.pause() : player!.play(); }), icon: Icon(player?.value.isPlaying == true ? Icons.pause_circle : Icons.play_circle, size: 42)), IconButton(onPressed: () => player?.seekTo(player!.value.position + const Duration(seconds: 10)), icon: const Icon(Icons.forward_10))]), const SizedBox(height: 16)]))));

  Widget _epg() {
    final now = DateTime.now();
    final live = repo.items.where((e) => e.kind == ContentKind.live).toList();
    return Column(children: [Padding(padding: const EdgeInsets.all(18), child: Row(children: [const Expanded(child: Text('Guide des programmes', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))), TextButton.icon(onPressed: openEpgDialog, icon: const Icon(Icons.refresh), label: const Text('Charger EPG'))])),
      Expanded(child: live.isEmpty ? _emptyState() : ListView.builder(itemCount: live.length, itemBuilder: (_, i) {
        final channel = live[i];
        final entries = repo.programmes.where((p) => p.channelId == channel.epgId || p.channelId == channel.id).toList()..sort((a,b) => a.start.compareTo(b.start));
        final current = entries.where((p) => p.start.isBefore(now) && p.end.isAfter(now)).firstOrNull;
        final next = entries.where((p) => p.start.isAfter(now)).firstOrNull;
        return Card(color: panel, margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5), child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [_logo(channel, 48), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(channel.name, style: const TextStyle(fontWeight: FontWeight.bold)), if (current != null) Text('EN COURS · ${DateFormat.Hm().format(current.start)} — ${current.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF86B5FF), fontSize: 12)) else const Text('Programme non disponible', style: TextStyle(color: Colors.white54, fontSize: 12)), if (next != null) Text('À SUIVRE · ${DateFormat.Hm().format(next.start)} — ${next.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 11))])), IconButton(onPressed: () => play(channel), icon: const Icon(Icons.play_arrow))])));
      }))]);
  }

  String _duration(int ms) { final d = Duration(milliseconds: ms); return 'Reprendre à ${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}'; }
}
