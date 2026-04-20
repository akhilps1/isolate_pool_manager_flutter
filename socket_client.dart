
enum SocketEvents {
  unknown,
  onConnect,
  onConnectError,
  onDisconnect,
  onError,
  onMessage,
  reconnecting,
  connectionStatus,
  ping,
  isolateExit
}

class SocketEvent extends ToMap {
  final SocketEvents event;

  final dynamic data;

  final bool connected;
  final List<String> portIds;

  SocketEvent(this.event, this.data, this.connected, this.portIds);

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'type': 'socketEvent',
      'event': event.name,
      'data': data,
      'connected': connected,
      'portIds': portIds,
    };
  }

  factory SocketEvent.fromMap(Map<String, dynamic> map) {
    return SocketEvent(
      SocketEvents.values.firstWhere(
        (val) => val.name == map['event'],
        orElse: () => SocketEvents.unknown,
      ),
      map['data'] as dynamic,
      map['connected'] as bool,
      map['portIds'],
    );
  }
}


abstract class ToMap {
  toMap();
}

class WorkerMessageEmit extends ToMap {
  final String type;
  final String event;
  final dynamic data;

  WorkerMessageEmit({
    required this.event,
    required this.data,
    this.type = 'emit',
  });

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{'event': event, 'data': data, 'type': type};
  }

  factory WorkerMessageEmit.fromMap(Map<String, dynamic> map) {
    return WorkerMessageEmit(
      event: map['event'] as String,
      data: map['data'] as dynamic,
      type: map['type'],
    );
  }
}

class WorkerMessageEmitWithAck extends ToMap {
  final String requestId;

  final String type;
  final String event;
  final dynamic data;
  final int timeout;

  WorkerMessageEmitWithAck({
    required this.requestId,
    required this.event,
    required this.data,
    this.timeout = 8,
    this.type = 'emitWithAck',
  });

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'requestId': requestId,
      'event': event,
      'data': data,
      'type': type,
      'timeout': timeout,
    };
  }

  factory WorkerMessageEmitWithAck.fromMap(Map<String, dynamic> map) {
    return WorkerMessageEmitWithAck(
      requestId: map['requestId'] as String,
      event: map['event'] as String,
      data: map['data'] as dynamic,
      type: map['type'],
      timeout: map['timeout'],
    );
  }
}

class WorkerDisconnect extends ToMap {
  final String type;
  WorkerDisconnect({this.type = 'disconnect'});
  @override
  toMap() {
    return {'type': 'disconnect'};
  }
}

class WorkerReConnect extends ToMap {
  final String type;
  WorkerReConnect({this.type = 'reConnect'});
  @override
  toMap() {
    return {'type': 'reConnect'};
  }
}

class PongResponse extends ToMap {
  final String type;
  PongResponse({this.type = 'pong'});
  @override
  toMap() {
    return {'type': type};
  }
}

class WorkerAttachMainPort extends ToMap {
  String type;
  SendPort port;
  String portId;
  WorkerAttachMainPort({
    required this.port,
    required this.portId,
    this.type = 'attachMainPort',
  });

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{'port': port, 'portId': portId, 'type': type};
  }

  factory WorkerAttachMainPort.fromMap(Map<String, dynamic> map) {
    return WorkerAttachMainPort(
      port: map['port'] as SendPort,
      portId: map['portId'] as String,
      type: map['type'],
    );
  }
}

class WorkerDetachMainPort extends ToMap {
  final String portId;
  WorkerDetachMainPort(this.portId);

  @override
  toMap() {
    return {'type': 'workerDetachMainPort', 'portId': portId};
  }

  factory WorkerDetachMainPort.fromMap(Map<String, dynamic> map) {
    return WorkerDetachMainPort(map['portId'] as String);
  }
}

class RefreshToken {
  final String token;
  final String uid;
  RefreshToken(this.token, this.uid);
}


class AckResponse extends ToMap {
  final String requestId;
  final String type;
  final dynamic data;
  final String? error;

  AckResponse({
    required this.requestId,
    required this.data,
    this.error,
    this.type = 'ackResponse',
  });

