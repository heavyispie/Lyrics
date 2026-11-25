import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BratApp());
}

const Color limeColor = Color(0xFF8ACE00);

class BratColor {
  final String name;
  final Color bg;
  final Color fg;
  const BratColor(this.name, this.bg, this.fg);
}

const List<BratColor> bratColors = [
  BratColor('Verde Lima', Color(0xFF8ACE00), Color(0xFF000000)),
  BratColor('Blanco', Color(0xFFFFFFFF), Color(0xFF000000)),
  BratColor('Negro', Color(0xFF000000), Color(0xFFFFFFFF)),
];

class LrcLine {
  final Duration time;
  final String text;
  const LrcLine(this.time, this.text);
}

class Track {
  final String id;
  final String title;
  final String artist;
  final int durationMs;
  final String ext;
  final int savedAt;
  final String dir;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.ext,
    required this.savedAt,
    required this.dir,
  });

  String get audioPath => '$dir/$id.$ext';
  String get lrcPath => '$dir/$id.lrc';
  String get thumbPath => '$dir/$id.jpg';
  String get metaPath => '$dir/$id.json';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'durationMs': durationMs,
        'ext': ext,
        'savedAt': savedAt,
      };

  factory Track.fromJson(Map<String, dynamic> j, String dir) => Track(
        id: j['id'] as String,
        title: j['title'] as String,
        artist: j['artist'] as String,
        durationMs: (j['durationMs'] as num).toInt(),
        ext: j['ext'] as String,
        savedAt: (j['savedAt'] as num).toInt(),
        dir: dir,
      );
}

List<LrcLine> parseLrc(String raw) {
  final re = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');
  final out = <LrcLine>[];
  for (final line in raw.split('\n')) {
    final ms = re.allMatches(line).toList();
    if (ms.isEmpty) continue;
    final text = line.substring(ms.last.end).trim();
    for (final m in ms) {
      final mins = int.parse(m.group(1)!);
      final secs = double.parse(m.group(2)!);
      out.add(LrcLine(
        Duration(milliseconds: ((mins * 60 + secs) * 1000).round()),
        text,
      ));
    }
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}

String plainToLrc(String plain, int durSec) {
  final ls = plain
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (ls.isEmpty) return '';
  final total = (durSec > 0 ? durSec : ls.length * 4) * 1000;
  final step = total / ls.length;
  final b = StringBuffer();
  for (var i = 0; i < ls.length; i++) {
    final ms = (i * step).round();
    final m = (ms ~/ 60000).toString().padLeft(2, '0');
    final s = ((ms % 60000) / 1000).toStringAsFixed(2).padLeft(5, '0');
    b.writeln('[$m:$s]${ls[i]}');
  }
  return b.toString();
}

String? pickLyrics(dynamic j, int durSec) {
  if (j is! Map) return null;
  final synced = j['syncedLyrics'];
  if (synced is String && synced.trim().isNotEmpty) return synced;
  final plain = j['plainLyrics'];
  if (plain is String && plain.trim().isNotEmpty) {
    return plainToLrc(plain, durSec);
  }
  return null;
}

Future<String?> fetchLyrics(String title, String artist, int durSec) async {
  const headers = {'User-Agent': 'BratPlayer/1.0'};
  try {
    final uri = Uri.https('lrclib.net', '/api/get', {
      'artist_name': artist,
      'track_name': title,
      if (durSec > 0) 'duration': '$durSec',
    });
    final r =
        await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
    if (r.statusCode == 200) {
      final res = pickLyrics(jsonDecode(utf8.decode(r.bodyBytes)), durSec);
      if (res != null) return res;
    }
  } catch (_) {}
  try {
    final uri =
        Uri.https('lrclib.net', '/api/search', {'q': '$artist $title'});
    final r =
        await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
    if (r.statusCode == 200) {
      final list = jsonDecode(utf8.decode(r.bodyBytes));
      if (list is List) {
        for (final item in list) {
          if (item is Map &&
              item['syncedLyrics'] is String &&
              (item['syncedLyrics'] as String).trim().isNotEmpty) {
            return item['syncedLyrics'] as String;
          }
        }
        for (final item in list) {
          final res = pickLyrics(item, durSec);
          if (res != null) return res;
        }
      }
    }
  } catch (_) {}
  return null;
}

String cleanTitle(String t) {
  final cleaned = t
      .replaceAll(
        RegExp(
          r'[\(\[][^\)\]]*(official|video|audio|lyrics|lyric|visualizer|hd|4k)[^\)\]]*[\)\]]',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? t : cleaned;
}

String fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

class BratApp extends StatelessWidget {
  const BratApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brat Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(primary: limeColor),
        scaffoldBackgroundColor: const Color(0xFF0E0E0E),
      ),
      home: const HomePage(),
    );
  }
}

