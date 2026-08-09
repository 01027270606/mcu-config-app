import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';

void main() {
  runApp(const McuApp());
}

class McuApp extends StatelessWidget {
  const McuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MCU Config Manager',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const McuHomeScreen(),
    );
  }
}

class McuHomeScreen extends StatefulWidget {
  const McuHomeScreen({super.key});

  @override
  State<McuHomeScreen> createState() => _McuHomeScreenState();
}

class _McuHomeScreenState extends State<McuHomeScreen> {
  // MCU 정보
  final List<Map<String, String>> mcuList = [
    {'name': 'MCU A', 'ip': '192.168.100.11'},
    {'name': 'MCU B', 'ip': '192.168.100.12'},
    {'name': 'MCU C', 'ip': '192.168.100.13'},
  ];

  int selectedMcuIndex = 0;
  bool isConnected = false;
  bool isLoading = false;
  
  // Conf 파일 파싱 데이터 (Key-Value)
  Map<String, String> configMap = {};
  
  // Text Controller 임시 저장용
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    _loadRemoteConfig();
  }

  // SSH 접속 및 dbcs_setting.conf 로드
  Future<void> _loadRemoteConfig() async {
    setState(() {
      isLoading = true;
      isConnected = false;
    });

    final targetIp = mcuList[selectedMcuIndex]['ip']!;

    try {
      final socket = await SSHSocket.connect(targetIp, 22, timeout: const Duration(seconds: 3));
      final client = SSHClient(
        socket,
        username: 'root',
        onPasswordRequest: () => 'dbcs',
      );

      final result = await client.run('cat /dbcs/config/dbcs_setting.conf');
      final content = utf8.decode(result);

      _parseConfig(content);

      client.close();
      await socket.close();

      setState(() {
        isConnected = true;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        isConnected = false;
      });
      _showSnackBar('SSH 접속 실패 ($targetIp): $e');
    }
  }

  // Conf 파일 파싱
  void _parseConfig(String content) {
    Map<String, String> tempMap = {};
    List<String> lines = const LineSplitter().convert(content);

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.contains('=')) {
        var parts = line.split('=');
        var key = parts[0].trim();
        var value = parts.sublist(1).join('=').trim();
        tempMap[key] = value;
      }
    }

    setState(() {
      configMap = tempMap;
      _controllers.clear();
      configMap.forEach((key, value) {
        _controllers[key] = TextEditingController(text: value);
      });
    });
  }

  // 저장 및 SFTP 덮어쓰기 (백업 포함)
  Future<void> _saveRemoteConfig() async {
    if (!isConnected) {
      _showSnackBar('MCU에 먼저 연결해야 합니다.');
      return;
    }

    setState(() => isLoading = true);
    final targetIp = mcuList[selectedMcuIndex]['ip']!;

    try {
      final socket = await SSHSocket.connect(targetIp, 22, timeout: const Duration(seconds: 5));
      final client = SSHClient(
        socket,
        username: 'root',
        onPasswordRequest: () => 'dbcs',
      );

      // 1. 기존 파일 백업
      await client.run('cp /dbcs/config/dbcs_setting.conf /dbcs/config/dbcs_setting.conf.bak');

      // 2. 새로운 내역으로 파일 생성
      StringBuffer sb = StringBuffer();
      sb.writeln('# Modified by Mobile App');
      configMap.forEach((key, value) {
        sb.writeln('$key=$value');
      });

      // Remote 파일 전달
      final sftp = await client.sftp();
      final file = await sftp.open(
        '/dbcs/config/dbcs_setting.conf',
        mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.truncate,
      );
      await file.writeBytes(utf8.encode(sb.toString()));

      client.close();
      await socket.close();

      setState(() => isLoading = false);
      _showSnackBar('저장 및 백업 완료! (dbcs_setting.conf.bak)');
    } catch (e) {
      setState(() => isLoading = false);
      _showSnackBar('저장 실패: $e');
    }
  }

  // 원격 데몬 재시작
  Future<void> _restartDaemon() async {
    final targetIp = mcuList[selectedMcuIndex]['ip']!;
    try {
      final socket = await SSHSocket.connect(targetIp, 22, timeout: const Duration(seconds: 3));
      final client = SSHClient(socket, username: 'root', onPasswordRequest: () => 'dbcs');
      await client.run('systemctl restart dbcs');
      client.close();
      _showSnackBar('DBCS 데몬 재시작 명령 전송 완료');
    } catch (e) {
      _showSnackBar('재시작 실패: $e');
    }
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCU Setting Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRemoteConfig,
          )
        ],
      ),
      body: Column(
        children: [
          // 1. MCU 선택 탭
          Row(
            children: List.generate(mcuList.length, (index) {
              return Expanded(
                child: InkWell(
                  onTap: () {
                    setState(() => selectedMcuIndex = index);
                    _loadRemoteConfig();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    color: selectedMcuIndex == index ? Colors.blue : Colors.grey[200],
                    child: Center(
                      child: Text(
                        mcuList[index]['name']!,
                        style: TextStyle(
                          color: selectedMcuIndex == index ? Colors.white : Colors.black,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          
          // 2. 상태 헤더
          Container(
            padding: const EdgeInsets.all(8),
            color: isConnected ? Colors.green[100] : Colors.red[100],
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 14,
                  color: isConnected ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  '${mcuList[selectedMcuIndex]['ip']} - ${isConnected ? '연결됨' : '연결 안됨'}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),

          // 3. 로딩바 및 설정 항목 리스트
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : configMap.isEmpty
                    ? const Center(child: Text('설정 정보를 불러오지 못했습니다.'))
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          _buildSectionTitle('제한 입력 항목 (드롭다운)'),
                          _buildDropdownItem('TypeCCU', ['0', '1', '2', '3', '4']),
                          _buildDropdownItem('CdSerialType', ['1', '2', '3', '4', '5']),
                          _buildDropdownItem('VesType', ['1', '2']),
                          
                          const Divider(height: 30),
                          _buildSectionTitle('주요 스위치 및 일반 설정'),
                          _buildSwitchItem('json_use'),
                          _buildSwitchItem('use_sftp'),
                          _buildSwitchItem('use_err_filter'),
                          
                          const Divider(height: 30),
                          _buildSectionTitle('전체 키-값 상세 목록'),
                          ...configMap.keys.map((key) {
                            if (['TypeCCU', 'CdSerialType', 'VesType', 'json_use', 'use_sftp', 'use_err_filter'].contains(key)) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: TextField(
                                controller: _controllers[key],
                                decoration: InputDecoration(
                                  labelText: key,
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                ),
                                onChanged: (val) => configMap[key] = val,
                              ),
                            );
                          }),
                        ],
                      ),
          ),

          // 4. 하단 동작 버튼
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.grey[100], border: const Border(top: BorderSide(color: Colors.grey))),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saveRemoteConfig,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                    child: const Text('MCU 저장 및 백업'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _restartDaemon,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                    child: const Text('데몬 재시작'),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue)),
    );
  }

  // 드롭다운 위젯
  Widget _buildDropdownItem(String key, List<String> options) {
    String currentValue = configMap[key] ?? options.first;
    if (!options.contains(currentValue)) currentValue = options.first;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(key, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          DropdownButton<String>(
            value: currentValue,
            items: options.map((opt) => DropdownMenuItem(value: opt, child: Text(opt))).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() => configMap[key] = val);
              }
            },
          ),
        ],
      ),
    );
  }

  // 토글 스위치 위젯
  Widget _buildSwitchItem(String key) {
    bool isSwitched = configMap[key] == '1';
    return SwitchListTile(
      title: Text(key),
      value: isSwitched,
      onChanged: (val) {
        setState(() {
          configMap[key] = val ? '1' : '0';
        });
      },
    );
  }
}
