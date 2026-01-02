import 'dart:isolate';
import 'dart:async';
import 'dart:math';
import 'package:assited_agent_v2/bloc/chat/config/app_lifecycle_observer.dart';
import 'package:assited_agent_v2/bloc/chat/config/event/event_manager.dart';
import 'package:assited_agent_v2/common/logger.dart';
import 'package:assited_agent_v2/database/AppDataBase.dart';
import 'package:assited_agent_v2/socketIO/socket_event_listener.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Listener signature for reacting to authenticated user changes.
typedef UserChangeListener = void Function(LoginUserModel);

/// All socket-level events emitted from the worker isolate to the main isolate.
enum SocketEvents {
  /// Fired when socket is successfully connected
  onConnect,

  /// Fired when socket connection fails
  onConnectError,

  /// Fired when socket disconnects
  onDisconnect,

  /// Fired on any socket error
  onError,

  /// Fired for all incoming socket messages (onAny)
  onMessage,

  /// Fired when reconnect attempt is scheduled
  reconnecting,
}

/// Wrapper object sent from worker isolate to main isolate
/// representing a socket lifecycle or message event.
class SocketEvent {
  /// Type of socket event
  final SocketEvents event;

  /// Optional payload associated with the event
  final dynamic data;

  /// Whether socket is currently connected
  final bool connected;

  SocketEvent(this.event, this.data, this.connected);
}

/// Message sent from main isolate → worker isolate
/// to emit a socket event without acknowledgement.
class WorkerMessageEmit {
  final String event;
  final dynamic data;

  WorkerMessageEmit({required this.event, required this.data});
}

/// Message sent from main isolate → worker isolate
/// to emit a socket event that expects an ACK response.
class WorkerMessageEmitWithAck {
  /// Unique request id to map ACK back to caller
  final String requestId;

  final String event;
  final dynamic data;

  WorkerMessageEmitWithAck({
    required this.requestId,
    required this.event,
    required this.data,
  });
}

/// Command to explicitly disconnect socket from main isolate.
class WorkerDisconnect {}

/// Command to explicitly reconnect socket from main isolate.
class WorkerReConnect {}

/// Token refresh payload (used during reconnect/auth flows).
class RefreshToken {
  final String token;
  final String uid;
  RefreshToken(this.token, this.uid);
}

/// ACK response sent from worker isolate → main isolate
/// mapped using requestId.
class AckResponse {
  final String requestId;
  final dynamic data;

  AckResponse({required this.requestId, required this.data});
}

/// Binds authenticated user changes from local DB
/// and feeds them into socket initialization lifecycle.
class AuthUserBinder {
  AuthUserBinder(this.db);

  StreamSubscription? subscription;
  final AppDB db;

  /// Start listening to logged-in user stream.
  /// Automatically triggers socket initialization.
  void bind(UserChangeListener listener) {
    subscription ??= db.getLoginProfile.listen((result) {
      if (result.isNotEmpty) {
        listener(result.first);
      }
    });
  }

  /// Stops listening to user changes.
  void unbind() {
    subscription?.cancel();
    subscription = null;
  }
}

/// High-level socket client responsible for:
/// - Managing isolate lifecycle
/// - App lifecycle handling
/// - Ack handling
/// - Connectivity state propagation
class SocketClient {
  final AuthUserBinder authUserBinder;
  final Connectivity connectivity;
  final AppLifecycleObserver observer;
  final AppDB db;

  SocketClient(this.authUserBinder, this.observer, this.db)
    : connectivity = Connectivity() {
    /// Automatically initialize socket when user is available
    authUserBinder.bind(initialize);
  }

  ReceivePort? _receivePort;
  StreamSubscription? _subscription;

  /// Public stream for socket events
  Stream<SocketEvent> get eventStream => evetController.stream;

  final evetController = StreamController<SocketEvent>.broadcast();

  /// Emits current socket connectivity state
  final _connectivityStream = BehaviorSubject.seeded(false);

  bool _connected = false;

  /// Updates internal connectivity flag
  set setConnected(bool value) {
    _connected = value;
  }

  Stream<bool> get connectivityStream => _connectivityStream.stream;

