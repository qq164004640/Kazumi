import 'package:kazumi/modules/danmaku/custom_danmaku_client.dart';
import 'package:kazumi/modules/danmaku/custom_danmaku_server_config.dart';
import 'package:kazumi/modules/danmaku/danmaku_ch_convert.dart';
import 'package:kazumi/modules/danmaku/danmaku_episode_response.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

class DanmakuApi {
  static final DanmakuClient _client = DanmakuClient.instance;

  /// 用户配置了可用的自定义弹幕服务器 (danmu_api / LogVar 兼容) 时为 true。
  /// 所有弹幕请求在此统一分发, 关闭时行为与改动前完全一致。
  static bool get _useCustomServer => CustomDanmakuServerConfig.isEnabled;

  static Future<int> getDanDanBangumiIDByBgmBangumiID(int bgmBangumiID) async {
    // 自定义弹幕服务器 (danmu_api) 不提供 bgmtv ID 映射,
    // 播放取弹幕改走 getCustomDanmakuByBangumiName 的标题匹配路径。
    if (_useCustomServer) {
      return 0;
    }
    final path = ApiEndpoints.formatUrl(
      ApiEndpoints.dandanAPIInfoByBgmBangumiId,
      [bgmBangumiID],
    );
    final endPoint = ApiEndpoints.dandanAPIDomain + path;
    final jsonData = await _client.get(endPoint);
    return DanmakuEpisodeResponse.fromJson(jsonData).bangumiId;
  }

  static Future<DanmakuEpisodeResponse> getDanDanEpisodesByDanDanBangumiID(
    int bangumiID,
  ) async {
    if (_useCustomServer) {
      return CustomDanmakuClient.instance.getEpisodes(bangumiID);
    }
    final path = ApiEndpoints.dandanAPIInfo + bangumiID.toString();
    final endPoint = ApiEndpoints.dandanAPIDomain + path;
    final jsonData = await _client.get(endPoint);
    return DanmakuEpisodeResponse.fromJson(jsonData);
  }

  // v2 episode search avoids the anime search's 25-result cap.
  // Fetch full episode lists separately; search results can truncate them.
  static Future<DanmakuSearchResponse> searchAnimes(String title) async {
    if (_useCustomServer) {
      return CustomDanmakuClient.instance.searchAnimes(title);
    }
    final endPoint =
        ApiEndpoints.dandanAPIDomain + ApiEndpoints.dandanAPISearchEpisodes;
    final jsonData = await _client.get(
      endPoint,
      queryParameters: {'anime': title, 'v2': 'true'},
    );
    return DanmakuSearchResponse.fromJson(jsonData);
  }

  static Future<List<DanmakuEntry>> getDanDanmaku(
    int bangumiID,
    int episode,
  ) async {
    if (bangumiID == 0) {
      return [];
    }
    // Automatic matching relies on an undocumented episode ID convention.
    return _getComments('$bangumiID${episode.toString().padLeft(4, '0')}');
  }

  static Future<List<DanmakuEntry>> getDanDanmakuByEpisodeID(
      int episodeID) async {
    // 手动选择分集时 episodeID 来自服务端返回的分集列表, 是真实 ID。
    if (_useCustomServer) {
      return CustomDanmakuClient.instance.getComments(episodeID);
    }
    return _getComments(episodeID.toString());
  }

  static Future<List<DanmakuEntry>> _getComments(String episodeID) async {
    final endPoint =
        '${ApiEndpoints.dandanAPIDomain}${ApiEndpoints.dandanAPIComment}$episodeID';
    final conversion = DanmakuChConvert.fromValue(
      GStorage.getSetting(SettingsKeys.danmakuChConvert),
    );
    KazumiLogger().i('Danmaku: final request URL $endPoint');
    final jsonData = await _client.get(
      endPoint,
      queryParameters: {
        'withRelated': 'true',
        'chConvert': conversion.value.toString(),
      },
    );
    final List<dynamic> comments = jsonData['comments'];
    return [for (final comment in comments) DanmakuEntry.fromJson(comment)];
  }

  // ===================== 自定义弹幕服务器 (danmu_api / LogVar) =====================

  /// 播放时按番剧标题自动匹配并拉取弹幕。
  ///
  /// danmu_api 不兼容弹弹play 的 bgmtv ID 映射与 animeId*10000+集数 的
  /// commentId 约定, 因此先经 match 接口按 "标题 E集数" 解析真实 episodeId,
  /// 失败时退化为 搜索->取首个番剧->按集序取分集。
  static Future<List<DanmakuEntry>> getCustomDanmakuByBangumiName(
    String bangumiName,
    int episode,
  ) async {
    if (!_useCustomServer) {
      return const [];
    }
    final title = bangumiName.trim();
    if (title.isEmpty || episode < 1) {
      return const [];
    }
    if (CustomDanmakuServerConfig.autoMatch) {
      final episodeId = await CustomDanmakuClient.instance
          .matchEpisodeId(fileName: _buildMatchFileName(title, episode));
      if (episodeId != null) {
        return CustomDanmakuClient.instance.getComments(episodeId);
      }
    }
    return _getCustomDanmakuByEpisodeOrder(title, episode);
  }

  /// 匹配用的文件名。danmu_api 的 parseFileName 兼容 "S01E05" / "第5集"
  /// 等网盘命名格式, "E05" 对 bgm.tv 条目内的绝对集数最稳妥。
  static String _buildMatchFileName(String title, int episode) {
    return '$title E${episode.toString().padLeft(2, '0')}';
  }

  /// 退化路径: 搜索番剧 -> 取首个结果的完整分集列表 -> 按集序取第 episode 集。
  static Future<List<DanmakuEntry>> _getCustomDanmakuByEpisodeOrder(
    String title,
    int episode,
  ) async {
    try {
      final searchResponse =
          await CustomDanmakuClient.instance.searchAnimes(title);
      if (searchResponse.animes.isEmpty) {
        return const [];
      }
      final bangumiID = searchResponse.animes.first.animeId;
      final episodes =
          await CustomDanmakuClient.instance.getEpisodes(bangumiID);
      if (episodes.episodes.length < episode) {
        return const [];
      }
      return CustomDanmakuClient.instance
          .getComments(episodes.episodes[episode - 1].episodeId);
    } catch (e) {
      KazumiLogger().w('Danmaku: custom server fallback match failed',
          error: e);
      return const [];
    }
  }
}
