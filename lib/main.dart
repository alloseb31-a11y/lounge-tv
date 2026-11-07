import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

// ---------------------------------------------------------------------------
// Palette rouge et or
// ---------------------------------------------------------------------------

const Color kBlack = Color(0xFF0A0406);
const Color kRed = Color(0xFF9B111E);
const Color kGold = Color(0xFFD4AF37);
const Color kGoldLight = Color(0xFFF3DC8A);
const Color kGoldDark = Color(0xFF9C7A1E);
const Color kPanel = Color(0xFF241015);

const LinearGradient kGoldGradient = LinearGradient(
colors: [kGoldLight, kGold, kGoldDark],
begin: Alignment.topLeft,
end: Alignment.bottomRight,
);

const String kPlayerAgent = 'VLC/3.0.20 LibVLC/3.0.20';

void main() {
WidgetsFlutterBinding.ensureInitialized();
runApp(const LoungeApp());
}

class LoungeApp extends StatelessWidget {
const LoungeApp({super.key});

@override
Widget build(BuildContext context) {
return MaterialApp(
title: 'Lounge Tv',
debugShowCheckedModeBanner: false,
theme: ThemeData(
useMaterial3: true,
brightness: Brightness.dark,
scaffoldBackgroundColor: kBlack,
colorScheme: const ColorScheme.dark(
primary: kGold,
onPrimary: kBlack,
secondary: kRed,
surface: kBlack,
),
textSelectionTheme: const TextSelectionThemeData(cursorColor: kGold),
),
home: const Gate(),
);
}
}

// ---------------------------------------------------------------------------
// Modèles
// ---------------------------------------------------------------------------

class Item {
final String name;
final String url;
final String alt;
final String logo;
final String group;
final String kind; // live, movie, series
final int? seriesId;

const Item({
required this.name,
this.url = '',
this.alt = '',
this.logo = '',
this.group = 'Divers',
this.kind = 'live',
this.seriesId,
});

String get key {
if (kind == 'series' && url.isEmpty) return 'series:$seriesId';
return url.isEmpty ? name : url;
}
}

class Library {
final List<Item> live;
final List<Item> movies;
final List<Item> series;

const Library(this.live, this.movies, this.series);

bool get isEmpty => live.isEmpty && movies.isEmpty && series.isEmpty;

List<Item> get all => [...live, ...movies, ...series];
}

String _s(dynamic v) => v == null ? '' : '$v';

String _errorText(Object e) {
final t = '$e';
if (e is TimeoutException) {
return 'Le serveur met trop de temps à répondre.';
}
if (e is FormatException) {
return 'La réponse du serveur est illisible. Vérifiez l’adresse.';
}
if (t.contains('SocketException') || t.contains('ClientException')) {
return 'Connexion impossible. Vérifiez l’adresse et votre réseau.';
}
return t.replaceFirst('Exception: ', '');
}

// ---------------------------------------------------------------------------
// Connexion : liste M3U ou Xtream Codes
// ---------------------------------------------------------------------------