  factory AckResponse.fromMap(Map<String, dynamic> map) {
    return AckResponse(
      requestId: map['requestId'] as String,
      data: map['data'] as dynamic,
      error: map['error'],
    );
  }

  @override
  toMap() {
    return {'requestId': requestId, 'type': type, 'data': data, 'error': error};
  }
}


class SocketIsolateRegistry {
  static const String socketPortName = "socket_worker_port";
}

typedef UserChangeListener = void Function(LoginUserModel);

class AuthUserBinder {
  AuthUserBinder(this.db);

  StreamSubscription? subscription;
  final AppDB db;

  void bind(UserChangeListener listener) {
    subscription ??= db.getLoginProfile.listen((result) {
      if (result.isNotEmpty) {
        listener(result.first);
      }
    });
  }

  void unbind() {
    subscription?.cancel();
    subscription = null;
  }
}

class SocketClient {
  final AuthUserBinder authUserBinder;
  // final Connectivity connectivity;
  final AppLifecycleObserver observer;

  List<String> avaliblePorts = [];

  String? portId;

  SocketClient(this.authUserBinder, this.observer) {
    authUserBinder.bind(initialize);
    portId = AppBgTracker.fromBg ? Uuid().v4() : "main";
  }

  ReceivePort? _receivePort;
  StreamSubscription? _subscription;

  Stream<SocketEvent> get eventStream => evetController.stream;

  final evetController = StreamController<SocketEvent>.broadcast();

  final _connectivityStream = BehaviorSubject.seeded(false);

  bool _connected = false;

  set setConnected(bool value) {
    _connected = value;
  }

  bool _isConnecting = false;
  set setConnecting(bool value) {
    _isConnecting = value;
  }

  Stream<bool> get connectivityStream => _connectivityStream.stream;

  bool get isConnected => _connected;

  Isolate? _isolate;
  SendPort? _workerSendPort;

  LoginUserModel? get user => _loginUserModel;

  LoginUserModel? _loginUserModel;

  final Map<String, Completer<AckResponse>> _ackCompleters = {};

