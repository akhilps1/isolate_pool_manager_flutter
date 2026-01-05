import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'package:assited_agent_v2/bloc/chat/config/custom_exception.dart';
import 'package:assited_agent_v2/bloc/chat/config/event/event_manager.dart';
import 'package:assited_agent_v2/bloc/chat/config/isolate_pool/commands/isolate_pool_commands.dart';
import 'package:assited_agent_v2/bloc/chat/config/isolate_pool/models/isolate_result.dart';
import 'package:assited_agent_v2/bloc/chat/config/isolate_pool/models/isolate_task.dart';
import 'package:assited_agent_v2/common/logger.dart';
import 'package:assited_agent_v2/repository/api_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';
import 'package:rxdart/rxdart.dart';
import 'package:image/image.dart' as img;

sealed class WorkerCommand {}

class ExecuteTask extends WorkerCommand {
  final IsolateTask task;
  ExecuteTask(this.task);
}

class CancelTask extends WorkerCommand {
  final String taskId;
  CancelTask(this.taskId);
}

class Shutdown extends WorkerCommand {}



abstract class IsolatePayload {}

class IsolateTask {
  final String taskId;
  final IsolatePayload payload;
  IsolateTask({required this.taskId, required this.payload});
}

class NetworkPayload extends IsolatePayload {
  final String url;
  final String method;
  final Object? data;
  final Map<String, dynamic>? queryParameters;
  final bool withProgress;

  NetworkPayload({
    required this.url,
    required this.method,
    this.data,
    this.queryParameters,
    this.withProgress = false,
  });

  NetworkRequest get toNetworkRequest {
    return NetworkRequest(url, method, data, queryParameters);
  }
}

class DownloadPayload extends IsolatePayload {
  final String token;
  final List<DownloadMedia> url;
  final String storagePath;
  DownloadPayload({
    required this.token,
    required this.url,
    required this.storagePath,
  });
}

class DownloadMedia {
  final String url;
  final String extention;
  final String id;
  DownloadMedia(this.url, this.extention, this.id);
}

class UploadPayload extends IsolatePayload {
  final String url;
  final String token;
  final String storagePath;
  final List<UploadMedia> medias;

  UploadPayload({
    required this.token,
    required this.medias,
    required this.url,
    required this.storagePath,
  });
}

class UploadMedia {
  final String filePath;
  final String tempId;
  final String parentId;
  UploadMedia(this.filePath, this.tempId, this.parentId);
}


abstract class IsolateResult {
  String get taskId;
  dynamic get data;
  String? get error;
  Enum? get event;
  bool get isSuccess;
}

class IsolateResultWithoutProgress implements IsolateResult {
  IsolateResultWithoutProgress({
    this.data,
    this.error,
    required this.taskId,
    this.event,
  });
  @override
  final dynamic data;

  @override
  final String? error;
  @override
  final String taskId;

  @override
  final Enum? event;

  @override
  bool get isSuccess => error == null;
}

class IsolateResultWithProgress implements IsolateResult {
  IsolateResultWithProgress({
    this.data,
    this.error,
    required this.taskId,
    this.progress,
    this.completed = false,
    this.event,
  });
  @override
  final dynamic data;
  @override
  final String? error;
  @override
  final String taskId;

  @override
  bool get isSuccess => error == null;

  final bool completed;
  @override
  final Enum? event;

  double? progress;
}


enum DownloadEvent { completed }

typedef WatchListener = void Function();
typedef DioProgressUpdater = void Function(int, int);