class Config {
final String type; // m3u ou xtream
final String url;
final String user;
final String pass;

const Config({
required this.type,
required this.url,
this.user = '',
this.pass = '',
});

Map<String, dynamic> toJson() => {
'type': type,
'url': url,
'user': user,
'pass': pass,
};

factory Config.fromJson(Map<String, dynamic> j) => Config(
type: _s(j['type']),
url: _s(j['url']),
user: _s(j['user']),
pass: _s(j['pass']),
);

String get base {
var u = url.trim();
if (!u.startsWith('http://') && !u.startsWith('https://')) {
u = 'http://$u';
}
final cut = u.indexOf('/player_api.php');
if (cut > 0) u = u.substring(0, cut);
while (u.endsWith('/')) {
u = u.substring(0, u.length - 1);
}
return u;
}

String get _u => user.trim();
String get _p => pass.trim();

Future<Library> load() async {
final lib = type == 'm3u' ? await _loadM3u() : await _loadXtream();
if (lib.isEmpty) {
throw Exception('Aucun contenu trouvé dans cette liste.');
}
return lib;
}

// --- M3U ---

Future<Library> _loadM3u() async {
var link = url.trim();
if (!link.startsWith('http://') && !link.startsWith('https://')) {
link = 'http://$link';
}
final r = await http
.get(Uri.parse(link))
.timeout(const Duration(seconds: 90));
if (r.statusCode != 200) {
throw Exception('Le serveur a répondu ${r.statusCode}.');
}
final items = parseM3u(utf8.decode(r.bodyBytes, allowMalformed: true));
return Library(
items.where((i) => i.kind == 'live').toList(),
items.where((i) => i.kind == 'movie').toList(),
items.where((i) => i.kind == 'series').toList(),
);
}

// --- Xtream Codes ---

Future<dynamic> _api(String action, [Map<String, String>? extra]) async {
final q = <String, String>{'username': _u, 'password': _p};
if (action.isNotEmpty) q['action'] = action;
if (extra != null) q.addAll(extra);
final uri = Uri.parse('$base/player_api.php').replace(queryParameters: q);
final r = await http.get(uri).timeout(const Duration(seconds: 60));
if (r.statusCode != 200) {
throw Exception('Le serveur a répondu ${r.statusCode}.');
}
return jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
}

Map<String, String> _cats(dynamic raw) {
final m = <String, String>{};
if (raw is List) {
for (final e in raw) {
if (e is Map) {
m[_s(e['category_id'])] = _s(e['category_name']);
}
}
}
return m;
}

Future<Library> _loadXtream() async {
final info = await _api('');
final ui = info is Map ? info['user_info'] : null;
if (ui is! Map || _s(ui['auth']) != '1') {
throw Exception('Identifiants incorrects ou abonnement expiré.');
}
final res = await Future.wait([_live(), _vod(), _series()]);
return Library(res[0], res[1], res[2]);
}

Future<List<Item>> _live() async {
try {
final cats = _cats(await _api('get_live_categories'));
final raw = await _api('get_live_streams');
final out = <Item>[];
if (raw is List) {
for (final e in raw) {
if (e is! Map) continue;
final id = _s(e['stream_id']);
out.add(Item(
name: _s(e['name']),
url: '$base/live/$_u/$_p/$id.m3u8',
alt: '$base/live/$_u/$_p/$id.ts',
logo: _s(e['stream_icon']),
group: cats[_s(e['category_id'])] ?? 'Divers',
kind: 'live',
));
}
}
return out;
} catch (_) {
return <Item>[];
}
}

Future<List<Item>> _vod() async {
try {
final cats = _cats(await _api('get_vod_categories'));
final raw = await _api('get_vod_streams');
final out = <Item>[];
if (raw is List) {
for (final e in raw) {
if (e is! Map) continue;
final id = _s(e['stream_id']);
final ext =
_s(e['container_extension']).isEmpty ? 'mp4' : _s(e['container_extension']);
out.add(Item(
name: _s(e['name']),
url: '$base/movie/$_u/$_p/$id.$ext',
logo: _s(e['stream_icon']),
group: cats[_s(e['category_id'])] ?? 'Divers',
kind: 'movie',
));
}
}
return out;
} catch (_) {
return <Item>[];
}
}

Future<List<Item>> _series() async {
try {
final cats = _cats(await _api('get_series_categories'));
final raw = await _api('get_series');
final out = <Item>[];
if (raw is List) {
for (final e in raw) {
if (e is! Map) continue;
final id = int.tryParse(_s(e['series_id']));
if (id == null) continue;
out.add(Item(
name: _s(e['name']),
logo: _s(e['cover']),
group: cats[_s(e['category_id'])] ?? 'Divers',
kind: 'series',
seriesId: id,
));
}
}
return out;
} catch (_) {
return <Item>[];
}
}

Future<List<Item>> episodes(int seriesId) async {
final raw = await _api('get_series_info', {'series_id': '$seriesId'});
final out = <Item>[];
if (raw is! Map) return out;
final eps = raw['episodes'];

void add(String season, dynamic e) {
if (e is! Map) return;
final ext =
_s(e['container_extension']).isEmpty ? 'mp4' : _s(e['container_extension']);
final n = _s(e['episode_num']);
final title = _s(e['title']);
out.add(Item(
name: title.isEmpty ? 'Épisode $n' : title,
url: '$base/series/$_u/$_p/${_s(e['id'])}.$ext',
group: 'Saison $season',
kind: 'series',
));
}

if (eps is Map) {
eps.forEach((k, v) {
if (v is List) {
for (final e in v) {
add('$k', e);
}
}
});
} else if (eps is List) {
for (var i = 0; i < eps.length; i++) {
final v = eps[i];
if (v is List) {
for (final e in v) {
add('${i + 1}', e);
}
}
}
}
return out;
}
}

String? _attr(String line, String key) {
final m = RegExp('$key="([^"]*)"').firstMatch(line);
return m?.group(1);
}

List<Item> parseM3u(String text) {
final items = <Item>[];
String? name;
String logo = '';
String group = 'Divers';
for (final raw in const LineSplitter().convert(text)) {
final line = raw.trim();
if (line.isEmpty) continue;
if (line.startsWith('#EXTINF')) {
final comma = line.lastIndexOf(',');
name = comma >= 0 ? line.substring(comma + 1).trim() : 'Sans nom';
logo = _attr(line, 'tvg-logo') ?? '';
final g = _attr(line, 'group-title') ?? '';
group = g.isEmpty ? 'Divers' : g;
} else if (!line.startsWith('#')) {
var kind = 'live';
if (line.contains('/movie/')) {
kind = 'movie';
} else if (line.contains('/series/')) {
kind = 'series';
}
items.add(Item(
name: (name == null || name.isEmpty) ? line : name,
url: line,
logo: logo,
group: group,
kind: kind,
));
name = null;
logo = '';
group = 'Divers';
}
}
return items;
}

// ---------------------------------------------------------------------------
// Stockage local : connexion, favoris, positions de lecture
// ---------------------------------------------------------------------------