  bool get isConnected => _connected;

  Isolate? _isolate;
  SendPort? _workerSendPort;
  LoginUserModel? _loginUserModel;

  /// Maps requestId → Completer for ACK-based emits
  final Map<String, Completer<AckResponse>> _ackCompleters = {};

  /// Reacts to app lifecycle events.
  /// Disconnects on pause, reconnects on resume.
  void onAppLifecycleChanged(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      Logger.logInfo("Socket App Lifecycle State: $state");
      disconnect();
    }

    if (state == AppLifecycleState.resumed && _loginUserModel != null) {
      db.refreshFromBackground();
      manualReconnect();
    }
  }

  /// Explicit reconnect trigger from main isolate.
  void manualReconnect() {
    if (!isConnected) {
      _workerSendPort?.send(WorkerReConnect());
    }
  }

  /// Initializes socket isolate for authenticated user.
  Future<void> initialize(LoginUserModel user) async {
    _loginUserModel = user;

    if (isConnected) return;

    await dispose();

    _receivePort = ReceivePort();
    observer.addListener(onAppLifecycleChanged);

    final workerReady = Completer<SendPort>();

    /// Listen for messages from worker isolate
    _subscription = _receivePort?.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        workerReady.complete(message);
        return;
      }

      _handleMessage(message);
    });

    /// Spawn socket worker isolate
    _isolate = await Isolate.spawn(SocketWorkerEntry.entryPoint, {
      'sendPort': _receivePort?.sendPort,
      'token': user.token,
      'uid': user.nId,
    });

    await workerReady.future;
  }

  /// Routes incoming worker messages to appropriate handlers.
  void _handleMessage(dynamic message) {
    if (message is SocketEvent) {
      final handler = SocketEventHandlerFactory.getHandler(message);
      _connectivityStream.add(message.connected);

      if (handler != null) {
        handler.handleEvent(message, this);
      } else {
        Logger.logWarning("Unknown Socket Message Event: ${message.event}");
      }
    }

    if (message is AckResponse) {
      final completer = _ackCompleters.remove(message.requestId);
      completer?.complete(message);
    }
  }

  /// Emit socket event without ACK.
  void emit(String event, dynamic data) {
    _workerSendPort?.send(WorkerMessageEmit(event: event, data: data));
  }

  /// Emit socket event with ACK and timeout.
  Future<AckResponse> emitWithAck(
    String event,
    dynamic data, [
    int timeOut = 8,
  ]) {
    final requestId = const Uuid().v4();
    final completer = Completer<AckResponse>();
    _ackCompleters[requestId] = completer;

    _workerSendPort?.send(
      WorkerMessageEmitWithAck(requestId: requestId, event: event, data: data),
    );

    return completer.future.timeout(Duration(seconds: timeOut));
  }

  /// Gracefully disconnect socket.
  void disconnect() {
    _workerSendPort?.send(WorkerDisconnect());
  }

  /// Fully disposes socket isolate and all listeners.
  Future<void> dispose() async {
    Logger.logInfo("DISPOSING THE SOCKET CONNECTION");

    _subscription?.cancel();
    _subscription = null;

    _receivePort?.close();
    _receivePort = null;

    authUserBinder.unbind();
    observer.removeListener(onAppLifecycleChanged);

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

/// Entry point for the socket worker isolate.
///
/// Responsibilities:
/// - Owns the Socket.IO client instance
/// - Manages reconnection with exponential backoff + jitter
/// - Sends socket lifecycle & message events back to main isolate
/// - Receives commands (emit, disconnect, reconnect) from main isolate
/// - Runs heartbeat to keep connection alive
class SocketWorkerEntry {
  /// Isolate entry method.
  ///
  /// Expected payload keys:
  /// - sendPort : SendPort to communicate back to main isolate
  /// - token    : Auth token for socket authentication
  /// - uid      : User identifier
  static void entryPoint(Map<String, dynamic> payload) {
    /// ReceivePort for commands coming from main isolate
    final workerReceivePort = ReceivePort();

    /// SendPort to notify main isolate of socket events
    final mainSendPort = payload['sendPort'] as SendPort;

    /// Auth credentials passed from main isolate
    final token = payload['token'] as String?;
    final uid = payload['uid'] as String?;

    /// First handshake: send worker SendPort to main isolate
    mainSendPort.send(workerReceivePort.sendPort);

    /// Base reconnect delay (1s)
    const int baseDelay = 1000;

    /// Maximum reconnect delay (30s)
    const int maxDelay = 30000;

    /// Random jitter factor to prevent thundering herd reconnects
    const double jitter = 0.5;

    /// Number of reconnect attempts so far
    int retryCount = 0;

    /// Flag to prevent auto-reconnect after manual disconnect
    bool manuallyDisconnected = false;

    /// Factory method for creating a new Socket.IO instance.
    ///
    /// Important:
    /// - autoConnect disabled → we control when connect happens
    /// - reconnection disabled → custom backoff strategy is used
    io.Socket createSocket() {
      return io.io("http://3.110.95.88:3000/", {
        'transports': ['websocket'],
        'autoConnect': false,
        'reconnection': false,
        'timeout': 30000,
        'forceNew': true,
        'query': {"token": token, "uId": uid},
      });
    }

    /// Socket.IO client owned exclusively by this isolate
    late io.Socket socket;
    socket = createSocket();

    /// Periodic heartbeat timer to keep connection alive
    Timer? heartbeatTimer;

    /// Starts heartbeat emission every 20 seconds.
    ///
    /// Heartbeat is stopped on disconnect and restarted on reconnect.
    void startHeartbeat() {
      heartbeatTimer?.cancel();
      heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (socket.connected) {
          socket.emit('heartbeat', {
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });

          debugPrint("emitted heartbeat");
        }
      });
    }

    /// Attempts socket reconnection using exponential backoff + jitter.
    ///
    /// Stops immediately if:
    /// - socket was manually disconnected
    void attemptReconnect() async {
      if (manuallyDisconnected) return;

      retryCount++;

      /// Exponential backoff calculation
      int delay = (baseDelay * (1 << (retryCount - 1))).clamp(
        baseDelay,
        maxDelay,
      );

      /// Apply jitter to randomize reconnect attempts
      final randomFactor = 1 + ((Random().nextDouble() - 0.5) * 2 * jitter);
      delay = (delay * randomFactor).toInt();

      /// Notify main isolate that reconnect is scheduled
      mainSendPort.send(
        SocketEvent(SocketEvents.reconnecting, {
          "attempt": retryCount,
          "delayMs": delay,
        }, false),
      );

      await Future.delayed(Duration(milliseconds: delay));

      socket.connect();
    }

    /// Fired when socket connects successfully
    socket.onConnect((_) {
      retryCount = 0;
      mainSendPort.send(SocketEvent(SocketEvents.onConnect, null, true));
      startHeartbeat();
    });

    /// Fired when socket disconnects
    socket.onDisconnect((reason) {
      heartbeatTimer?.cancel();

      mainSendPort.send(SocketEvent(SocketEvents.onDisconnect, reason, false));

      if (!manuallyDisconnected) {
        attemptReconnect();
      }
    });

    /// Fired when initial connection fails
    socket.onConnectError((error) {
      mainSendPort.send(SocketEvent(SocketEvents.onConnectError, error, false));

      if (!manuallyDisconnected) {
        attemptReconnect();
      }
    });

    /// Fired on socket-level runtime errors
    socket.onError((error) {
      mainSendPort.send(
        SocketEvent(SocketEvents.onError, error, socket.connected),
      );
    });

    /// Catch-all handler for all incoming socket events
    socket.onAny((event, data) {
      mainSendPort.send(
        SocketEvent(SocketEvents.onMessage, {
          "event": event,
          "data": data,
        }, socket.connected),
      );
    });

    /// Initial connect trigger
    socket.connect();

    /// Listen for commands from main isolate
    workerReceivePort.listen((message) {
      /// Emit event without ACK
      if (message is WorkerMessageEmit) {
        socket.emit(message.event, message.data);
      }

      /// Emit event with ACK support
      if (message is WorkerMessageEmitWithAck) {
        socket.emitWithAck(
          message.event,
          message.data,
          ack: (resp) {
            debugPrint("ACK Response: $resp");
            mainSendPort.send(
              AckResponse(requestId: message.requestId, data: resp),
            );
          },
        );
      }

      /// Manual disconnect command
      if (message is WorkerDisconnect) {
        manuallyDisconnected = true;
        heartbeatTimer?.cancel();
        socket.disconnect();
        debugPrint("Socket disconnected manually");
      }

      /// Manual reconnect command
      if (message is WorkerReConnect) {
        manuallyDisconnected = false;
        socket.connect();
        debugPrint("Socket reconnect triggered manually");
      }
    });
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
  void handleEvent(SocketEvent event, SocketClient client) {
    /// Update socket connectivity state
    client.setConnected = event.connected;

    /// Notify app-level listeners that socket has reconnected
    eventManager.emit(eventName: 'socketReconnect', data: '');

    debugPrint(
      "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
    );
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

    debugPrint(
      "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
    );
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

    debugPrint(
      "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
    );
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

    debugPrint(
      "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
    );
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

    debugPrint(
      "_handleMessage() ${event.data}, ${event.event} ${event.connected}",
    );
  }
}
// ignore_for_file: constant_identifier_names