class Watcher {
  static Timer? timer;
  static void watch(WatchListener listener) {
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      listener.call();
    });
  }

  static Future<void> waitUntil(
    bool Function() predicate, {
    Duration checkInterval = const Duration(seconds: 10),
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final start = DateTime.now();

    while (!predicate()) {
      if (DateTime.now().difference(start) > timeout) {
        // debugPrint("waitUntil timeout reached");
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
  final String poolName;
  final EventManager eventManager;
  final int maxWorkers;

  IsolatePoolManager({
    required this.poolName,
    required this.eventManager,
    this.maxWorkers = 2,
  });

  final workQueue = Queue<IsolateTask>();
  final List<IsolateWorkerHandle> _workers = [];
  final Map<String, Completer<IsolateResult>> _completers = {};

  final progressEventsController =
      BehaviorSubject<Map<String, IsolateResultWithProgress>>.seeded({});

  bool _initialized = false;
  bool get hasPendingWork => workQueue.isNotEmpty;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    for (int i = 0; i < maxWorkers; i++) {
      await _spawnWorker(i);
    }
  }

  bool isInEvent(String id) {
    return progressEventsController.value[id] != null || _isInQueue(id);
  }

  bool _isInQueue(String id) {
    return workQueue.any((w) => w.taskId == id);
  }

  Future<void> _spawnWorker(int index) async {
    final receivePort = ReceivePort();
    final sendPortCompleter = Completer<SendPort>();

    final sub = receivePort.listen((message) {
      if (message is SendPort) {
        sendPortCompleter.complete(message);
        return;
      }
      _handleWorkerMessage(message);
    });

    final isolate = await Isolate.spawn(
      IsolateWorker.entryPoint,
      receivePort.sendPort,
      debugName: '${poolName}_worker_$index',
    );

    final sendPort = await sendPortCompleter.future;

    _workers.add(
      IsolateWorkerHandle(
        workerId: 'worker_$index',
        isolate: isolate,
        sendPort: sendPort,
        receivePort: receivePort,
        subscription: sub,
      ),
    );
  }

  Future<IsolateResult> addTaskAsync(IsolateTask task) async {
    await init();

    if (_completers.containsKey(task.taskId)) {
      throw CustomException(errMsg: 'Work already in progress');
    }

    final completer = Completer<IsolateResult>();
    _completers[task.taskId] = completer;

    workQueue.add(task);
    _dispatch();

    return completer.future;
  }

  void addTaskSync(IsolateTask task) {
    addTaskAsync(task);
  }

  void _dispatch() {
    for (final worker in _workers) {
      if (workQueue.isEmpty) return;
      if (worker.busy) continue;

      final task = workQueue.removeFirst();

      worker.busy = true;
      worker.currentTaskId = task.taskId;

      if (_shouldUpdateProgress(task.payload)) {
        _updateProgress(IsolateResultWithProgress(taskId: task.taskId));
      }

      worker.sendPort.send(ExecuteTask(task));
    }
  }

  void _handleWorkerMessage(dynamic message) {
    try {
      if (message is! IsolateResult) return;

      _handleResult(message);

      final worker = _workers.firstWhere(
        (w) => w.currentTaskId == message.taskId,
        orElse: () => throw Exception('Worker not found'),
      );

      if (message is IsolateResultWithProgress && !message.completed) {
        return;
      }

      worker.busy = false;
      worker.currentTaskId = null;

      _dispatch();
    } catch (e) {
      Logger.logError(e.toString());
    }
  }

  void _handleResult(IsolateResult message) {
    if (message is IsolateResultWithProgress) {
      if (message.completed) {
        _complete(message);
      } else {
        _updateProgress(message);
      }
    } else {
      _complete(message);
    }
  }

  void _complete(IsolateResult message) {
    final completer = _completers.remove(message.taskId);
    completer?.complete(message);

    if (message.event != null) {
      eventManager.emit(eventName: message.event!.name, data: message);
    }

    _removeProgress(message.taskId);
  }

  void _updateProgress(IsolateResultWithProgress msg) {
    final map = {...progressEventsController.value};
    map[msg.taskId] = msg;
    progressEventsController.add(map);
  }

  void _removeProgress(String taskId) {
    final map = {...progressEventsController.value};
    map.remove(taskId);
    progressEventsController.add(map);
  }

  void cancelTask(String taskId) {
    workQueue.removeWhere((e) => e.taskId == taskId);

    final worker = _workers
        .where((w) => w.currentTaskId == taskId)
        .cast<IsolateWorkerHandle?>()
        .firstOrNull;

    if (worker != null) {
      worker.sendPort.send(CancelTask(taskId));
      worker.busy = false;
      worker.currentTaskId = null;
    }

    _removeProgress(taskId);

    _completers
        .remove(taskId)
        ?.completeError(CustomException(errMsg: 'Task canceled'));

    _dispatch();
  }

  void dispose() {
    for (final w in _workers) {
      w.sendPort.send(Shutdown());
      w.subscription.cancel();
      w.receivePort.close();
      w.isolate.kill(priority: Isolate.immediate);
    }
    _workers.clear();
    progressEventsController.close();
  }

  bool _shouldUpdateProgress(IsolatePayload payload) {
    return (payload is NetworkPayload && payload.withProgress) ||
        payload is DownloadPayload;
  }
}

class IsolateWorkerHandle {
  final String workerId;
  final Isolate isolate;
  final SendPort sendPort;
  final ReceivePort receivePort;
  final StreamSubscription subscription;

  bool busy = false;
  String? currentTaskId;

  IsolateWorkerHandle({
    required this.workerId,
    required this.isolate,
    required this.sendPort,
    required this.receivePort,
    required this.subscription,
  });
}

class IsolateWorker {
  static void entryPoint(SendPort mainSendPort) {
    final port = ReceivePort();
    mainSendPort.send(port.sendPort);

    StreamSubscription? taskSub;

    port.listen((message) async {
      if (message is ExecuteTask) {
        taskSub?.cancel();

        final task = message.task;
        final executer = IsolateTaskExecuterFactory.getExecuter(
          task.payload.runtimeType,
        );

        if (executer == null) {
          mainSendPort.send(
            _handleErrorWithMessage(message.task, 'Cannot find the executer'),
          );
          return;
        }

        taskSub = executer
            .stream(task.payload, task.taskId)
            .listen(mainSendPort.send);
      }

      if (message is CancelTask) {
        taskSub?.cancel();
      }

      if (message is Shutdown) {
        taskSub?.cancel();
        port.close();
        Isolate.exit();
      }
    });
  }

  static IsolateResult _handleErrorWithMessage(
    IsolateTask message,
    String error,
  ) {
    if (message.payload is NetworkPayload &&
        (message.payload as NetworkPayload).withProgress) {
      return IsolateResultWithProgress(taskId: message.taskId, error: error);
    } else if (message.payload is NetworkPayload &&
        !(message.payload as NetworkPayload).withProgress) {
      return IsolateResultWithoutProgress(taskId: message.taskId, error: error);
    } else {
      return IsolateResultWithProgress(taskId: message.taskId, error: error);
    }
  }
}

class IsolateTaskExecuterFactory {
  static final _strategies = <Type, IsolateTaskExecuter>{
    NetworkPayload: StreamNetworkTaskWithoutDbInsertion(),
    DownloadPayload: RunDownloadTaskWithProgress(),
    UploadPayload: RunUploadTaskWithProgress(),
  };

  static IsolateTaskExecuter? getExecuter(Type payload) {
    // debugPrint("executer: $payload ${_strategies[payload]}");
    return _strategies[payload];
  }
}

abstract class IsolateTaskExecuter<T> {
  Stream<IsolateResult> stream(T payload, String taskId);
}

class RunDownloadTaskWithProgress
    implements IsolateTaskExecuter<DownloadPayload> {
  RunDownloadTaskWithProgress();

  @override
  Stream<IsolateResultWithProgress> stream(
    DownloadPayload payload,
    String taskId,
  ) async* {
    final progressController = StreamController<IsolateResultWithProgress>();
    final completer = Completer<List<Map<String, dynamic>>?>();
    final List<int> currentBytes = List.filled(payload.url.length, 0);
    final List<int> totalBytes = List.filled(payload.url.length, 0);

    try {
      final futures = Future.wait(
        List.generate(payload.url.length, (index) {
          final media = payload.url[index];

          return _handleDownload(
            downloadMedia: media,
            savePath: _createSavePath(
              storagePath: payload.storagePath,
              extention: media.extention,
            ),
            token: payload.token,
            onReceiveProgress: (current, total) {
              currentBytes[index] = current;
              totalBytes[index] = total > 0 ? total : 0;

              final sumCurrent = currentBytes.fold<int>(0, (a, b) => a + b);
              final sumTotal = totalBytes.fold<int>(0, (a, b) => a + b);

              double? progress;
              if (sumTotal > 0) {
                progress = sumCurrent / sumTotal;
              }

              progressController.add(
                IsolateResultWithProgress(taskId: taskId, progress: progress),
              );

              if ((progress ?? 0) >= 1) {
                progressController.add(
                  IsolateResultWithProgress(taskId: taskId, progress: null),
                );
                progressController.close();
              }
            },
          );
        }),
      );

      futures.then(
        (path) {
          completer.complete(path);
          // debugPrint("Download Complete: $path");
        },
        onError: (err) {
          debugPrint("Download Error: $err");
          progressController.add(
            IsolateResultWithProgress(taskId: taskId, error: err.toString()),
          );
          completer.complete(null);
          progressController.close();
        },
      );

      await for (var progress in progressController.stream) {
        await Future.delayed(const Duration(milliseconds: 10));
        yield progress;
      }

      final finalPath = await completer.future;

      yield IsolateResultWithProgress(
        taskId: taskId,
        data: finalPath,
        completed: true,
        event: DownloadEvent.completed,
      );
    } catch (e) {
      yield IsolateResultWithProgress(
        taskId: taskId,
        error: e.toString(),
        completed: true,
      );
    }
  }

  String _createSavePath({
    required String storagePath,
    required String extention,
  }) {
    final fileName =
        "download-${DateTime.now().microsecondsSinceEpoch}.$extention";
    return "$storagePath/$fileName";
  }

  Future<Map<String, dynamic>> _handleDownload({
    required String token,
    required String savePath,
    required DownloadMedia downloadMedia,
    required DioProgressUpdater onReceiveProgress,
    int maxRetry = 3,
  }) async {
    final file = File(savePath);

    int downloaded = 0;

    if (await file.exists()) {
      downloaded = await file.length();
    }

    IOSink sink = file.openWrite(mode: FileMode.append);

    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: Duration.zero,
          headers: {"token": token},
        ),
      );

      final url = Uri.encodeFull(downloadMedia.url);

      final response = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: {if (downloaded > 0) "Range": "bytes=$downloaded-"},
        ),
      );

      if (downloaded > 0 && response.statusCode != 206) {
        throw CustomException(errMsg: "Server does not support resume");
      }

      final totalRemote = response.data!.contentLength;

      final fullTotal = downloaded + totalRemote;

      int received = downloaded;

      await for (final chunk in response.data!.stream) {
        received += chunk.length;
        sink.add(chunk);

        onReceiveProgress(received, fullTotal);
      }

      await sink.close();

      return {"file_path": savePath, "meta_id": downloadMedia.id};
    } catch (e) {
      await sink.close();

      if (maxRetry > 0) {
        debugPrint("Retrying download... Remaining attempts: $maxRetry");

        await Future.delayed(Duration(seconds: maxRetry * 3));

        return _handleDownload(
          token: token,
          savePath: savePath,
          downloadMedia: downloadMedia,
          onReceiveProgress: onReceiveProgress,
          maxRetry: maxRetry - 1,
        );
      }

      rethrow;
    }
  }
}