class Store {
static late SharedPreferences _p;
static Set<String> _favs = <String>{};

static Future<void> init() async {
_p = await SharedPreferences.getInstance();
_favs = (_p.getStringList('favs') ?? <String>[]).toSet();
}

static Config? get config {
final s = _p.getString('config');
if (s == null) return null;
try {
return Config.fromJson(jsonDecode(s) as Map<String, dynamic>);
} catch (_) {
return null;
}
}

static Future<void> saveConfig(Config c) async {
await _p.setString('config', jsonEncode(c.toJson()));
}

static Future<void> clearConfig() async {
await _p.remove('config');
}

static bool isFav(Item i) => _favs.contains(i.key);

static Future<void> toggleFav(Item i) async {
if (!_favs.remove(i.key)) _favs.add(i.key);
await _p.setStringList('favs', _favs.toList());
}

static int position(String url) => _p.getInt('pos:$url') ?? 0;

static Future<void> savePosition(String url, int ms) async {
await _p.setInt('pos:$url', ms);
}
}

// ---------------------------------------------------------------------------
// Éléments d’interface réutilisables
// ---------------------------------------------------------------------------

class Backdrop extends StatelessWidget {
final Widget child;
const Backdrop({super.key, required this.child});

@override
Widget build(BuildContext context) {
return Container(
decoration: const BoxDecoration(
gradient: RadialGradient(
center: Alignment(-0.8, -1.0),
radius: 1.7,
colors: [Color(0xFF4A0A14), kBlack],
),
),
child: child,
);
}
}

class GoldText extends StatelessWidget {
final String text;
final double size;
final double spacing;
const GoldText(this.text, {super.key, this.size = 22, this.spacing = 3});

@override
Widget build(BuildContext context) {
return ShaderMask(
shaderCallback: (rect) => kGoldGradient.createShader(rect),
blendMode: BlendMode.srcIn,
child: Text(
text,
style: TextStyle(
fontSize: size,
fontWeight: FontWeight.w800,
letterSpacing: spacing,
color: Colors.white,
),
),
);
}
}

class Crown extends StatelessWidget {
final double size;
const Crown({super.key, this.size = 40});

@override
Widget build(BuildContext context) {
return Container(
width: size,
height: size,
decoration: BoxDecoration(
shape: BoxShape.circle,
gradient: kGoldGradient,
boxShadow: [
BoxShadow(color: kGold.withAlpha(90), blurRadius: size / 2),
],
),
child: Icon(Icons.live_tv_rounded, color: kBlack, size: size * 0.52),
);
}
}

/// Zone cliquable ou sélectionnable à la télécommande : bordure dorée au focus.
class GoldTap extends StatefulWidget {
final Widget child;
final VoidCallback? onTap;
final VoidCallback? onLongPress;
final double radius;
final bool autofocus;

const GoldTap({
super.key,
required this.child,
this.onTap,
this.onLongPress,
this.radius = 14,
this.autofocus = false,
});

@override
State<GoldTap> createState() => _GoldTapState();
}

class _GoldTapState extends State<GoldTap> {
bool _focused = false;

@override
Widget build(BuildContext context) {
final r = BorderRadius.circular(widget.radius);
return AnimatedScale(
scale: _focused ? 1.05 : 1.0,
duration: const Duration(milliseconds: 140),
child: AnimatedContainer(
duration: const Duration(milliseconds: 140),
decoration: BoxDecoration(
borderRadius: r,
border: Border.all(
color: _focused ? kGoldLight : Colors.transparent,
width: 2.5,
),
boxShadow: _focused
? [BoxShadow(color: kGold.withAlpha(110), blurRadius: 20, spreadRadius: 1)]
: const <BoxShadow>[],
),
child: ClipRRect(
borderRadius: r,
child: Material(
color: Colors.transparent,
child: InkWell(
autofocus: widget.autofocus,
onTap: widget.onTap,
onLongPress: widget.onLongPress,
onFocusChange: (v) => setState(() => _focused = v),
focusColor: Colors.transparent,
hoverColor: Colors.white10,
splashColor: kGold.withAlpha(40),
child: widget.child,
),
),
),
),
);
}
}

class GoldButton extends StatelessWidget {
final String label;
final VoidCallback? onTap;
final bool busy;
final bool autofocus;

const GoldButton({
super.key,
required this.label,
required this.onTap,
this.busy = false,
this.autofocus = false,
});

@override
Widget build(BuildContext context) {
return GoldTap(
radius: 16,
autofocus: autofocus,
onTap: busy ? () {} : onTap,
child: Container(
width: double.infinity,
padding: const EdgeInsets.symmetric(vertical: 16),
decoration: const BoxDecoration(gradient: kGoldGradient),
alignment: Alignment.center,
child: busy
? const SizedBox(
width: 22,
height: 22,
child: CircularProgressIndicator(strokeWidth: 3, color: kBlack),
)
: Text(
label,
style: const TextStyle(
color: kBlack,
fontSize: 17,
fontWeight: FontWeight.w800,
letterSpacing: 0.5,
),
),
),
);
}
}

