import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// --- BLE UUIDs (Must match your ESP32 firmware) ---
const String esp32ServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String dataCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const String debugCharUuid = 'f4a1f353-8576-4993-81b4-1101b0596348';
const String uptimeCharUuid = 'a8f5f247-3665-448d-8a0c-6b3a2a3e592b';
const String rebootCharUuid = 'b2d49a43-6c84-474c-a496-02d997e54f8e';
const String onTimeCharUuid = 'c8a3cadd-536c-4819-9154-10a110a19a4e';
const String offTimeCharUuid = 'd8a3cadd-536c-4819-9154-10a110a19a4f';


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
  final TextEditingController _dataToSendController = TextEditingController();
  final TextEditingController _valueAController = TextEditingController();
  final TextEditingController _valueBController = TextEditingController();
  String _receivedData = '';
  Map<String, dynamic>? _debugData;
  String _uptime = '00:00:00';

  // --- Characteristics ---
  BluetoothCharacteristic? _dataChar;
  BluetoothCharacteristic? _rebootChar;
  BluetoothCharacteristic? _valueAChar;
  BluetoothCharacteristic? _valueBChar;
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
    _dataToSendController.dispose();
    _valueAController.dispose();
    _valueBController.dispose();
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
    for (var service in services) {
      if (service.uuid == Guid(esp32ServiceUuid)) {
        for (var char in service.characteristics) {
          if (char.uuid == Guid(dataCharUuid)) _dataChar = char;
          if (char.uuid == Guid(rebootCharUuid)) _rebootChar = char;
          if (char.uuid == Guid(debugCharUuid)) _monitorDebug(char);
          if (char.uuid == Guid(uptimeCharUuid)) _monitorUptime(char);
          if (char.uuid == Guid(onTimeCharUuid)) _valueAChar = char;
          if (char.uuid == Guid(offTimeCharUuid)) _valueBChar = char;
        }
      }
    }
    // Read initial values after connecting
    _readValueA();
    _readValueB();
  }

  void _onDisconnected() {
    setState(() {
      _connectedDevice = null;
      _status = 'Disconnected';
      _debugData = null;
      _uptime = '00:00:00';
      _valueAController.text = '';
      _valueBController.text = '';
    });
    _debugSubscription?.cancel();
    _uptimeSubscription?.cancel();
  }

  void _disconnectDevice() async {
    await _connectedDevice?.disconnect();
  }

  void _sendData() async {
    if (_dataChar != null && _dataToSendController.text.isNotEmpty) {
      await _dataChar!.write(utf8.encode(_dataToSendController.text));
    }
  }

  void _readData() async {
    if (_dataChar != null) {
      List<int> value = await _dataChar!.read();
      setState(() { _receivedData = utf8.decode(value); });
    }
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

  void _readValueA() async {
    if (_valueAChar != null) {
      List<int> value = await _valueAChar!.read();
      if (value.length >= 4) {
        final intVal = ByteData.sublistView(Uint8List.fromList(value)).getUint32(0, Endian.little);
        setState(() { _valueAController.text = intVal.toString(); });
      }
    }
  }

  void _sendValueA() async {
    if (_valueAChar != null && _valueAController.text.isNotEmpty) {
      final int? val = int.tryParse(_valueAController.text);
      if (val != null) {
        final byteData = ByteData(4)..setUint32(0, val, Endian.little);
        await _valueAChar!.write(byteData.buffer.asUint8List());
      }
    }
  }
  
  void _readValueB() async {
    if (_valueBChar != null) {
      List<int> value = await _valueBChar!.read();
      if (value.length >= 4) {
        final intVal = ByteData.sublistView(Uint8List.fromList(value)).getUint32(0, Endian.little);
        setState(() { _valueBController.text = intVal.toString(); });
      }
    }
  }

  void _sendValueB() async {
    if (_valueBChar != null && _valueBController.text.isNotEmpty) {
      final int? val = int.tryParse(_valueBController.text);
      if (val != null) {
        final byteData = ByteData(4)..setUint32(0, val, Endian.little);
        await _valueBChar!.write(byteData.buffer.asUint8List());
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 Flutter Controller'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildConnectionCard(),
            if (_connectedDevice != null) ...[
              const SizedBox(height: 16),
              _buildValueSettingsCard(),
              const SizedBox(height: 16),
              _buildDataExchangeCard(),
              const SizedBox(height: 16),
              _buildDebugViewCard(),
              const SizedBox(height: 16),
              _buildSystemInfoCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    return Card(
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
    );
  }

  Widget _buildValueSettingsCard() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Numeric Values', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            const Text('Value A', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _valueAController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _sendValueA, child: const Text('Send')),
                const SizedBox(width: 8),
                IconButton(icon: const Icon(Icons.refresh), onPressed: _readValueA),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Value B', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _valueBController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _sendValueB, child: const Text('Send')),
                const SizedBox(width: 8),
                IconButton(icon: const Icon(Icons.refresh), onPressed: _readValueB),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildDataExchangeCard() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Data Exchange', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: _dataToSendController,
              decoration: const InputDecoration(labelText: 'Send Data', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            ElevatedButton(onPressed: _sendData, child: const Text('Send')),
            const SizedBox(height: 16),
            const Text('Received Data', style: TextStyle(fontWeight: FontWeight.w600)),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
              child: Text(_receivedData.isEmpty ? ' ' : _receivedData),
            ),
            const SizedBox(height: 8),
            ElevatedButton(onPressed: _readData, child: const Text('Read')),
          ],
        ),
      ),
    );
  }
  
  Widget _buildDebugViewCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Debug View', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              height: 150,
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
    );
  }
  
  Widget _buildSystemInfoCard() {
    return Card(
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
    );
  }
}