class NetworkRequest {
  final String url;
  final String method;
  final Object? data;
  final Map<String, dynamic>? queryParameters;

  NetworkRequest(this.url, this.method, this.data, this.queryParameters);
}

class StreamNetworkTaskWithoutDbInsertion
    implements IsolateTaskExecuter<NetworkPayload> {
  StreamNetworkTaskWithoutDbInsertion();
  @override
  Stream<IsolateResult> stream(NetworkPayload payload, String taskId) async* {
    try {
      if (payload.withProgress) {
        await for (var result in RunNetworkTaskWithProgress.execute(
          payload.toNetworkRequest,
          taskId,
        )) {
          await Future.delayed(const Duration(milliseconds: 10));
          yield result;
        }
      } else {
        yield await RunNetworkTaskWithoutProgress.execute(
          payload.toNetworkRequest,
          taskId,
        );
      }
    } catch (e) {
      IsolateResult result = payload.withProgress
          ? IsolateResultWithProgress(
              taskId: taskId,
              error: e.toString(),
              completed: true,
            )
          : IsolateResultWithoutProgress(taskId: taskId, error: e.toString());
      yield result;
    }
  }
}

class RunNetworkTaskWithProgress {
  static Stream<IsolateResultWithProgress> execute(
    NetworkRequest payload,
    String taskId,
  ) async* {
    StreamController<IsolateResultWithProgress> progressController =
        StreamController();

    final Completer<dynamic> completer = Completer();
    try {
      _handleNetworkTask(
        payload: payload,
        onSendProgress: (current, total) {
          final progress = (current / total);

          progressController.add(
            IsolateResultWithProgress(taskId: taskId, progress: progress),
          );

          if (progress >= 1) {
            progressController.add(
              IsolateResultWithProgress(taskId: taskId, progress: null),
            );
            progressController.close();
          }
        },
      ).then(
        (data) {
          completer.complete(data);
        },
        onError: (err) {
          progressController.add(
            IsolateResultWithProgress(taskId: taskId, error: err.toString()),
          );
          completer.complete(null);
          progressController.close();
        },
      );

      await for (var progres in progressController.stream) {
        // debugPrint("Upload Progress: ${progres.progress}");

        yield progres;
      }

      final result = await completer.future;

      yield IsolateResultWithProgress(
        taskId: taskId,
        data: result,
        progress: null,
        completed: true,
      );
    } catch (e) {
      yield IsolateResultWithProgress(taskId: taskId, error: e.toString());
    }
  }