class NetImg extends StatelessWidget {
final String url;
final BoxFit fit;
const NetImg(this.url, {super.key, this.fit = BoxFit.contain});

Widget _fallback() => Center(
child: Icon(Icons.live_tv_rounded, color: kGold.withAlpha(120), size: 34),
);

@override
Widget build(BuildContext context) {
if (!url.startsWith('http')) return _fallback();
return Image.network(
url,
fit: fit,
cacheWidth: 360,
gaplessPlayback: true,
errorBuilder: (c, e, s) => _fallback(),
);
}
}

// ---------------------------------------------------------------------------
// Porte d’entrée : chargement, connexion, accueil
// ---------------------------------------------------------------------------

class Gate extends StatefulWidget {
const Gate({super.key});

@override
State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
Library? _lib;
String? _error;
bool _loading = true;
bool _needLogin = false;

@override
void initState() {
super.initState();
_boot();
}

Future<void> _boot() async {
await Store.init();
final cfg = Store.config;
if (cfg == null) {
if (!mounted) return;
setState(() {
_loading = false;
_needLogin = true;
});
return;
}
await _fetch(cfg);
}

Future<void> _fetch(Config cfg) async {
setState(() {
_loading = true;
_error = null;
});
try {
final l = await cfg.load();
if (!mounted) return;
setState(() {
_lib = l;
_loading = false;
_needLogin = false;
});
} catch (e) {
if (!mounted) return;
setState(() {
_loading = false;
_error = _errorText(e);
});
}
}

Future<String?> _login(Config cfg) async {
try {
final l = await cfg.load();
await Store.saveConfig(cfg);
if (!mounted) return null;
setState(() {
_lib = l;
_error = null;
_loading = false;
_needLogin = false;
});
return null;
} catch (e) {
return _errorText(e);
}
}

@override
Widget build(BuildContext context) {
if (_loading) return const LoadingView();
if (_needLogin) return LoginScreen(onConnect: _login);
if (_error != null || _lib == null) {
return ErrorView(
message: _error ?? 'Une erreur est survenue.',
onRetry: () {
final c = Store.config;
if (c != null) _fetch(c);
},
onEdit: () => setState(() => _needLogin = true),
);
}
return HomeScreen(
lib: _lib!,
onRefresh: () {
final c = Store.config;
if (c != null) _fetch(c);
},
onLogout: () async {
await Store.clearConfig();
if (!mounted) return;
setState(() {
_lib = null;
_needLogin = true;
});
},
);
}
}

class LoadingView extends StatelessWidget {
const LoadingView({super.key});

@override
Widget build(BuildContext context) {
return Scaffold(
body: Backdrop(
child: Center(
child: Column(
mainAxisSize: MainAxisSize.min,
children: const [
Crown(size: 84),
SizedBox(height: 18),
GoldText('LOUNGE TV', size: 30, spacing: 6),
SizedBox(height: 30),
CircularProgressIndicator(color: kGold),
SizedBox(height: 18),
Text(
'Chargement de vos chaînes…',
style: TextStyle(color: Colors.white70),
),
],
),
),
),
);
}
}

class ErrorView extends StatelessWidget {
final String message;
final VoidCallback onRetry;
final VoidCallback onEdit;

const ErrorView({
super.key,
required this.message,
required this.onRetry,
required this.onEdit,
});

@override
Widget build(BuildContext context) {
return Scaffold(
body: Backdrop(
child: Center(
child: ConstrainedBox(
constraints: const BoxConstraints(maxWidth: 460),
child: Padding(
padding: const EdgeInsets.all(24),
child: Column(
mainAxisSize: MainAxisSize.min,
children: [
const Icon(Icons.error_outline_rounded, color: kGold, size: 54),
const SizedBox(height: 16),
const Text(
'Impossible de charger votre liste',
textAlign: TextAlign.center,
style: TextStyle(
color: Colors.white,
fontSize: 20,
fontWeight: FontWeight.w700,
),
),
const SizedBox(height: 10),
Text(
message,
textAlign: TextAlign.center,
style: const TextStyle(color: Colors.white70, fontSize: 15),
),
const SizedBox(height: 26),
GoldButton(label: 'Réessayer', onTap: onRetry, autofocus: true),
const SizedBox(height: 12),
GoldTap(
radius: 16,
onTap: onEdit,
child: Container(
width: double.infinity,
padding: const EdgeInsets.symmetric(vertical: 14),
alignment: Alignment.center,
color: kPanel,
child: const Text(
'Modifier la connexion',
style: TextStyle(
color: kGoldLight,
fontWeight: FontWeight.w700,
),
),
),
),
],
),
),
),
),
),
);
}
}

// ---------------------------------------------------------------------------
// Écran de connexion
// ---------------------------------------------------------------------------