  void onAppLifecycleChanged(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      await emitWithAck('exit_app', {}, 6);
    }
  }

  void manualReconnect() {
    if (!isConnected) {
      _workerSendPort?.send(WorkerReConnect().toMap());
    }
  }

  Future<void> initialize(LoginUserModel user) async {
    try {
      if (isConnected || _isConnecting) return;
      _loginUserModel = user;
      _isConnecting = true;

      final existingPort = IsolateNameServer.lookupPortByName(
        SocketIsolateRegistry.socketPortName,
      );

      if (existingPort != null) {
        Logger.logInfo("Reusing existing socket isolate");

        _workerSendPort = existingPort;

        _receivePort = ReceivePort();
        _subscription = _receivePort?.listen(_handleMessage);
        existingPort.send(
          WorkerAttachMainPort(
            port: _receivePort!.sendPort,
            portId: portId!,
          ).toMap(),
        );

        manualReconnect();

        return;
      }

      await _spawnSocketIsolate(user);
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _spawnSocketIsolate(LoginUserModel user) async {
    _receivePort = ReceivePort();

    observer.addListener(onAppLifecycleChanged);

    final workerReady = Completer<SendPort>();

    _subscription = _receivePort?.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        workerReady.complete(message);
        return;
      }

      _handleMessage(message);
    });

    _isolate = await Isolate.spawn(SocketWorkerEntry.entryPoint, {
      'sendPort': _receivePort?.sendPort,
      'token': _loginUserModel?.token,
      'uid': _loginUserModel?.nId,
      'portId': portId,
    });

    await workerReady.future;
  }

  void _handleMessage(dynamic message) {
    if (message['type'] == 'socketEvent') {
      final event = SocketEvent.fromMap(message);
      avaliblePorts = event.portIds;
      final handler = SocketEventHandlerFactory.getHandler(event);
      _connectivityStream.add(event.connected);

      if (handler != null) {
        handler.handleEvent(event, this);
      } else {
        Logger.logWarning("Unknown Socket Message Event: ${event.event}");
      }
    }

    if (message['type'] == 'ackResponse') {
      final ackResponse = AckResponse.fromMap(message);
      final completer = _ackCompleters.remove(ackResponse.requestId);
      completer?.complete(ackResponse);
    }

    Logger.logInfo("Avalible Ports: $avaliblePorts");
  }

  void emit(String event, dynamic data) {
    _workerSendPort?.send(WorkerMessageEmit(event: event, data: data).toMap());
  }

  Future<AckResponse> emitWithAck(
    String event,
    dynamic data, [
    int timeOut = 30,
  ]) {
    final requestId = const Uuid().v4();
    final completer = Completer<AckResponse>();
    _ackCompleters[requestId] = completer;

    _workerSendPort?.send(
      WorkerMessageEmitWithAck(
        requestId: requestId,
        event: event,
        data: data,
        timeout: timeOut,
      ).toMap(),
    );

    return completer.future.timeout(
      Duration(seconds: timeOut),
      onTimeout: () {
        _ackCompleters.remove(requestId);
        throw TimeoutException('Socket ACK timeout');
      },
    );
  }

  void disconnect() async {
    _workerSendPort?.send(WorkerDisconnect().toMap());
  }

  void pong() {
    _workerSendPort?.send(PongResponse().toMap());
  }

  void ditachPort() {
    _workerSendPort?.send(WorkerDetachMainPort(portId!).toMap());
  }

  Future<void> dispose() async {
    Logger.logInfo("DISPOSING THE SOCKET CONNECTION");
    ditachPort();

    _subscription?.cancel();
    _subscription = null;

    _receivePort?.close();
    _receivePort = null;

    // authUserBinder.unbind();
    observer.removeListener(onAppLifecycleChanged);

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

class SocketWorkerEntry {
  static final ports = <String, SendPort>{};

  static void entryPoint(Map<String, dynamic> payload) {
    int lastPongTime = 0;
    const int pingTimeoutMs = 10000;

    final ackQueue = Queue<WorkerMessageEmitWithAck>();
    final emitQueue = Queue<WorkerMessageEmit>();

    final workerReceivePort = ReceivePort();
    IsolateNameServer.removePortNameMapping(
      SocketIsolateRegistry.socketPortName,
    );
    IsolateNameServer.registerPortWithName(
      workerReceivePort.sendPort,
      SocketIsolateRegistry.socketPortName,
    );
    final portId = payload['portId'] as String;

    final mainSendPort = payload['sendPort'] as SendPort;

    ports[portId] = mainSendPort;

    final token = payload['token'] as String?;
    final uid = payload['uid'] as String?;

    mainSendPort.send(workerReceivePort.sendPort);

    const int baseDelay = 1000;

    const int maxDelay = 30000;

    const double jitter = 0.5;

    int retryCount = 0;

    bool manuallyDisconnected = false;

    io.Socket createSocket() {
      return io.io(Urls.socketUrl, {
        'transports': ['websocket'],
        'autoConnect': false,
        'reconnection': false,
        'timeout': 30000,
        'forceNew': true,
        'query': {"token": token, "uId": uid},
      });
    }

    late io.Socket socket;
    socket = createSocket();

    Timer? heartbeatTimer;

    void startMonitorMainAlive() {
      lastPongTime = DateTime.now().millisecondsSinceEpoch;
      heartbeatTimer?.cancel();
      heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (t) {
        final now = DateTime.now().millisecondsSinceEpoch;

        debugPrint("Ping timeout  ${(now - lastPongTime)}");

        if ((now - lastPongTime) > pingTimeoutMs) {
          _emit(SocketEvent(SocketEvents.isolateExit, null, false, []).toMap());
          debugPrint(
            "Ping timeout detected → forcing disconnect ${(now - lastPongTime) > pingTimeoutMs}",
          );

          ports.clear();

          socket.dispose();
          heartbeatTimer?.cancel();
          IsolateNameServer.removePortNameMapping(
            SocketIsolateRegistry.socketPortName,
          );
          workerReceivePort.close();
          Isolate.exit();
        }

        _emit(
          SocketEvent(
            SocketEvents.ping,
            null,
            socket.connected,
            ports.keys.toList(),
          ).toMap(),
        );
      });
    }

    void attemptReconnect() async {
      if (manuallyDisconnected) return;

      retryCount++;

      int delay = (baseDelay * (1 << (retryCount - 1))).clamp(
        baseDelay,
        maxDelay,
      );

      final randomFactor = 1 + ((Random().nextDouble() - 0.5) * 2 * jitter);
      delay = (delay * randomFactor).toInt();

      _emit(
        SocketEvent(
          SocketEvents.reconnecting,
          {"attempt": retryCount, "delayMs": delay},
          false,
          ports.keys.toList(),
        ).toMap(),
      );

      await Future.delayed(Duration(milliseconds: delay));

      socket.connect();
    }

    socket.onConnect((_) {
      retryCount = 0;
      _emit(
        SocketEvent(
          SocketEvents.onConnect,
          null,
          true,
          ports.keys.toList(),
        ).toMap(),
      );
      processAckQueue(socket, ackQueue);
      processEmitQueue(socket, emitQueue);
    });

    socket.onDisconnect((reason) {
      _emit(
        SocketEvent(
          SocketEvents.onDisconnect,
          reason,
          false,
          ports.keys.toList(),
        ).toMap(),
      );

      if (!manuallyDisconnected) {
        attemptReconnect();
      }
    });

    socket.onConnectError((error) {
      _emit(
        SocketEvent(
          SocketEvents.onConnectError,
          error,
          false,
          ports.keys.toList(),
        ).toMap(),
      );

      if (!manuallyDisconnected) {
        attemptReconnect();
      }
    });

    socket.onError((error) {
      _emit(
        SocketEvent(
          SocketEvents.onError,
          error,
          socket.connected,
          ports.keys.toList(),
        ).toMap(),
      );
    });

    socket.onAny((event, data) {
      _emit(
        SocketEvent(
          SocketEvents.onMessage,
          {"event": event, "data": data},
          socket.connected,
          ports.keys.toList(),
        ).toMap(),
      );
    });

    startMonitorMainAlive();
    socket.connect();

    workerReceivePort.listen((message) {
      debugPrint("Socket Message $message");
      if (message['type'] == 'emit') {
        final command = WorkerMessageEmit.fromMap(message);
        emitQueue.add(command);
        processEmitQueue(socket, emitQueue);
      }

      if (message['type'] == 'emitWithAck') {
        final command = WorkerMessageEmitWithAck.fromMap(message);
        ackQueue.add(command);
        processAckQueue(socket, ackQueue);
      }

      /// Manual disconnect command
      if (message['type'] == 'disconnect') {
        manuallyDisconnected = true;
        // heartbeatTimer?.cancel();
        socket.disconnect();

        debugPrint("Socket disconnected manually");
      }

      /// Manual reconnect command
      if (message['type'] == 'reConnect') {
        if (!socket.connected) {
          manuallyDisconnected = false;
          socket.connect();
          debugPrint("Socket reconnect triggered manually");
        }
      }

      if (message['type'] == 'pong') {
        lastPongTime = DateTime.now().millisecondsSinceEpoch;

        debugPrint("PONG Response $lastPongTime");
      }

      if (message['type'] == 'attachMainPort') {
        debugPrint("Socket Connected: ${socket.connected}");

        final command = WorkerAttachMainPort.fromMap(message);
        ports[command.portId] = command.port;
        _emit(
          SocketEvent(
            SocketEvents.connectionStatus,
            null,
            socket.connected,
            ports.keys.toList(),
          ).toMap(),
        );
      }

      if (message['type'] == 'workerDetachMainPort') {
        final command = WorkerDetachMainPort.fromMap(message);
        ports.remove(command.portId);
      }
    });
  }

  static void _emit(dynamic event, [String? portId]) {
    final deadPorts = <String>[];

    if (portId != null) {
      try {
        ports[portId]!.send(event);
      } catch (e) {
        deadPorts.add(portId);
      }

      return;
    }

    ports.forEach((id, port) {
      try {
        port.send(event);
      } catch (err) {
        debugPrint("Failed to send event to port: $id, $err");
        deadPorts.add(id);
      }
    });

    for (final id in deadPorts) {
      ports.remove(id);
    }
  }

  static bool isProcessingAck = false;
  static void processAckQueue(
    io.Socket socket,
    Queue<WorkerMessageEmitWithAck> ackQueue,
  ) async {
    if (isProcessingAck) return;

    isProcessingAck = true;
    try {
      while (ackQueue.isNotEmpty) {
        if (!socket.connected) break;
        final command = ackQueue.removeFirst();
        dynamic response;

        try {
          final completer = Completer<dynamic>();

          socket.emitWithAck(
            command.event,
            command.data,
            ack: (resp) {
              response = resp;
              completer.complete(resp);
            },
          );

          response = await completer.future.timeout(
            Duration(seconds: command.timeout),
          );

          _emit(
            AckResponse(requestId: command.requestId, data: response).toMap(),
          );
        } on TimeoutException {
          _emit(
            AckResponse(
              requestId: command.requestId,
              data: null,
              error: "Time out",
            ).toMap(),
          );
        } catch (e) {
          _emit(
            AckResponse(
              requestId: command.requestId,
              data: null,
              error: e.toString(),
            ).toMap(),
          );
        }
      }
    } finally {
      isProcessingAck = false;
    }
  }

  static bool isProcessingEmit = false;
  static void processEmitQueue(
    io.Socket socket,
    Queue<WorkerMessageEmit> emitQueue,
  ) {
    if (isProcessingEmit) return;
    isProcessingEmit = true;
    try {
      while (emitQueue.isNotEmpty) {
        if (!socket.connected) break;
        final command = emitQueue.removeFirst();
        socket.emit(command.event, command.data);
      }
    } finally {
      isProcessingEmit = false;
    }
  }
}

