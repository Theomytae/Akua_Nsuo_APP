import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// --- BLE UUIDs (Must match your ESP32 firmware) ---
const String esp32ServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String debugCharUuid = 'f4a1f353-8576-4993-81b4-1101b0596348';
const String uptimeCharUuid = 'a8f5f247-3665-448d-8a0c-6b3a2a3e592b';
const String rebootCharUuid = 'b2d49a43-6c84-474c-a496-02d997e54f8e';
const String onTimeCharUuid = 'c8a3cadd-536c-4819-9154-10a110a19a4e';
const String offTimeCharUuid = 'd8a3cadd-536c-4819-9154-10a110a19a4f';
// --- NEW UUIDs for Pump Power ---
const String pumpPowerVisibilityCharUuid = 'e0c47e8c-838a-42d3-9b09-2495304e28e4';
const String pumpPowerValueCharUuid = 'e1c47e8c-838a-42d3-9b09-2495304e28e5';


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Controller',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF111827),
        primaryColor: const Color(0xFF2563eb),
        cardColor: const Color(0xFF1f2937),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF1f2937),
          selectedItemColor: Color(0xFF2563eb),
          unselectedItemColor: Colors.grey,
        ),
      ),
      home: const ESP32ControllerScreen(),
    );
  }
}

class ESP32ControllerScreen extends StatefulWidget {
  const ESP32ControllerScreen({super.key});

  @override
  State<ESP32ControllerScreen> createState() => _ESP32ControllerScreenState();
}

class _ESP32ControllerScreenState extends State<ESP32ControllerScreen> {
  // --- State Variables ---
  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  String _status = 'Disconnected';
  final TextEditingController _timerOnController = TextEditingController();
  final TextEditingController _timerOffController = TextEditingController();
  final TextEditingController _pumpPowerController = TextEditingController();
  Map<String, dynamic>? _debugData;
  String _uptime = '00:00:00';
  int _selectedIndex = 0;
  bool _showPumpPowerSection = false;