class LoginScreen extends StatefulWidget {
final Future<String?> Function(Config) onConnect;
const LoginScreen({super.key, required this.onConnect});

@override
State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
bool _xtream = true;
final _m3u = TextEditingController();
final _host = TextEditingController();
final _user = TextEditingController();
final _pass = TextEditingController();
bool _busy = false;
String? _err;

@override
void initState() {
super.initState();
final c = Store.config;
if (c != null) {
_xtream = c.type != 'm3u';
if (c.type == 'm3u') {
_m3u.text = c.url;
} else {
_host.text = c.url;
_user.text = c.user;
_pass.text = c.pass;
}
}
}

@override
void dispose() {
_m3u.dispose();
_host.dispose();
_user.dispose();
_pass.dispose();
super.dispose();
}

Future<void> _go() async {
final Config cfg;
if (_xtream) {
if (_host.text.trim().isEmpty ||
_user.text.trim().isEmpty ||
_pass.text.trim().isEmpty) {
setState(() => _err = 'Remplissez le serveur, l’utilisateur et le mot de passe.');
return;
}
cfg = Config(
type: 'xtream',
url: _host.text,
user: _user.text,
pass: _pass.text,
);
} else {
if (_m3u.text.trim().isEmpty) {
setState(() => _err = 'Collez l’adresse de votre liste M3U.');
return;
}
cfg = Config(type: 'm3u', url: _m3u.text);
}
setState(() {
_busy = true;
_err = null;
});
final e = await widget.onConnect(cfg);
if (!mounted) return;
setState(() {
_busy = false;
_err = e;
});
}

InputDecoration _deco(String label, IconData icon) {
OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
borderRadius: BorderRadius.circular(14),
borderSide: BorderSide(color: c, width: w),
);
return InputDecoration(
labelText: label,
labelStyle: const TextStyle(color: Colors.white60),
floatingLabelStyle: const TextStyle(color: kGoldLight),
prefixIcon: Icon(icon, color: kGold),
filled: true,
fillColor: const Color(0xFF1E0C11),
enabledBorder: border(kGold.withAlpha(70), 1),
border: border(kGold.withAlpha(70), 1),
focusedBorder: border(kGold, 2),
);
}

Widget _modeTab(String label, bool selected, VoidCallback onTap) {
return Expanded(
child: GoldTap(
radius: 14,
onTap: onTap,
child: Container(
padding: const EdgeInsets.symmetric(vertical: 13),
alignment: Alignment.center,
decoration: BoxDecoration(
gradient: selected ? kGoldGradient : null,
color: selected ? null : kPanel,
),
child: Text(
label,
style: TextStyle(
color: selected ? kBlack : kGoldLight,
fontWeight: FontWeight.w800,
),
),
),
),
);
}

@override
Widget build(BuildContext context) {
return Scaffold(
body: Backdrop(
child: SafeArea(
child: Center(
child: SingleChildScrollView(
padding: const EdgeInsets.all(24),
child: ConstrainedBox(
constraints: const BoxConstraints(maxWidth: 520),
child: Column(
mainAxisSize: MainAxisSize.min,
children: [
const Crown(size: 80),
const SizedBox(height: 14),
const GoldText('LOUNGE TV', size: 32, spacing: 6),
const SizedBox(height: 6),
const Text(
'Votre salon, version prestige',
style: TextStyle(color: Colors.white60, fontSize: 14),
),
const SizedBox(height: 26),
Container(
padding: const EdgeInsets.all(22),
decoration: BoxDecoration(
color: Colors.black.withAlpha(120),
borderRadius: BorderRadius.circular(24),
border: Border.all(color: kGold.withAlpha(110)),
),
child: Column(
children: [
Row(
children: [
_modeTab('Xtream Codes', _xtream,
() => setState(() => _xtream = true)),
const SizedBox(width: 10),
_modeTab('Liste M3U', !_xtream,
() => setState(() => _xtream = false)),
],
),
const SizedBox(height: 20),
if (_xtream) ...[
TextField(
controller: _host,
keyboardType: TextInputType.url,
textInputAction: TextInputAction.next,
decoration: _deco('Serveur (http://…)', Icons.dns_rounded),
),
const SizedBox(height: 14),
TextField(
controller: _user,
textInputAction: TextInputAction.next,
decoration: _deco('Utilisateur', Icons.person_rounded),
),
const SizedBox(height: 14),
TextField(
controller: _pass,
obscureText: true,
textInputAction: TextInputAction.done,
onSubmitted: (_) => _go(),
decoration: _deco('Mot de passe', Icons.lock_rounded),
),
] else
TextField(
controller: _m3u,
keyboardType: TextInputType.url,
textInputAction: TextInputAction.done,
onSubmitted: (_) => _go(),
decoration: _deco('Adresse de la liste M3U', Icons.link_rounded),
),
if (_err != null) ...[
const SizedBox(height: 14),
Text(
_err!,
textAlign: TextAlign.center,
style: const TextStyle(
color: Color(0xFFFF8A8A),
fontSize: 14,
),
),
],
const SizedBox(height: 22),
GoldButton(label: 'Se connecter', onTap: _go, busy: _busy),
],
),
),
],
),
),
),
),
),
),
);
}
}

// ---------------------------------------------------------------------------
// Accueil : chaînes, films, séries, favoris
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
final Library lib;
final VoidCallback onRefresh;
final VoidCallback onLogout;