import 'package:assited_agent_v2/common/logger.dart';
import 'package:assited_agent_v2/socketIO/socket_client.dart';
import 'package:assited_agent_v2/socketIO/socket_manager.dart';
import 'package:flutter/material.dart';

/// Builder signature for creating a [SocketEventListener]
/// based on the current [SocketManager].
typedef SocketListenerBuilder =
    SocketEventListener Function(SocketManager socketManager);

/// Enum representing all domain-level socket message types
/// received via `socket.onAny`.
///
/// These values MUST match backend event names exactly
/// as they are resolved using `byName`.
enum SocketEventType {
  uDate,
  newsChange,
  articleChange,
  forumsChange,
  eventChange,
  enrollChange,
  courseComment,
  articleComment,
  newsComment,
  eventComment,
  forumComment,
  on_add_comment,
  likeUpdate,
  addAgLead,
  assignChange,
  contactChange,
  enrollmentChange,
  new_contact,
  directChange,
  aplnChange,
  new_message,
  room_user_time,
  my_msgStatus,
  new_room_with_msg,
  del_message,
  studDocChange,
  updateProfile,
  applicationList,
  user_online,
}

/// Handles `SocketEvents.onMessage` events coming from the worker isolate.
///
/// Responsibilities:
/// - Push raw socket events to global socket stream
/// - Resolve domain-specific socket event type
/// - Dispatch message payload to correct listener via factory
class SocketOnMessageEventHandler implements SocketEventHandler {
  final SocketManager socketManager;