  // --- Characteristics ---
  BluetoothCharacteristic? _rebootChar;
  BluetoothCharacteristic? _timerOnChar;
  BluetoothCharacteristic? _timerOffChar;
  BluetoothCharacteristic? _pumpPowerChar;
  StreamSubscription? _debugSubscription;
  StreamSubscription? _uptimeSubscription;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    if (statuses[Permission.bluetoothScan] != PermissionStatus.granted ||
        statuses[Permission.bluetoothConnect] != PermissionStatus.granted ||
        statuses[Permission.location] != PermissionStatus.granted) {
       _showErrorDialog('Permissions Required', 'Please grant Bluetooth and Location permissions for the app to function.');
    }
  }

  @override
  void dispose() {
    _connectionStateSubscription?.cancel();
    _debugSubscription?.cancel();
    _uptimeSubscription?.cancel();
    _connectedDevice?.disconnect();
    _timerOnController.dispose();
    _timerOffController.dispose();
    _pumpPowerController.dispose();
    super.dispose();
  }

  void _scanAndConnect() async {
    var scanPerm = await Permission.bluetoothScan.status;
    if (!scanPerm.isGranted) {
      _showErrorDialog('Permissions Required', 'Bluetooth Scan permission must be granted to find devices.');
      _requestPermissions();
      return;
    }

    setState(() {
      _status = 'Scanning...';
    });
    
    StreamSubscription? scanSubscription;

    try {
      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        if (results.isNotEmpty) {
          final device = results.first.device;
          FlutterBluePlus.stopScan();
          scanSubscription?.cancel();
          _connectToDevice(device);
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [Guid(esp32ServiceUuid)],
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      _showErrorDialog('Scan Error', 'Could not start scanning. Error: ${e.toString()}');
      setState(() { _status = 'Scan Failed'; });
    }
    
    // Fallback in case scan times out
    await Future.delayed(const Duration(seconds: 15));
    if (_connectedDevice == null) {
        FlutterBluePlus.stopScan();
        scanSubscription?.cancel();
        if(mounted) {
            setState(() {
                _status = 'No ESP32 device found.';
            });
        }
    }
  }

  void _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _status = 'Connecting to ${device.platformName}...';
    });
    try {
      await device.connect();
      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });
      _onConnected(device);
    } catch (e) {
      _showErrorDialog('Connection Error', 'Failed to connect. Error: ${e.toString()}');
      _onDisconnected();
    }
  }

  void _onConnected(BluetoothDevice device) async {
    setState(() {
      _connectedDevice = device;
      _status = 'Connected to ${device.platformName}';
    });

    List<BluetoothService> services = await device.discoverServices();
    BluetoothCharacteristic? pumpVisibilityChar;

    for (var service in services) {
      if (service.uuid == Guid(esp32ServiceUuid)) {
        for (var char in service.characteristics) {
          if (char.uuid == Guid(rebootCharUuid)) _rebootChar = char;
          if (char.uuid == Guid(debugCharUuid)) _monitorDebug(char);
          if (char.uuid == Guid(uptimeCharUuid)) _monitorUptime(char);
          if (char.uuid == Guid(onTimeCharUuid)) _timerOnChar = char;
          if (char.uuid == Guid(offTimeCharUuid)) _timerOffChar = char;
          if (char.uuid == Guid(pumpPowerValueCharUuid)) _pumpPowerChar = char;
          if (char.uuid == Guid(pumpPowerVisibilityCharUuid)) pumpVisibilityChar = char;
        }
      }
    }

    // After finding characteristics, check for pump power visibility
    if (pumpVisibilityChar != null) {
      await _checkPumpPowerVisibility(pumpVisibilityChar);
    }

    _readTimerOn();
    _readTimerOff();
  }

  void _onDisconnected() {
    setState(() {
      _connectedDevice = null;
      _status = 'Disconnected';
      _debugData = null;
      _uptime = '00:00:00';
      _timerOnController.text = '';
      _timerOffController.text = '';
      _pumpPowerController.text = '';
      _showPumpPowerSection = false;
      _selectedIndex = 0; // Reset to connection tab
    });
    _debugSubscription?.cancel();
    _uptimeSubscription?.cancel();
  }

  void _disconnectDevice() async {
    await _connectedDevice?.disconnect();
  }
  
  void _rebootDevice() async {
    if (_rebootChar != null) {
      await _rebootChar!.write([1]);
    }
  }
  
  void _monitorDebug(BluetoothCharacteristic char) async {
    await char.setNotifyValue(true);
    _debugSubscription = char.lastValueStream.listen((value) {
      final jsonString = utf8.decode(value);
      try {
        setState(() { _debugData = jsonDecode(jsonString); });
      } catch (e) { /* Ignore malformed JSON */ }
    });
  }
  
  void _monitorUptime(BluetoothCharacteristic char) async {
    await char.setNotifyValue(true);
    _uptimeSubscription = char.lastValueStream.listen((value) {
      if (value.length >= 4) {
        final secondsTotal = ByteData.sublistView(Uint8List.fromList(value)).getUint32(0, Endian.little);
        final duration = Duration(seconds: secondsTotal);
        String twoDigits(int n) => n.toString().padLeft(2, '0');
        final hours = twoDigits(duration.inHours);
        final minutes = twoDigits(duration.inMinutes.remainder(60));
        final seconds = twoDigits(duration.inSeconds.remainder(60));
        setState(() { _uptime = '$hours:$minutes:$seconds'; });
      }
    });
  }

  void _readTimerOn() async {
    if (_timerOnChar != null) {
      List<int> value = await _timerOnChar!.read();
      if (value.length >= 4) {
        final intVal = ByteData.sublistView(Uint8List.fromList(value)).getUint32(0, Endian.little);
        setState(() { _timerOnController.text = intVal.toString(); });
      }
    }
  }

  void _sendTimerOn() async {
    if (_timerOnChar != null && _timerOnController.text.isNotEmpty) {
      final int? val = int.tryParse(_timerOnController.text);
      if (val != null) {
        final byteData = ByteData(4)..setUint32(0, val, Endian.little);
        await _timerOnChar!.write(byteData.buffer.asUint8List());
      }
    }
  }
  
  void _readTimerOff() async {
    if (_timerOffChar != null) {
      List<int> value = await _timerOffChar!.read();
      if (value.length >= 4) {
        final intVal = ByteData.sublistView(Uint8List.fromList(value)).getUint32(0, Endian.little);
        setState(() { _timerOffController.text = intVal.toString(); });
      }
    }
  }

  void _sendTimerOff() async {
    if (_timerOffChar != null && _timerOffController.text.isNotEmpty) {
      final int? val = int.tryParse(_timerOffController.text);
      if (val != null) {
        final byteData = ByteData(4)..setUint32(0, val, Endian.little);
        await _timerOffChar!.write(byteData.buffer.asUint8List());
      }
    }
  }

  Future<void> _checkPumpPowerVisibility(BluetoothCharacteristic char) async {
    List<int> value = await char.read();
    if (value.isNotEmpty && value[0] == 1) {
      setState(() {
        _showPumpPowerSection = true;
      });
      // If visible, read its initial value
      _readPumpPower();
    }
  }

  void _readPumpPower() async {
    if (_pumpPowerChar != null) {
      List<int> value = await _pumpPowerChar!.read();
      if (value.isNotEmpty) {
        // Convert byte (0-255) back to percentage
        final percentage = (value[0] / 2.55).round();
        setState(() {
          _pumpPowerController.text = percentage.toString();
        });
      }
    }
  }

  void _sendPumpPower() async {
    if (_pumpPowerChar != null && _pumpPowerController.text.isNotEmpty) {
      final int? percentage = int.tryParse(_pumpPowerController.text);
      if (percentage != null && percentage >= 0 && percentage <= 100) {
        // Convert percentage (0-100) to byte (0-255)
        final valueToSend = (percentage * 2.55).round();
        await _pumpPowerChar!.write([valueToSend]);
      } else {
        _showErrorDialog("Invalid Input", "Please enter a percentage between 0 and 100.");
      }
    }
  }

  void _showErrorDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  void _onTabTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = _connectedDevice == null
      ? [_buildConnectionPage()]
      : [
          _buildConnectionPage(),
          _buildTimersPage(),
          _buildDebugPage(),
          _buildSystemPage(),
        ];
        
    final List<BottomNavigationBarItem> navItems = _connectedDevice == null
      ? [const BottomNavigationBarItem(icon: Icon(Icons.bluetooth), label: 'Connection')]
      : [
          const BottomNavigationBarItem(icon: Icon(Icons.bluetooth), label: 'Connection'),
          const BottomNavigationBarItem(icon: Icon(Icons.timer), label: 'Timers'),
          const BottomNavigationBarItem(icon: Icon(Icons.bug_report), label: 'Debug'),
          const BottomNavigationBarItem(icon: Icon(Icons.info), label: 'System'),
        ];


    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 Flutter Controller'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: navItems,
        currentIndex: _selectedIndex,
        onTap: _onTabTapped,
      ),
    );
  }

  // --- Page Widgets ---
  
  Widget _buildWrapper(Widget child) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: child,
    );
  }

  Widget _buildConnectionPage() {
    return _buildWrapper(
      Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Connection', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 12, height: 12,
                    decoration: BoxDecoration(
                      color: _connectedDevice != null ? Colors.green.shade400 : Colors.red.shade400,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_status, style: const TextStyle(fontSize: 16), overflow: TextOverflow.ellipsis,)),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _connectedDevice != null ? _disconnectDevice : _scanAndConnect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(_connectedDevice != null ? 'Disconnect' : 'Connect to ESP32', style: const TextStyle(fontSize: 16, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimersPage() {
    return _buildWrapper(
      Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Timer Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              const Text('Timer On', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _timerOnController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: _sendTimerOn, child: const Text('Send')),
                  const SizedBox(width: 8),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: _readTimerOn),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Timer Off', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _timerOffController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: _sendTimerOff, child: const Text('Send')),
                  const SizedBox(width: 8),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: _readTimerOff),
                ],
              ),
              if (_showPumpPowerSection) ...[
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),
                const Text('Puissance Pompe (%)', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pumpPowerController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: false),
                        decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '0-100'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(onPressed: _sendPumpPower, child: const Text('Send')),
                    const SizedBox(width: 8),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: _readPumpPower),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildDebugPage() {
    return _buildWrapper(
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Debug View', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                height: 300, // Increased height for better viewing
                padding: const EdgeInsets.all(12.0),
                decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
                child: _debugData == null 
                  ? const Text('Waiting for debug data...', style: TextStyle(color: Colors.greenAccent))
                  : ListView(
                      children: _debugData!.entries.map((entry) => Text(
                          '${entry.key}: ${entry.value}',
                          style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace'),
                      )).toList(),
                    )
              )
            ]
          )
        )
      )
    );
  }
  
  Widget _buildSystemPage() {
    return _buildWrapper(
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('System Info', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Uptime:', style: TextStyle(fontSize: 16)),
                  Text(_uptime, style: const TextStyle(fontSize: 18, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _rebootDevice,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
                  child: const Text('Reboot ESP32', style: TextStyle(color: Colors.white)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