/// Factory responsible for resolving a [SocketEventHandler]
/// for a given [SocketEvent].
///
/// This enables:
/// - Clean separation of socket event handling logic
/// - Open/Closed principle (add new handlers without touching SocketClient)
/// - Dependency injection via GetIt
class SocketEventHandlerFactory {
  /// Mapping between socket event types and their corresponding handlers.
  ///
  /// Handlers are resolved eagerly from GetIt and treated as stateless.
  static final _handlers = {
    SocketEvents.onConnect: GetIt.I<SocketOnConnectEventHandler>(),
    SocketEvents.onConnectError: GetIt.I<SocketErrorEventHandler>(),
    SocketEvents.onDisconnect: GetIt.I<SocketDisconnectEventHandler>(),
    SocketEvents.onError: GetIt.I<SocketConnectionErrorEventHandler>(),
    SocketEvents.onMessage: GetIt.I<SocketOnMessageEventHandler>(),
    SocketEvents.reconnecting: GetIt.I<SocketOnReconnectEventHandler>(),
    SocketEvents.connectionStatus:
        GetIt.I<SocketConnectionStatusEventHandler>(),
    SocketEvents.ping: GetIt.I<SocketPingEventHandler>(),
    SocketEvents.isolateExit: GetIt.I<SocketIsolateExitEventHandler>(),
  };