  SocketOnMessageEventHandler(this.socketManager);

  @override
  void handleEvent(SocketEvent message, SocketClient client) {
    Logger.logInfo(
      "_handleMessage() ${message.data}, ${message.event} ${message.connected}",
    );

    /// Forward raw socket event to public socket stream
    client.evetController.add(message);

    /// Resolve domain-level socket event type from payload
    ///
    /// Expected message structure:
    /// {
    ///   "event": "<SocketEventType.name>",
    ///   "data": <payload>
    /// }
    final type = SocketEventType.values.byName(message.data['event']);

    /// Create listener using factory and dispatch payload
    final listener = SocketEventFactory.create(type, socketManager);
    listener?.listen(message.data['data']);
  }
}

/// Factory responsible for mapping socket message types
/// to their corresponding domain listeners.
///
/// Implements Strategy Pattern:
/// - Each event type has its own listener class
/// - No switch-case or conditional logic
class SocketEventFactory {
  /// Registry mapping socket event types to listener builders.
  ///
  /// New socket events can be added here without modifying
  /// any dispatcher logic.
  static final Map<SocketEventType, SocketListenerBuilder> _registry = {
    SocketEventType.uDate: (sm) => UDateChange(sm),
    SocketEventType.newsChange: (sm) => NewsChange(sm),
    SocketEventType.articleChange: (sm) => ArticleChange(sm),
    SocketEventType.forumsChange: (sm) => ForumsChange(sm),
    SocketEventType.eventChange: (sm) => EventChange(sm),
    SocketEventType.enrollChange: (sm) => EnrollChange(sm),
    SocketEventType.courseComment: (sm) => CourseCommentChange(sm),
    SocketEventType.articleComment: (sm) => ArticleCommentChange(sm),
    SocketEventType.newsComment: (sm) => NewsCommentChange(sm),
    SocketEventType.eventComment: (sm) => EventCommentChange(sm),
    SocketEventType.forumComment: (sm) => ForumCommenttChange(sm),
    SocketEventType.on_add_comment: (sm) => AddComment(sm),
    SocketEventType.likeUpdate: (sm) => LikeUpdate(sm),
    SocketEventType.addAgLead: (sm) => AddLeadChange(sm),
    SocketEventType.assignChange: (sm) => AssignLeadChange(sm),
    SocketEventType.contactChange: (sm) => ContactedLeadChange(sm),
    SocketEventType.enrollmentChange: (sm) => EnrolledLeadChange(sm),
    SocketEventType.new_contact: (sm) => EnquiryLeadChange(sm),
    SocketEventType.directChange: (sm) => DirectLeadChange(sm),
    SocketEventType.aplnChange: (sm) => AplnChange(sm),
    SocketEventType.new_message: (sm) => NewChatMessage(sm),
    SocketEventType.room_user_time: (sm) => RoomUserTime(sm),
    SocketEventType.my_msgStatus: (sm) => RoomMessageStatus(sm),
    SocketEventType.new_room_with_msg: (sm) => RoomWithMessage(sm),
    SocketEventType.del_message: (sm) => MessageDelete(sm),
    SocketEventType.studDocChange: (sm) => StudDocChange(sm),
    SocketEventType.updateProfile: (sm) => UpdateProfile(sm),
    SocketEventType.applicationList: (sm) => ApplicationList(sm),
    SocketEventType.user_online: (sm) => UserOnline(sm),
  };