  static Future<dynamic> _handleNetworkTask({
    required NetworkRequest payload,
    DioProgressUpdater? onSendProgress,
  }) async {
    final strategy = ApiCallFactory.getStrategy(payload.method);
    if (strategy == null) {
      throw CustomException(errMsg: 'Unknown method tag: ${payload.method}');
    }

    final response = await strategy.handle(
      url: payload.url,
      data: payload.data,
      queryParameters: payload.queryParameters,
      onSendProgress: onSendProgress,
    );

    if (response.isOk) {
      return response.data;
    } else {
      throw CustomException(
        errMsg: response.data['m'] ?? 'Somthing went wrong',
      );
    }
  }
}

class RunNetworkTaskWithoutProgress {
  static Future<IsolateResultWithoutProgress> execute(
    NetworkRequest payload,
    String taskId,
  ) async {
    try {
      final result = await _handleNetworkTask(payload: payload);

      return IsolateResultWithoutProgress(taskId: taskId, data: result);
    } on CustomException catch (e) {
      return IsolateResultWithoutProgress(taskId: taskId, error: e.errMsg);
    }
  }

  static Future<dynamic> _handleNetworkTask({
    required NetworkRequest payload,
  }) async {
    final strategy = ApiCallFactory.getStrategy(payload.method);
    if (strategy == null) {
      throw CustomException(errMsg: 'Unknown method tag: ${payload.method}');
    }

    final response = await strategy.handle(
      url: payload.url,
      data: payload.data,
      queryParameters: payload.queryParameters,
    );

    if (response.isOk) {
      return response.data;
    } else {
      throw CustomException(
        errMsg: response.data['m'] ?? 'Somthing went wrong',
      );
    }
  }
}