  /// Returns the handler responsible for processing the given socket event.
  ///
  /// Returns `null` if no handler is registered for the event type.
  static SocketEventHandler? getHandler(SocketEvent message) {
    return _handlers[message.event];
  }
}

/// Base contract for all socket event handlers.
///
/// Each handler:
/// - Reacts to a specific [SocketEvents] type
/// - Mutates [SocketClient] state if required
/// - Emits domain events into the app layer if needed
abstract class SocketEventHandler {
  /// Handles a socket event coming from the worker isolate.
  ///
  /// [event]  → socket event payload
  /// [client] → socket client owning the connection
  void handleEvent(SocketEvent event, SocketClient client);
}

/// Handles successful socket connection events.
///
/// Typical responsibilities:
/// - Mark socket as connected
/// - Notify rest of app that socket is available again
class SocketOnConnectEventHandler implements SocketEventHandler {
  final EventManager eventManager;

  SocketOnConnectEventHandler(this.eventManager);

  @override
  void handleEvent(SocketEvent event, SocketClient client) async {
    /// Update socket connectivity state
    client.setConnected = event.connected;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      final res = await client.emitWithAck('open_app', {}, 6);
      Logger.logError("APP OPEN ${res.data}");
    }

    /// Notify app-level listeners that socket has reconnected
    eventManager.emit(eventName: 'socketReconnect', data: '');
    if (kDebugMode) {
      debugPrint(
        "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
      );
    }
  }
}