  /// Creates a [SocketEventListener] for the given [SocketEventType].
  ///
  /// Returns `null` if no listener is registered.
  static SocketEventListener? create(
    SocketEventType type,
    SocketManager socketManager,
  ) {
    return _registry[type]?.call(socketManager);
  }
}

/// Base contract for all domain-level socket event listeners.
///
/// Each implementation:
/// - Handles ONE specific socket event type
/// - Delegates actual work to [SocketManager]
/// - Remains stateless except for injected dependencies
abstract class SocketEventListener {
  /// Called when a socket message of the corresponding type is received.
  ///
  /// [data] → raw payload sent from backend
  void listen(dynamic data);
}

/// Handles user date update events.
///
/// This listener is lifecycle-aware and ignores events
/// when the app is not in foreground.
class UDateChange implements SocketEventListener {
  final SocketManager socketManager;

  UDateChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    /// Ignore updates when app is not active
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }

    await socketManager.handleUDate(data);
  }
}

/// Handles news change events.
class NewsChange implements SocketEventListener {
  final SocketManager socketManager;

  NewsChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleNewsChange(data);
  }
}

/// Handles article update events.
class ArticleChange implements SocketEventListener {
  final SocketManager socketManager;

  ArticleChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleArticleChange(data);
  }
}

/// Handles forum updates.
class ForumsChange implements SocketEventListener {
  final SocketManager socketManager;

  ForumsChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleForumsChange(data);
  }
}

/// Handles event updates.
class EventChange implements SocketEventListener {
  final SocketManager socketManager;

  EventChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleEventChange(data);
  }
}

/// Handles enrollment updates.
class EnrollChange implements SocketEventListener {
  final SocketManager socketManager;

  EnrollChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleEnrollChange(data);
  }
}

/// Handles course comment updates.
class CourseCommentChange implements SocketEventListener {
  final SocketManager socketManager;

  CourseCommentChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleCourseComment(data);
  }
}

/// Handles article comment updates.
class ArticleCommentChange implements SocketEventListener {
  final SocketManager socketManager;

  ArticleCommentChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleArticleComment(data);
  }
}

/// Handles news comment updates.
class NewsCommentChange implements SocketEventListener {
  final SocketManager socketManager;

  NewsCommentChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleNewsComment(data);
  }
}

/// Handles event comment updates.
class EventCommentChange implements SocketEventListener {
  final SocketManager socketManager;

  EventCommentChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleEventComment(data);
  }
}

/// Handles forum comment updates.
class ForumCommenttChange implements SocketEventListener {
  final SocketManager socketManager;

  ForumCommenttChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleForumComment(data);
  }
}

/// Handles new comment creation events.
class AddComment implements SocketEventListener {
  final SocketManager socketManager;

  AddComment(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleAddComment(data);
  }
}

/// Handles like count or reaction updates.
class LikeUpdate implements SocketEventListener {
  final SocketManager socketManager;

  LikeUpdate(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleLikeUpdate(data);
  }
}

/// Handles new lead creation events.
class AddLeadChange implements SocketEventListener {
  final SocketManager socketManager;

  AddLeadChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleAddLeadChange(data);
  }
}

/// Handles lead assignment updates.
class AssignLeadChange implements SocketEventListener {
  final SocketManager socketManager;

  AssignLeadChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleAssignLeadChange(data);
  }
}

/// Handles contacted lead updates.
class ContactedLeadChange implements SocketEventListener {
  final SocketManager socketManager;

  ContactedLeadChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleContactedLeadChange(data);
  }
}

/// Handles enrolled lead updates.
class EnrolledLeadChange implements SocketEventListener {
  final SocketManager socketManager;

  EnrolledLeadChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleEnrolledLeadChange(data);
  }
}

/// Handles enquiry lead updates.
class EnquiryLeadChange implements SocketEventListener {
  final SocketManager socketManager;

  EnquiryLeadChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleEnquiryLeadChange(data);
  }
}

/// Handles direct lead updates.
class DirectLeadChange implements SocketEventListener {
  final SocketManager socketManager;

  DirectLeadChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleDirectLeadChange(data);
  }
}

/// Handles application change events.
class AplnChange implements SocketEventListener {
  final SocketManager socketManager;

  AplnChange(this.socketManager);

  @override
  void listen(dynamic data) async {
    await socketManager.handleAplnChange(data);
  }
}

/// Handles incoming chat messages.
class NewChatMessage implements SocketEventListener {
  final SocketManager socketManager;

  NewChatMessage(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleNewChatMessage(data);
  }
}

/// Handles user activity timestamp updates within chat rooms.
class RoomUserTime implements SocketEventListener {
  final SocketManager socketManager;

  RoomUserTime(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleRoomUserTime(data);
  }
}

/// Handles message status updates (sent, delivered, seen).
class RoomMessageStatus implements SocketEventListener {
  final SocketManager socketManager;

  RoomMessageStatus(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleRoomMessageStatus(data);
  }
}

/// Handles creation of a new room along with its first message.
class RoomWithMessage implements SocketEventListener {
  final SocketManager socketManager;

  RoomWithMessage(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleRoomWithMessage(data);
  }
}

/// Handles message deletion events.
class MessageDelete implements SocketEventListener {
  final SocketManager socketManager;

  MessageDelete(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleDeleteMessage(data);
  }
}

/// Handles student document change events.
class StudDocChange implements SocketEventListener {
  final SocketManager socketManager;

  StudDocChange(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleStudDocChange(data);
  }
}

/// Handles user profile update events.
class UpdateProfile implements SocketEventListener {
  final SocketManager socketManager;

  UpdateProfile(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleUpdateProfile(data);
  }
}

/// Handles application list updates.
class ApplicationList implements SocketEventListener {
  final SocketManager socketManager;

  ApplicationList(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleApplicationList(data);
  }
}

/// Handles online/offline user presence updates.
class UserOnline implements SocketEventListener {
  final SocketManager socketManager;

  UserOnline(this.socketManager);

  @override
  void listen(dynamic data) {
    socketManager.handleUserOnline(data);
  }
}