const HomeScreen({
super.key,
required this.lib,
required this.onRefresh,
required this.onLogout,
});

@override
State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
static const List<String> _tabNames = ['Chaînes', 'Films', 'Séries', 'Favoris'];
static const List<IconData> _tabIcons = [
Icons.live_tv_rounded,
Icons.movie_rounded,
Icons.video_library_rounded,
Icons.star_rounded,
];

int _tab = 0;
String? _group;
String _query = '';
bool _searching = false;
final TextEditingController _searchCtl = TextEditingController();

List<Item> _src = <Item>[];
List<String> _groups = <String>[];
List<Item> _visible = <Item>[];

@override
void initState() {
super.initState();
_recompute();
}

@override
void dispose() {
_searchCtl.dispose();
super.dispose();
}

void _recompute({bool groups = true}) {
switch (_tab) {
case 0:
_src = widget.lib.live;
break;
case 1:
_src = widget.lib.movies;
break;
case 2:
_src = widget.lib.series;
break;
default:
_src = widget.lib.all.where((i) => Store.isFav(i)).toList();
}
if (groups) {
final seen = <String>{};
final g = <String>[];
for (final i in _src) {
if (seen.add(i.group)) g.add(i.group);
}
_groups = g;
if (_group != null && !seen.contains(_group)) _group = null;
}
final q = _query.trim().toLowerCase();
_visible = _src
.where((i) =>
(_group == null || i.group == _group) &&
(q.isEmpty || i.name.toLowerCase().contains(q)))
.toList();
}

void _open(int index) {
final it = _visible[index];
if (it.url.isEmpty) {
Navigator.of(context)
.push(MaterialPageRoute(builder: (_) => SeriesScreen(series: it)))
.then((_) {
if (mounted) setState(() {});
});
return;
}
final playable = _visible.where((e) => e.url.isNotEmpty).toList();
final idx = playable.indexOf(it);
Navigator.of(context)
.push(MaterialPageRoute(
builder: (_) => PlayerScreen(items: playable, index: idx < 0 ? 0 : idx),
))
.then((_) {
if (mounted) setState(() => _recompute(groups: false));
});
}

Future<void> _toggleFav(Item it) async {
await Store.toggleFav(it);
if (!mounted) return;
final now = Store.isFav(it);
setState(() => _recompute(groups: _tab == 3));
ScaffoldMessenger.of(context).showSnackBar(
SnackBar(
content: Text(now ? 'Ajouté aux favoris' : 'Retiré des favoris'),
backgroundColor: kRed,
duration: const Duration(milliseconds: 1400),
),
);
}

Widget _iconBtn(IconData icon, VoidCallback onTap) {
return GoldTap(
radius: 24,
onTap: onTap,
child: Padding(
padding: const EdgeInsets.all(10),
child: Icon(icon, color: kGoldLight, size: 24),
),
);
}

Widget _header() {
final wide = MediaQuery.of(context).size.width >= 900;
return Padding(
padding: const EdgeInsets.fromLTRB(20, 14, 16, 6),
child: Row(
children: [
if (!_searching || wide) ...[
const Crown(size: 38),
const SizedBox(width: 12),
const GoldText('LOUNGE TV', size: 21, spacing: 4),
],
const Spacer(),
if (_searching) ...[
SizedBox(
width: wide ? 340 : 200,
child: TextField(
controller: _searchCtl,
autofocus: true,
style: const TextStyle(color: Colors.white),
onChanged: (v) => setState(() {
_query = v;
_recompute(groups: false);
}),
decoration: InputDecoration(
hintText: 'Rechercher',
hintStyle: const TextStyle(color: Colors.white54),
prefixIcon: const Icon(Icons.search_rounded, color: kGold),
isDense: true,
filled: true,
fillColor: const Color(0xFF1E0C11),
enabledBorder: OutlineInputBorder(
borderRadius: BorderRadius.circular(22),
borderSide: BorderSide(color: kGold.withAlpha(90)),
),
focusedBorder: OutlineInputBorder(
borderRadius: BorderRadius.circular(22),
borderSide: const BorderSide(color: kGold, width: 2),
),
),
),
),
const SizedBox(width: 8),
_iconBtn(Icons.close_rounded, () {
setState(() {
_searching = false;
_query = '';
_searchCtl.clear();
_recompute(groups: false);
});
}),
] else ...[
_iconBtn(Icons.search_rounded, () => setState(() => _searching = true)),
const SizedBox(width: 6),
_iconBtn(Icons.refresh_rounded, widget.onRefresh),
const SizedBox(width: 6),
_iconBtn(Icons.logout_rounded, widget.onLogout),
],
],
),
);
}