class SocketPingEventHandler implements SocketEventHandler {
  final EventManager eventManager;

  SocketPingEventHandler(this.eventManager);

  @override
  void handleEvent(SocketEvent event, SocketClient client) async {
    /// Update socket connectivity state
    ///
    if (kDebugMode) {
      debugPrint(
        "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
      );
    }
    client.pong();
  }
}

/// Handles socket connection errors during initial connect attempts.
///
/// This typically indicates:
/// - Network failure
/// - Invalid auth token
/// - Server unreachable
class SocketErrorEventHandler implements SocketEventHandler {
  final EventManager eventManager;

  SocketErrorEventHandler(this.eventManager);

  @override
  void handleEvent(SocketEvent event, SocketClient client) {
    /// Update connectivity state
    client.setConnected = event.connected;

    if (kDebugMode) {
      debugPrint(
        "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
      );
    }
  }
}

/// Handles socket disconnection events.
///
/// Fired when:
/// - Network drops
/// - Server disconnects client
/// - Client explicitly disconnects
class SocketDisconnectEventHandler implements SocketEventHandler {
  final EventManager eventManager;

  SocketDisconnectEventHandler(this.eventManager);

  @override
  void handleEvent(SocketEvent event, SocketClient client) {
    /// Update connectivity state
    client.setConnected = event.connected;

    if (kDebugMode) {
      debugPrint(
        "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
      );
    }
  }
}

/// Handles runtime socket errors occurring *after* connection.
///
/// Examples:
/// - Protocol violations
/// - Unexpected server-side failures
class SocketConnectionErrorEventHandler implements SocketEventHandler {
  final EventManager eventManager;

  SocketConnectionErrorEventHandler(this.eventManager);

  @override
  void handleEvent(SocketEvent event, SocketClient client) {
    /// Update connectivity state
    client.setConnected = event.connected;

    if (kDebugMode) {
      debugPrint(
        "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
      );
    }

    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      Fluttertoast.showToast(msg: 'Connection error');
    }
  }
}

/// Handles reconnect scheduling events.
///
/// Fired when worker isolate schedules a reconnect attempt
/// using exponential backoff.
class SocketOnReconnectEventHandler implements SocketEventHandler {
  final EventManager eventManager;

  SocketOnReconnectEventHandler(this.eventManager);

  @override
  void handleEvent(SocketEvent event, SocketClient client) {
    /// Socket is still considered disconnected during reconnect attempts
    client.setConnected = event.connected;

    if (kDebugMode) {
      debugPrint(
        "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
      );
    }
  }
}

class SocketConnectionStatusEventHandler implements SocketEventHandler {
  final EventManager eventManager;

  SocketConnectionStatusEventHandler(this.eventManager);

  @override
  void handleEvent(SocketEvent event, SocketClient client) {
    /// Socket is still considered disconnected during reconnect attempts
    client.setConnected = event.connected;

    if (kDebugMode) {
      debugPrint(
        "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
      );
    }
  }
}

class SocketIsolateExitEventHandler implements SocketEventHandler {
  final EventManager eventManager;

  SocketIsolateExitEventHandler(this.eventManager);

  @override
  void handleEvent(SocketEvent event, SocketClient client) async {
    print("_handleMessage() ${event.data}, ${event.event} ${event.connected}");
    client.setConnected = event.connected;
    client.setConnecting = false;
    await Future.delayed(const Duration(seconds: 10));
    if (client.user != null) {
      client.initialize(client.user!);
    }
    // if (kDebugMode) {

    // }
  } 
}
