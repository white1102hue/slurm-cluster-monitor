import 'package:flutter/material.dart';
import '../models/slurm_models.dart';
import '../services/monitor_controller.dart';
import '../services/slurm_ssh_service.dart';
import '../services/key_file_service.dart';
import 'app_theme.dart';

class ServerEditor extends StatefulWidget {
  const ServerEditor({super.key, required this.controller, this.server});
  final MonitorController controller;
  final ServerConfig? server;
  @override
  State<ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<ServerEditor> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _host = TextEditingController(),
      _port = TextEditingController(text: '22');
  final _user = TextEditingController(),
      _password = TextEditingController(),
      _key = TextEditingController(),
      _passphrase = TextEditingController();
  AuthType _auth = AuthType.password;
  bool _busy = false, _showPassword = false;
  bool _pickingKey = false;
  String? _keyFileName;
  String? _error;
  String _fingerprint = '', _trustedEndpoint = '';
  @override
  void initState() {
    super.initState();
    final s = widget.server;
    if (s != null) {
      _name.text = s.name;
      _host.text = s.host;
      _port.text = '${s.port}';
      _user.text = s.username;
      _password.text = s.password;
      _key.text = s.privateKey;
      _passphrase.text = s.passphrase;
      _auth = s.authType;
      _fingerprint = s.fingerprint;
      _trustedEndpoint = '${s.host}:${s.port}';
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _user,
      _password,
      _key,
      _passphrase,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _required(String? s) =>
      s == null || s.trim().isEmpty ? '此项不能为空' : null;
  ServerConfig _config() => ServerConfig(
    id: widget.server?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: _name.text.trim().isEmpty ? _host.text.trim() : _name.text.trim(),
    host: _host.text.trim(),
    port: int.parse(_port.text.trim()),
    username: _user.text.trim(),
    authType: _auth,
    password: _auth == AuthType.password ? _password.text : '',
    privateKey: _auth == AuthType.privateKey ? _key.text.trim() : '',
    passphrase: _auth == AuthType.privateKey ? _passphrase.text : '',
    fingerprint: _fingerprint,
    enabled: widget.server?.enabled ?? true,
  );
  Future<bool> _verifyHost() async {
    final observed = await SlurmSshService.probeHost(_config());
    if (!mounted) return false;
    if (_fingerprint == observed.fingerprint &&
        _trustedEndpoint == '${_host.text.trim()}:${_port.text.trim()}') {
      return true;
    }
    final trusted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(_fingerprint.isNotEmpty ? '确认变更后的 SSH 主机' : '确认 SSH 主机身份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_host.text.trim()}:${_port.text.trim()}'),
            SizedBox(height: 16),
            Text(observed.type, style: TextStyle(color: context.muted)),
            SizedBox(height: 8),
            SelectableText(observed.fingerprint),
            SizedBox(height: 16),
            Text('请与管理员提供的 SHA256 指纹核对。确认后，才会向服务器发送登录凭据。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消连接'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('信任此主机'),
          ),
        ],
      ),
    );
    if (trusted == true) {
      _fingerprint = observed.fingerprint;
      _trustedEndpoint = '${_host.text.trim()}:${_port.text.trim()}';
      return true;
    }
    return false;
  }

  Future<void> _save({bool testOnly = false}) async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final service = SlurmSshService();
    try {
      if (!await _verifyHost()) return;
      final config = _config();
      final snapshot = await service.fetch(config);
      if (!mounted) return;
      if (testOnly) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '连接成功 · ${snapshot.activeJobs.length} 个活跃作业${snapshot.warnings.isEmpty ? '' : '；${snapshot.warnings.join('；')}'}',
            ),
          ),
        );
      } else {
        await widget.controller.saveServer(config);
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      service.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickKey() async {
    setState(() {
      _busy = true;
      _pickingKey = true;
      _error = null;
    });
    try {
      final file = await KeyFileService.pick();
      if (file != null && mounted) {
        setState(() {
          _key.text = file.content;
          _keyFileName = file.name;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '无法读取密钥文件，请重试或粘贴私钥内容',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _pickingKey = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.server == null ? '添加服务器' : '编辑服务器')),
    body: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640),
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '连接你的集群',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              Text(
                '通过 SSH 安全直连，仅采集当前账号的作业。',
                style: TextStyle(color: context.muted),
              ),
              SizedBox(height: 28),
              TextFormField(
                controller: _name,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: '服务器别名',
                  hintText: '例如：课题组 GPU 集群',
                ),
              ),
              SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _host,
                      enabled: !_busy,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: '主机地址',
                        hintText: 'IP 或域名',
                      ),
                      validator: (s) =>
                          _required(s) ??
                          (RegExp(r'[\s/\\]').hasMatch(s!)
                              ? '只需填写 IP 或域名'
                              : null),
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _port,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: '端口'),
                      validator: (s) {
                        final n = int.tryParse(s ?? '');
                        return n == null || n < 1 || n > 65535
                            ? '1–65535'
                            : null;
                      },
                    ),
                  ),
                ],
              ),
              SizedBox(height: 16),
              TextFormField(
                controller: _user,
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(labelText: 'SSH 用户名'),
                validator: _required,
              ),
              SizedBox(height: 24),
              SegmentedButton<AuthType>(
                segments: [
                  ButtonSegment(
                    value: AuthType.password,
                    icon: Icon(Icons.password),
                    label: Text('密码'),
                  ),
                  ButtonSegment(
                    value: AuthType.privateKey,
                    icon: Icon(Icons.key_outlined),
                    label: Text('SSH 私钥'),
                  ),
                ],
                selected: {_auth},
                onSelectionChanged: _busy
                    ? null
                    : (s) => setState(() => _auth = s.first),
              ),
              SizedBox(height: 20),
              if (_auth == AuthType.password)
                TextFormField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  validator: _required,
                  decoration: InputDecoration(
                    labelText: 'SSH 密码',
                    suffixIcon: IconButton(
                      tooltip: _showPassword ? '隐藏密码' : '显示密码',
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword ? Icons.visibility_off : Icons.visibility,
                      ),
                    ),
                  ),
                )
              else ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickKey,
                  icon: Icon(Icons.file_open_outlined),
                  label: Text(
                    _keyFileName == null ? '选择私钥文件' : '已导入：$_keyFileName',
                  ),
                ),
                SizedBox(height: 12),
                TextFormField(
                  controller: _key,
                  enabled: !_busy,
                  minLines: 5,
                  maxLines: 8,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: '私钥内容',
                    alignLabelWithHint: true,
                    hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                    helperText: '支持 OpenSSH、RSA PEM、Ed25519',
                  ),
                  validator: (s) =>
                      _required(s) ??
                      (!s!.contains('PRIVATE KEY-----') ? '请粘贴完整的私钥内容' : null),
                ),
                SizedBox(height: 16),
                TextFormField(
                  controller: _passphrase,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: '私钥口令 Passphrase（可选）'),
                ),
              ],
              SizedBox(height: 24),
              if (_fingerprint.isNotEmpty) ...[
                Text(
                  '已确认的主机指纹',
                  style: TextStyle(color: context.muted, fontSize: 12),
                ),
                SizedBox(height: 8),
                SelectableText(_fingerprint, style: TextStyle(fontSize: 11)),
                SizedBox(height: 20),
              ],
              if (_error != null) ...[
                SelectableText(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                SizedBox(height: 16),
              ],
              if (_busy)
                Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: LinearProgressIndicator(),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : () => _save(),
                icon: Icon(Icons.check),
                label: Text(
                  _pickingKey
                      ? '正在读取密钥…'
                      : _busy
                      ? '正在验证连接…'
                      : '验证并保存服务器',
                ),
              ),
              SizedBox(height: 10),
              OutlinedButton(
                onPressed: _busy ? null : () => _save(testOnly: true),
                child: Text('仅测试连接'),
              ),
              SizedBox(height: 18),
              Text(
                '凭据仅保存在本机加密存储中。首次连接需要确认主机指纹；保存后在首页启动后台监控。',
                style: TextStyle(
                  color: context.muted,
                  fontSize: 12,
                  height: 1.7,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