Widget _tabs() {
return Padding(
padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
child: SingleChildScrollView(
scrollDirection: Axis.horizontal,
child: Row(
children: [
for (var i = 0; i < _tabNames.length; i++)
Padding(
padding: const EdgeInsets.only(right: 10),
child: GoldTap(
radius: 22,
onTap: () => setState(() {
_tab = i;
_group = null;
_recompute();
}),
child: Container(
padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
decoration: BoxDecoration(
gradient: _tab == i ? kGoldGradient : null,
color: _tab == i ? null : kPanel,
),
child: Row(
mainAxisSize: MainAxisSize.min,
children: [
Icon(_tabIcons[i],
size: 18, color: _tab == i ? kBlack : kGoldLight),
const SizedBox(width: 8),
Text(
_tabNames[i],
style: TextStyle(
color: _tab == i ? kBlack : kGoldLight,
fontWeight: FontWeight.w800,
),
),
],
),
),
),
),
],
),
),
);
}

Widget _catTile(String label, bool selected, VoidCallback onTap, {bool expand = false}) {
return GoldTap(
radius: 12,
onTap: onTap,
child: Container(
width: expand ? double.infinity : null,
padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
decoration: BoxDecoration(
color: selected ? kRed : kPanel,
border: Border(
left: BorderSide(color: selected ? kGold : Colors.transparent, width: 3),
),
),
child: Text(
label,
maxLines: 1,
overflow: TextOverflow.ellipsis,
style: TextStyle(
color: selected ? Colors.white : Colors.white70,
fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
),
),
),
);
}

void _pickGroup(String? g) {
setState(() {
_group = g;
_recompute(groups: false);
});
}

Widget _sidebar() {
return ListView.builder(
padding: const EdgeInsets.fromLTRB(16, 6, 8, 20),
itemCount: _groups.length + 1,
itemBuilder: (c, i) {
final g = i == 0 ? null : _groups[i - 1];
return Padding(
padding: const EdgeInsets.only(bottom: 8),
child: _catTile(g ?? 'Tout', _group == g, () => _pickGroup(g), expand: true),
);
},
);
}

Widget _chips() {
return ListView.builder(
scrollDirection: Axis.horizontal,
padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
itemCount: _groups.length + 1,
itemBuilder: (c, i) {
final g = i == 0 ? null : _groups[i - 1];
return Padding(
padding: const EdgeInsets.only(right: 8),
child: _catTile(g ?? 'Tout', _group == g, () => _pickGroup(g)),
);
},
);
}

Widget _liveFace(Item it) {
return Container(
padding: const EdgeInsets.all(10),
decoration: BoxDecoration(
gradient: const LinearGradient(
colors: [Color(0xFF2B0C12), Color(0xFF14070A)],
begin: Alignment.topLeft,
end: Alignment.bottomRight,
),
border: Border.all(color: kGold.withAlpha(60)),
borderRadius: BorderRadius.circular(16),
),
child: Stack(
children: [
Column(
children: [
Expanded(child: Center(child: NetImg(it.logo))),
const SizedBox(height: 6),
Text(
it.name,
maxLines: 2,
overflow: TextOverflow.ellipsis,
textAlign: TextAlign.center,
style: const TextStyle(
color: Colors.white,
fontSize: 13,
fontWeight: FontWeight.w600,
),
),
],
),
if (Store.isFav(it))
const Positioned(
top: 0,
right: 0,
child: Icon(Icons.star_rounded, color: kGold, size: 20),
),
],
),
);
}

Widget _posterFace(Item it) {
return Stack(
fit: StackFit.expand,
children: [
Container(color: kPanel, child: NetImg(it.logo, fit: BoxFit.cover)),
Positioned(
left: 0,
right: 0,
bottom: 0,
child: Container(
padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
decoration: BoxDecoration(
gradient: LinearGradient(
begin: Alignment.topCenter,
end: Alignment.bottomCenter,
colors: [Colors.transparent, Colors.black.withAlpha(230)],
),
),
child: Text(
it.name,
maxLines: 2,
overflow: TextOverflow.ellipsis,
style: const TextStyle(
color: Colors.white,
fontSize: 12.5,
fontWeight: FontWeight.w700,
),
),
),
),
if (Store.isFav(it))
const Positioned(
top: 6,
right: 6,
child: Icon(Icons.star_rounded, color: kGold, size: 22),
),
],
);
}

Widget _grid() {
if (_visible.isEmpty) {
return Center(
child: Padding(
padding: const EdgeInsets.all(24),
child: Column(
mainAxisSize: MainAxisSize.min,
children: [
Icon(Icons.inbox_rounded, color: kGold.withAlpha(160), size: 48),
const SizedBox(height: 12),
Text(
_tab == 3
? 'Aucun favori pour le moment.\nMaintenez OK sur une chaîne pour l’ajouter.'
: 'Rien à afficher ici.',
textAlign: TextAlign.center,
style: const TextStyle(color: Colors.white70, fontSize: 15),
),
],
),
),
);
}
final poster = _tab == 1 || _tab == 2;
return GridView.builder(
padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
maxCrossAxisExtent: poster ? 170 : 230,
childAspectRatio: poster ? 0.64 : 1.35,
mainAxisSpacing: 16,
crossAxisSpacing: 16,
),
itemCount: _visible.length,
itemBuilder: (c, i) {
final it = _visible[i];
return GoldTap(
radius: 16,
onTap: () => _open(i),
onLongPress: () => _toggleFav(it),
child: poster ? _posterFace(it) : _liveFace(it),
);
},
);
}

