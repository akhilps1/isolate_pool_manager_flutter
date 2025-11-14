import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'package:assited_agent_v2/bloc/chat/config/isolate_pool/models/isolate_result.dart';
import 'package:assited_agent_v2/bloc/chat/config/isolate_pool/models/isolate_task.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

typedef WatchListener = void Function();

class IsolateResult {
  final String taskId;
  final dynamic data;
  final String? error;

  bool get isSuccess => error == null;

  IsolateResult({required this.taskId, this.data, this.error});
}
class IsolateTask {
  final String taskId;
  final NetworkPayload payload;
  IsolateTask({required this.taskId, required this.payload});
}

class NetworkPayload {
  final String url;
  final String method;
  final Object? data;
  final Map<String, dynamic>? queryParameters;

  NetworkPayload({
    required this.url,
    required this.method,
    this.data,
    this.queryParameters,
  });
}


class Watcher {
  static Timer? timer;
  static void watch(WatchListener listener) {
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      listener.call();
    });
  }

  static Future<void> waitUntil(
    bool Function() predicate, {
    Duration checkInterval = const Duration(seconds: 5),
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final start = DateTime.now();

    while (!predicate()) {
      if (DateTime.now().difference(start) > timeout) {
        debugPrint("waitUntil timeout reached");
        break;
      }
      await Future.delayed(checkInterval);
    }
  }

  static void stope() {
    timer?.cancel();
    timer = null;
  }
}

class IsolatePoolManager {
  IsolatePoolManager({this.maxWorkers = 2});

  final int maxWorkers;
  final workQueue = Queue<IsolateTask>();
  final Map<String, _WorkerHandle> _workers = {};
  final Map<String, Completer<IsolateResult>> _completers = {};

  bool _isProcessing = false;

  bool get hasPendingWork => workQueue.isNotEmpty;

  Future<IsolateResult> addTask(IsolateTask task) {
    final completer = Completer<IsolateResult>();
    _completers[task.taskId] = completer;
    workQueue.add(task);
    _tryProcess();
    return completer.future;
  }

  void _tryProcess() {
    if (_isProcessing) return;
    _isProcessing = true;
    _processTask();
  }

  Future<void> _processTask() async {
    while (workQueue.isNotEmpty && _workers.length < maxWorkers) {
      final work = workQueue.removeFirst();

      final receivePort = ReceivePort();

      final sendPortCompleter = Completer<SendPort>();

      final sub = receivePort.listen((message) {
        if (message is SendPort) {
          sendPortCompleter.complete(message);
        }
        debugPrint('Isolate Message: ${message.hashCode}');
        if (message is IsolateResult) {
          _handleResult(message);
        }
      });

      final isolate = await Isolate.spawn(
        IsolateWorker.entryPoint,
        receivePort.sendPort,
      );

      final sendPort = await sendPortCompleter.future;

      debugPrint('Isolate Message: 1 ${sendPort.hashCode}');

      _workers[work.taskId] = _WorkerHandle(
        isolate: isolate,
        sendPort: sendPort,
        subscription: sub,
      );

      sendPort.send(work);
    }

    _isProcessing = false;
  }

  void _handleResult(IsolateResult message) {
    final completer = _completers.remove(message.taskId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
    _cleanup(message.taskId);
  }

  void _cleanup(String taskId) {
    final worker = _workers.remove(taskId);
    worker?.subscription.cancel();
    worker?.isolate.kill(priority: Isolate.immediate);

    if (workQueue.isNotEmpty) {
      _tryProcess();
    }
  }

  void dispose() {
    for (var w in _workers.values) {
      w.subscription.cancel();
      w.isolate.kill(priority: Isolate.immediate);
    }
    _workers.clear();
  }
}

class _WorkerHandle {
  final Isolate isolate;
  final SendPort sendPort;
  final StreamSubscription subscription;
  _WorkerHandle({
    required this.isolate,
    required this.sendPort,
    required this.subscription,
  });
}

class IsolateWorker {
  static void entryPoint(SendPort mainSendPort) {
    final port = ReceivePort();
    mainSendPort.send(port.sendPort);

    port.listen((message) async {
      if (message is IsolateTask) {
        try {
          final result = await _handleNetworkTask(payload: message.payload);

          mainSendPort.send(
            IsolateResult(taskId: message.taskId, data: result),
          );
        } catch (e) {
          mainSendPort.send(
            IsolateResult(taskId: message.taskId, error: e.toString()),
          );
        }
      }
    });
  }

  static Future<dynamic> _handleNetworkTask({
    required NetworkPayload payload,
  }) async {
    final strategy = ApiCallFactory.getStrategy(payload.method);
    if (strategy == null) {
      throw Exception('Unknown method tag: ${payload.method}');
    }

    final response = await strategy.handle(
      url: payload.url,
      data: payload.data,
      queryParameters: payload.queryParameters,
    );

    if (response.statusCode != null && response.statusCode! < 300) {
      return response.data;
    } else {
      throw Exception('Error ${response.statusCode}');
    }
  }
}

enum APICallType { get, post }

class ApiCallFactory {
  static final Map<String, ApiNetworkCall> _map = {
    APICallType.get.name: GetApiCall(Dio()..interceptors.add(LogInterceptor())),
    APICallType.post.name: PostApiCall(
      Dio()..interceptors.add(LogInterceptor()),
    ),
  };

  static ApiNetworkCall? getStrategy(String tag) => _map[tag];
}

abstract class ApiNetworkCall {
  Future<Response> handle({
    required String url,
    Object? data,
    CancelToken? cancelToken,
    Options? options,
    Map<String, dynamic>? queryParameters,
  });
}

class GetApiCall implements ApiNetworkCall {
  final Dio dio;
  GetApiCall(this.dio) {
    dio.interceptors.add(PrettyDioLogger(requestBody: true));
  }

  @override
  Future<Response> handle({
    required String url,
    Object? data,
    CancelToken? cancelToken,
    Options? options,
    Map<String, dynamic>? queryParameters,
  }) {
    return dio.get(
      url,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      options: options,
    );
  }
}

class PostApiCall implements ApiNetworkCall {
  final Dio dio;
  PostApiCall(this.dio) {
    dio.interceptors.add(PrettyDioLogger(requestBody: true));
  }

  @override
  Future<Response> handle({
    required String url,
    Object? data,
    CancelToken? cancelToken,
    Options? options,
    Map<String, dynamic>? queryParameters,
  }) {
    return dio.post(
      url,
      data: data,
      cancelToken: cancelToken,
      options: options,
      queryParameters: queryParameters,
    );
  }
}