class _W {
  final String t;
  final bool visible;
  const _W(this.t, this.visible);
}

class BratBox extends StatelessWidget {
  final List<LrcLine> lines;
  final Duration pos;
  final BratColor color;
  final String fallback;

  const BratBox({
    super.key,
    required this.lines,
    required this.pos,
    required this.color,
    required this.fallback,
  });

  List<_W> _words() {
    if (lines.isEmpty) {
      return fallback
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .map((e) => _W(e, true))
          .toList();
    }
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx < 0) return [];
    final cur = lines[idx];
    final out = <_W>[];
    final prev = <String>[];
    final maxPrev = cur.text.isEmpty ? 3 : 2;
    for (var j = idx - 1; j >= 0 && prev.length < maxPrev; j--) {
      if (lines[j].text.isNotEmpty) prev.insert(0, lines[j].text);
    }
    if (cur.text.isEmpty && lines[idx].text.isEmpty) {
      var k = idx;
      while (k >= 0 && prev.length < maxPrev && lines[k].text.isNotEmpty) {
        k--;
      }
    }
    for (final p in prev) {
      for (final w in p.toLowerCase().split(RegExp(r'\s+'))) {
        if (w.isNotEmpty) out.add(_W(w, true));
      }
    }
    if (cur.text.isNotEmpty) {
      final end = idx + 1 < lines.length
          ? lines[idx + 1].time
          : cur.time + const Duration(seconds: 4);
      final span = math.max((end - cur.time).inMilliseconds, 1);
      final frac =
          ((pos - cur.time).inMilliseconds / (span * 0.75)).clamp(0.0, 1.0);
      final ws = cur.text
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .toList();
      final shown = (frac * ws.length).ceil();
      for (var i = 0; i < ws.length; i++) {
        out.add(_W(ws[i], i < shown));
      }
    }
    if (out.length > 24) return out.sublist(out.length - 24);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final words = _words();
    final style = TextStyle(
      fontFamily: 'sans-serif-condensed',
      fontSize: 30,
      fontWeight: FontWeight.w500,
      height: 1.08,
      letterSpacing: -1.0,
      color: color.fg,
    );
    final spans = <TextSpan>[
      for (final w in words)
        TextSpan(
          text: '${w.t} ',
          style: TextStyle(color: w.visible ? color.fg : Colors.transparent),
        ),
    ];
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: color.bg,
          border: Border.all(color: Colors.white24),
        ),
        padding: const EdgeInsets.all(16),
        child: ClipRect(
          child: Align(
            alignment: Alignment.center,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 0.6, sigmaY: 0.6),
              child: RichText(
                textAlign: TextAlign.justify,
                text: TextSpan(style: style, children: spans),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final YoutubeExplode _yt = YoutubeExplode();
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _searchCtl = TextEditingController();
  final ValueNotifier<Duration> _pos = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _dur = ValueNotifier(Duration.zero);

  int _tab = 0;
  int _bratIndex = 0;
  bool _searching = false;
  double? _drag;

  List<Video> _results = [];
  List<Track> _library = [];
  final Map<String, double> _progress = {};

  List<Track> _queue = [];
  int _idx = -1;
  Track? _current;
  List<LrcLine> _lines = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await Permission.audio.request();
      await Permission.storage.request();
    } catch (_) {}
    _player.positionStream.listen((p) => _pos.value = p);
    _player.durationStream.listen((d) => _dur.value = d ?? Duration.zero);
    _player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _next();
    });
    await _loadLibrary();
  }

  @override
  void dispose() {
    _player.dispose();
    _yt.close();
    _searchCtl.dispose();
    _pos.dispose();
    _dur.dispose();
    super.dispose();
  }

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<Directory> _musicDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/brat_music');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _loadLibrary() async {
    final dir = await _musicDir();
    final out = <Track>[];
    for (final e in dir.listSync()) {
      if (e is File && e.path.endsWith('.json')) {
        try {
          final j = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
          final t = Track.fromJson(j, dir.path);
          if (File(t.audioPath).existsSync()) out.add(t);
        } catch (_) {}
      }
    }
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    if (mounted) setState(() => _library = out);
  }

  Future<void> _search(String q) async {
    q = q.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _tab = 1;
      _searching = true;
    });
    try {
      final r = await _yt.search.search(q);
      if (mounted) setState(() => _results = r.toList());
    } catch (_) {
      _msg('No se pudo buscar. Revisa tu conexión.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<Track?> _download(Video v) async {
    final id = v.id.value;
    if (_progress.containsKey(id)) return null;
    setState(() => _progress[id] = 0);
    File? audioFile;
    try {
      final dir = await _musicDir();
      final manifest = await _yt.videos.streamsClient.getManifest(v.id);
      final audios = manifest.audioOnly.toList();
      final mp4 =
          audios.where((s) => s.container == StreamContainer.mp4).toList();
      final AudioOnlyStreamInfo info;
      if (mp4.isNotEmpty) {
        mp4.sort((a, b) =>
            b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        info = mp4.first;
      } else {
        info = manifest.audioOnly.withHighestBitrate();
      }
      final ext = info.container == StreamContainer.mp4 ? 'm4a' : 'webm';
      audioFile = File('${dir.path}/$id.$ext');
      final sink = audioFile.openWrite();
      final total = info.size.totalBytes;
      var got = 0;
      var last = 0.0;
      await for (final chunk in _yt.videos.streamsClient.get(info)) {
        got += chunk.length;
        sink.add(chunk);
        final p = total > 0 ? got / total : 0.0;
        if (p - last >= 0.01) {
          last = p;
          if (mounted) setState(() => _progress[id] = p);
        }
      }
      await sink.flush();
      await sink.close();

      var title = cleanTitle(v.title);
      var artist = v.author.replaceAll(RegExp(r' - Topic$'), '');
      final dash = title.indexOf(' - ');
      if (dash > 0) {
        artist = title.substring(0, dash).trim();
        final rest = title.substring(dash + 3).trim();
        if (rest.isNotEmpty) title = rest;
      }
      final durSec = v.duration?.inSeconds ?? 0;

      try {
        final r = await http.get(Uri.parse(v.thumbnails.mediumResUrl));
        if (r.statusCode == 200) {
          await File('${dir.path}/$id.jpg').writeAsBytes(r.bodyBytes);
        }
      } catch (_) {}

      final lrc = await fetchLyrics(title, artist, durSec);
      if (lrc != null && lrc.trim().isNotEmpty) {
        await File('${dir.path}/$id.lrc').writeAsString(lrc);
      }

      final track = Track(
        id: id,
        title: title,
        artist: artist,
        durationMs: (v.duration ?? Duration.zero).inMilliseconds,
        ext: ext,
        savedAt: DateTime.now().millisecondsSinceEpoch,
        dir: dir.path,
      );
      await File(track.metaPath).writeAsString(jsonEncode(track.toJson()));
      if (lrc == null) _msg('Descargada sin letra sincronizada');
      return track;
    } catch (_) {
      try {
        if (audioFile != null && await audioFile.exists()) {
          await audioFile.delete();
        }
      } catch (_) {}
      _msg('Error al descargar la canción');
      return null;
    } finally {
      if (mounted) setState(() => _progress.remove(id));
    }
  }

  Future<void> _onResultTap(Video v) async {
    final id = v.id.value;
    var i = _library.indexWhere((t) => t.id == id);
    if (i < 0) {
      final t = await _download(v);
      if (t == null) return;
      await _loadLibrary();
      i = _library.indexWhere((x) => x.id == id);
    }
    if (i >= 0) {
      if (mounted) setState(() => _tab = 0);
      await _playQueue(_library, i);
    }
  }

  Future<void> _playQueue(List<Track> q, int i) async {
    if (i < 0 || i >= q.length) return;
    final t = q[i];
    _queue = List<Track>.of(q);
    _idx = i;
    var lines = <LrcLine>[];
    try {
      final f = File(t.lrcPath);
      if (await f.exists()) lines = parseLrc(await f.readAsString());
    } catch (_) {}
    if (mounted) {
      setState(() {
        _current = t;
        _lines = lines;
        _drag = null;
      });
    }
    try {
      await _player.setFilePath(t.audioPath);
      _player.play();
    } catch (_) {
      _msg('No se pudo reproducir el archivo');
    }
  }

  Future<void> _next() async {
    if (_queue.isEmpty) return;
    if (_idx + 1 < _queue.length) {
      await _playQueue(_queue, _idx + 1);
    } else {
      await _player.seek(Duration.zero);
      await _player.pause();
    }
  }

  Future<void> _prev() async {
    if (_queue.isEmpty) return;
    if (_player.position > const Duration(seconds: 3) || _idx <= 0) {
      await _player.seek(Duration.zero);
    } else {
      await _playQueue(_queue, _idx - 1);
    }
  }

  Future<void> _toggle() async {
    if (_current == null) {
      if (_library.isNotEmpty) await _playQueue(_library, 0);
      return;
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      _player.play();
    }
  }

  Future<void> _delete(Track t) async {
    try {
      for (final p in [t.audioPath, t.lrcPath, t.thumbPath, t.metaPath]) {
        final f = File(p);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    if (_current?.id == t.id) {
      await _player.stop();
      setState(() {
        _current = null;
        _lines = [];
        _queue = [];
        _idx = -1;
      });
    }
    await _loadLibrary();
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: TextField(
        controller: _searchCtl,
        textInputAction: TextInputAction.search,
        onSubmitted: _search,
        decoration: InputDecoration(
          hintText: 'buscar en youtube music',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: () => _search(_searchCtl.text),
          ),
          filled: true,
          fillColor: const Color(0xFF1E1E1E),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _tabs() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
                value: 0,
                icon: Icon(Icons.graphic_eq, size: 18),
                label: Text('Brat')),
            ButtonSegment(
                value: 1,
                icon: Icon(Icons.search, size: 18),
                label: Text('Buscar')),
            ButtonSegment(
                value: 2,
                icon: Icon(Icons.download_done, size: 18),
                label: Text('Biblioteca')),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
      ),
    );
  }

  Widget _playerTab() {
    final bc = bratColors[_bratIndex];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          ValueListenableBuilder<Duration>(
            valueListenable: _pos,
            builder: (_, p, __) => BratBox(
              lines: _lines,
              pos: p,
              color: bc,
              fallback: _current == null
                  ? 'busca y descarga una canción'
                  : _current!.title,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < bratColors.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _bratIndex = i),
                  child: Container(
                    width: 38,
                    height: 38,
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: bratColors[i].bg,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: i == _bratIndex ? limeColor : Colors.white30,
                        width: i == _bratIndex ? 3 : 1.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            bc.name,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _thumbNetwork(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        width: 80,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: 80,
          height: 56,
          color: Colors.white12,
          child: const Icon(Icons.music_note),
        ),
      ),
    );
  }

  Widget _searchTab() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text('escribe arriba para buscar música',
            style: TextStyle(color: Colors.white54)),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final v = _results[i];
        final id = v.id.value;
        final downloaded = _library.any((t) => t.id == id);
        final prog = _progress[id];
        Widget trailing;
        if (prog != null) {
          trailing = SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              value: prog > 0 ? prog : null,
              strokeWidth: 3,
            ),
          );
        } else if (downloaded) {
          trailing = const Icon(Icons.check_circle, color: limeColor);
        } else {
          trailing = const Icon(Icons.download);
        }
        return ListTile(
          leading: _thumbNetwork(v.thumbnails.mediumResUrl),
          title: Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${v.author} · ${v.duration != null ? fmt(v.duration!) : '--:--'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailing,
          onTap: prog != null ? null : () => _onResultTap(v),
        );
      },
    );
  }

  Widget _libraryTab() {
    if (_library.isEmpty) {
      return const Center(
        child: Text('tu biblioteca offline está vacía',
            style: TextStyle(color: Colors.white54)),
      );
    }
    return ListView.builder(
      itemCount: _library.length,
      itemBuilder: (_, i) {
        final t = _library[i];
        final thumb = File(t.thumbPath);
        final playing = _current?.id == t.id;
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: thumb.existsSync()
                ? Image.file(thumb, width: 56, height: 56, fit: BoxFit.cover)
                : Container(
                    width: 56,
                    height: 56,
                    color: Colors.white12,
                    child: const Icon(Icons.music_note),
                  ),
          ),
          title: Text(
            t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: playing ? limeColor : null),
          ),
          subtitle: Text(
            '${t.artist} · ${fmt(Duration(milliseconds: t.durationMs))}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(t),
          ),
          onTap: () {
            setState(() => _tab = 0);
            _playQueue(_library, i);
          },
        );
      },
    );
  }

  Widget _controls() {
    final t = _current;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF161616),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            t?.title ?? 'sin reproducir',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          Text(
            t?.artist ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          AnimatedBuilder(
            animation: Listenable.merge([_pos, _dur]),
            builder: (_, __) {
              final maxMs = math
                  .max(_dur.value.inMilliseconds, t?.durationMs ?? 0)
                  .clamp(1, 1 << 31)
                  .toDouble();
              final cur = (_drag ?? _pos.value.inMilliseconds.toDouble())
                  .clamp(0.0, maxMs);
              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: limeColor,
                      thumbColor: limeColor,
                      inactiveTrackColor: Colors.white24,
                    ),
                    child: Slider(
                      value: cur,
                      min: 0,
                      max: maxMs,
                      onChanged: (v) => setState(() => _drag = v),
                      onChangeEnd: (v) async {
                        await _player.seek(Duration(milliseconds: v.round()));
                        if (mounted) setState(() => _drag = null);
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(fmt(Duration(milliseconds: cur.round())),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white54)),
                        Text(fmt(Duration(milliseconds: maxMs.round())),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white54)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 38,
                icon: const Icon(Icons.skip_previous),
                onPressed: _prev,
              ),
              const SizedBox(width: 12),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (_, snap) {
                  final st = snap.data;
                  final playing = st?.playing ?? false;
                  final busy = st?.processingState == ProcessingState.loading ||
                      st?.processingState == ProcessingState.buffering;
                  return Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                        color: limeColor, shape: BoxShape.circle),
                    child: busy
                        ? const Padding(
                            padding: EdgeInsets.all(18),
                            child: CircularProgressIndicator(
                              color: Colors.black,
                              strokeWidth: 3,
                            ),
                          )
                        : IconButton(
                            iconSize: 38,
                            color: Colors.black,
                            icon: Icon(
                                playing ? Icons.pause : Icons.play_arrow),
                            onPressed: _toggle,
                          ),
                  );
                },
              ),
              const SizedBox(width: 12),
              IconButton(
                iconSize: 38,
                icon: const Icon(Icons.skip_next),
                onPressed: _next,
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _searchBar(),
            _tabs(),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _playerTab(),
                  _searchTab(),
                  _libraryTab(),
                ],
              ),
            ),
            _controls(),
          ],
        ),
      ),
    );
  }
}