class RunUploadTaskWithProgress implements IsolateTaskExecuter<UploadPayload> {
  RunUploadTaskWithProgress();

  @override
  Stream<IsolateResultWithProgress> stream(
    UploadPayload payload,
    String taskId,
  ) async* {
    final progressController = StreamController<IsolateResultWithProgress>();
    final completer = Completer<List<Map<String, dynamic>>?>();
    final List<double> currentBytes = List.filled(payload.medias.length, 0);
    final List<int> totalBytes = List.filled(payload.medias.length, 1);

    try {
      Future.wait(
        List.generate(payload.medias.length, (index) {
          final media = payload.medias[index];

          return _handleUpload(
            url: payload.url,
            uploadMedia: media,
            token: payload.token,
            onSendProgress: (current, total) {
              currentBytes[index] = current / total;

              final sumCurrent = currentBytes.fold<double>(0, (a, b) => a + b);
              final sumTotal = totalBytes.fold<int>(0, (a, b) => a + b);

              double progress = (sumCurrent / sumTotal).isNaN
                  ? 0
                  : (sumCurrent / sumTotal);

              // debugPrint("Upload Progress $progress");

              progressController.add(
                IsolateResultWithProgress(taskId: taskId, progress: progress),
              );
            },
          );
        }),
      ).then(
        (response) {
          progressController.add(
            IsolateResultWithProgress(taskId: taskId, progress: null),
          );
          completer.complete(response);
          // debugPrint("Upload Complete: $response");
          progressController.close();
        },
        onError: (err) {
          debugPrint("Upload Error: $err");
          progressController.add(
            IsolateResultWithProgress(taskId: taskId, error: err.toString()),
          );
          completer.complete(null);
          progressController.close();
        },
      );

      await for (var progress in progressController.stream) {
        await Future.delayed(const Duration(milliseconds: 10));
        yield progress;
      }

      final response = await completer.future;

      yield IsolateResultWithProgress(
        taskId: taskId,
        data: response,
        completed: true,
      );
    } catch (e) {
      yield IsolateResultWithProgress(taskId: taskId, error: e.toString());
    }
  }