@override
Widget build(BuildContext context) {
return Scaffold(
body: Backdrop(
child: SafeArea(
child: Column(
children: [
_header(),
_tabs(),
Expanded(
child: LayoutBuilder(
builder: (context, bc) {
final grid = _grid();
if (bc.maxWidth >= 900) {
return Row(
children: [
SizedBox(width: 250, child: _sidebar()),
Expanded(child: grid),
],
);
}
return Column(
children: [
SizedBox(height: 56, child: _chips()),
Expanded(child: grid),
],
);
},
),
),
],
),
),
),
);
}
}

// ---------------------------------------------------------------------------
// Série : liste des saisons et épisodes
// ---------------------------------------------------------------------------

class SeriesScreen extends StatefulWidget {
final Item series;
const SeriesScreen({super.key, required this.series});

@override
State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
late Future<List<Item>> _future;

@override
void initState() {
super.initState();
final cfg = Store.config;
_future = cfg == null
? Future.value(<Item>[])
: cfg.episodes(widget.series.seriesId ?? 0);
}

Widget _body(List<Item> eps) {
if (eps.isEmpty) {
return const Center(
child: Text(
'Aucun épisode disponible pour cette série.',
style: TextStyle(color: Colors.white70),
),
);
}
final children = <Widget>[];
String? current;
for (var i = 0; i < eps.length; i++) {
final e = eps[i];
if (e.group != current) {
current = e.group;
children.add(Padding(
padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
child: GoldText(e.group, size: 18, spacing: 1.5),
));
}
final index = i;
children.add(Padding(
padding: const EdgeInsets.only(bottom: 8),
child: GoldTap(
radius: 12,
autofocus: i == 0,
onTap: () => Navigator.of(context).push(MaterialPageRoute(
builder: (_) => PlayerScreen(items: eps, index: index),
)),
child: Container(
padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
color: kPanel,
child: Row(
children: [
const Icon(Icons.play_circle_fill_rounded, color: kGold),
const SizedBox(width: 12),
Expanded(
child: Text(
e.name,
maxLines: 1,
overflow: TextOverflow.ellipsis,
style: const TextStyle(color: Colors.white, fontSize: 15),
),
),
],
),
),
),
));
}
return ListView(
padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
children: children,
);
}

@override
Widget build(BuildContext context) {
return Scaffold(
body: Backdrop(
child: SafeArea(
child: Column(
children: [
Padding(
padding: const EdgeInsets.fromLTRB(14, 12, 20, 6),
child: Row(
children: [
GoldTap(
radius: 24,
onTap: () => Navigator.of(context).maybePop(),
child: const Padding(
padding: EdgeInsets.all(10),
child: Icon(Icons.arrow_back_rounded, color: kGoldLight),
),
),
const SizedBox(width: 10),
Expanded(
child: Text(
widget.series.name,
maxLines: 1,
overflow: TextOverflow.ellipsis,
style: const TextStyle(
color: Colors.white,
fontSize: 20,
fontWeight: FontWeight.w800,
),
),
),
],
),
),
Expanded(
child: FutureBuilder<List<Item>>(
future: _future,
builder: (context, snap) {
if (snap.connectionState != ConnectionState.done) {
return const Center(child: CircularProgressIndicator(color: kGold));
}
if (snap.hasError) {
return Center(
child: Text(
_errorText(snap.error ?? 'Erreur'),
style: const TextStyle(color: Colors.white70),
),
);
}
return _body(snap.data ?? <Item>[]);
},
),
),
],
),
),
),
);
}
}

// ---------------------------------------------------------------------------
// Lecteur plein écran
// OK : lecture / pause Gauche, droite : -10 s / +10 s (films)
// Haut, bas : changer de chaîne (direct)
// ---------------------------------------------------------------------------

class PlayerScreen extends StatefulWidget {
final List<Item> items;
final int index;
const PlayerScreen({super.key, required this.items, required this.index});

@override
State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
late int _i;
VideoPlayerController? _c;
bool _overlay = true;
bool _error = false;
bool _usedAlt = false;
bool _fav = false;
int _gen = 0;
Timer? _hide;
Timer? _save;

Item get _item => widget.items[_i];
bool get _isLive => _item.kind == 'live';

@override
void initState() {
super.initState();
_i = widget.index;
SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
SystemChrome.setPreferredOrientations([
DeviceOrientation.landscapeLeft,
DeviceOrientation.landscapeRight,
]);
WidgetsBinding.instance.addPostFrameCallback((_) => _start(_item.url));
}

Future<void> _start(String url) async {
final gen = ++_gen;
final old = _c;
old?.removeListener(_tick);
if (mounted) {
setState(() {
_c = null;
_error = false;
_fav = Store.isFav(_item);
});
}
await old?.dispose();
final c = VideoPlayerController.networkUrl(
Uri.parse(url),
httpHeaders: const {'User-Agent': kPlayerAgent},
);
try {
await c.initialize();
if (!mounted || gen != _gen) {
await c.dispose();
…
