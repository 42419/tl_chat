import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tailscale/tailscale.dart';

/// Tailscale 封装：负责初始化嵌入式节点、上线注册、状态查询与 TCP 拨号。
///
/// 生命周期：
///   1. [initStateDir] 确定状态目录（应用支持目录下的 tailscale/）
///   2. [status] 判断是否已注册（NodeState）
///   3. [up] 首次注册需要 authKey，之后可省略
///   4. [dial] 通过 tailnet TCP 连接中心服务
class TailscaleService {
  String? _stateDir;

  /// 确定并保存状态目录（幂等）。
  Future<String> initStateDir() async {
    if (_stateDir != null) return _stateDir!;
    String dir;
    try {
      final support = await getApplicationSupportDirectory();
      dir = p.join(support.path, 'tailscale');
    } catch (_) {
      dir = p.join('.', 'tailscale_demo');
    }
    Tailscale.init(stateDir: dir, logLevel: TailscaleLogLevel.error);
    _stateDir = dir;
    return dir;
  }

  /// 当前节点状态（先 initStateDir）。
  Future<TailscaleStatus> status() async {
    await initStateDir();
    return Tailscale.instance.status();
  }

  /// 上线/注册。首次（noState）必须传 authKey；之后重连可省略。
  Future<TailscaleStatus> up({
    required String hostname,
    String? authKey,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    await initStateDir();
    return Tailscale.instance.up(
      hostname: hostname,
      authKey: authKey,
      timeout: timeout,
    );
  }

  /// tailnet 节点清单（用于解析服务器地址 / 通讯录）。
  Future<List<TailscaleNode>> nodes() async {
    await initStateDir();
    return Tailscale.instance.nodes();
  }

  /// 通过 tailnet 拨号 TCP。
  Future<TailscaleConnection> dial(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await initStateDir();
    return Tailscale.instance.tcp.dial(host, port, timeout: timeout);
  }
}