  Future<Map<String, dynamic>> _handleUpload({
    required String url,
    required String token,
    required UploadMedia uploadMedia,
    required DioProgressUpdater onSendProgress,
    int maxRetry = 3,
  }) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: Duration.zero,
          headers: {"token": token},
        ),
      );

      if (kDebugMode) {
        dio.interceptors.add(PrettyDioLogger(requestBody: true));
      }
      // debugPrint("Status Code: $url ");
      final data = await _toParams(uploadMedia, token);

      final response = await dio.post(
        url,
        data: data,
        onSendProgress: onSendProgress,
      );

      if (response.statusCode != 200) {
        throw CustomException(errMsg: "Failed to upload media");
      }

      return {
        "data": response.data,
        "temp_id": uploadMedia.tempId,
        "parent_id": uploadMedia.parentId,
      };
    } catch (e) {
      debugPrint('Error Uploading Image: $e');
      if (maxRetry > 0) {
        debugPrint("Retrying download... Remaining attempts: $maxRetry");

        return _handleUpload(
          url: url,
          token: token,
          uploadMedia: uploadMedia,
          onSendProgress: onSendProgress,
          maxRetry: maxRetry - 1,
        );
      }

      rethrow;
    }
  }

  Future<FormData> _toParams(UploadMedia media, String token) async {
    final fileName = media.filePath.split('/').last;
    final formData = FormData.fromMap({
      'file': MultipartFile.fromFileSync(media.filePath, filename: fileName),
    });
    formData.fields.add(MapEntry('t', token));
    formData.fields.add(MapEntry('mediatemp_id', media.tempId));

    return formData;
  }
}

enum APICallType { get, post }

class ApiCallFactory {
  static final Map<String, ApiNetworkCall> _map = {
    APICallType.get.name: GetApiCall(
      Dio(BaseOptions(connectTimeout: const Duration(seconds: 30))),
    ),

    APICallType.post.name: PostApiCall(
      Dio(BaseOptions(connectTimeout: const Duration(seconds: 30))),
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
    DioProgressUpdater? onReceiveProgress,
    DioProgressUpdater? onSendProgress,
  });
}

class GetApiCall implements ApiNetworkCall {
  final Dio dio;
  GetApiCall(this.dio) {
    if (kDebugMode) {
      dio.interceptors.add(PrettyDioLogger(requestBody: true));
    }
  }

  @override
  Future<Response> handle({
    required String url,
    Object? data,
    CancelToken? cancelToken,
    Options? options,
    Map<String, dynamic>? queryParameters,
    DioProgressUpdater? onReceiveProgress,
    DioProgressUpdater? onSendProgress,
  }) {
    return dio.get(
      url,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      options: options,
      onReceiveProgress: onReceiveProgress,
    );
  }
}

class PostApiCall implements ApiNetworkCall {
  final Dio dio;
  PostApiCall(this.dio) {
    if (kDebugMode) {
      dio.interceptors.add(PrettyDioLogger(requestBody: true));
    }
  }

  @override
  Future<Response> handle({
    required String url,
    Object? data,
    CancelToken? cancelToken,
    Options? options,
    Map<String, dynamic>? queryParameters,
    DioProgressUpdater? onReceiveProgress,
    DioProgressUpdater? onSendProgress,
  }) {
    return dio.post(
      url,
      data: data,
      cancelToken: cancelToken,
      options: options,
      queryParameters: queryParameters,
      onReceiveProgress: onReceiveProgress,
      onSendProgress: onSendProgress,
    );
  }
}

Future<File?> compressImage({
  required String inputPath,
  required String outputPath,
  int quality = 70,
}) async {
  try {
    final bytes = await File(inputPath).readAsBytes();

    final original = img.decodeImage(bytes);
    if (original == null) return null;

    final outBytes = img.encodeJpg(original, quality: quality);

    final file = File(outputPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(outBytes);

    return file;
  } catch (e) {
    debugPrint("Image compression failed: $e");
    return null;
  }
}
