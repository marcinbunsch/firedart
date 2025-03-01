import 'dart:async';
import 'dart:convert';

import 'package:firedart/generated/google/firestore/v1/common.pb.dart';
import 'package:firedart/generated/google/firestore/v1/document.pb.dart' as fs;
import 'package:firedart/generated/google/firestore/v1/firestore.pbgrpc.dart';
import 'package:firedart/generated/google/firestore/v1/query.pb.dart';
import 'package:grpc/grpc.dart';

import '../firedart.dart';

typedef RequestAuthenticator = Future<void>? Function(
    Map<String, String> metadata, String uri);

class _FirestoreGatewayStreamCache {
  void Function(String userInfo)? onDone;
  String userInfo;
  void Function(Object e) onError;

  StreamController<ListenRequest>? _listenRequestStreamController;
  late StreamController<ListenResponse> _listenResponseStreamController;
  late Map<String, Document> _documentMap;

  late bool _shouldCleanup;

  Stream<ListenResponse> get stream => _listenResponseStreamController.stream;

  Map<String, Document> get documentMap => _documentMap;

  _FirestoreGatewayStreamCache(
      {this.onDone, required this.userInfo, Function(Object e)? onError})
      : onError = onError ?? _handleErrorStub;

  void setListenRequest(
      ListenRequest request, FirestoreClient client, String database) {
    // Close the request stream if this function is called for a second time;
    _listenRequestStreamController?.close();

    _documentMap = <String, Document>{};
    _listenRequestStreamController = StreamController<ListenRequest>();
    _listenResponseStreamController =
        StreamController<ListenResponse>.broadcast(
            onListen: _handleListenOnResponseStream,
            onCancel: _handleCancelOnResponseStream);
    _listenResponseStreamController.addStream(client
        .listen(_listenRequestStreamController!.stream,
            options: CallOptions(
                metadata: {'google-cloud-resource-prefix': database}))
        .handleError(onError));
    _listenRequestStreamController!.add(request);
  }

  Future<void> close() async {
    await _listenRequestStreamController?.close();
    await _listenResponseStreamController.close();
  }

  void _handleListenOnResponseStream() {
    _shouldCleanup = false;
  }

  void _handleCancelOnResponseStream() {
    // Clean this up in the future
    _shouldCleanup = true;
    Future.microtask(_handleDone);
  }

  void _handleDone() {
    if (!_shouldCleanup) {
      return;
    }
    onDone?.call(userInfo);
    // Clean up stream resources
    _listenRequestStreamController!.close();
  }

  static void _handleErrorStub(e) {
    throw e;
  }
}

class FirestoreGateway {
  final RequestAuthenticator? _authenticator;

  final String basePath;
  final String database;

  final Map<String, _FirestoreGatewayStreamCache> _listenRequestStreamMap;

  late FirestoreClient _client;

  late ClientChannel _channel;

  final Emulator? _emulator;

  FirestoreGateway(
    String projectId, {
    String? databaseId,
    RequestAuthenticator? authenticator,
    Emulator? emulator,
  })  : _authenticator = authenticator,
        _emulator = emulator,
        basePath =
            'projects/$projectId/databases/${databaseId ?? '(default)'}/documents',
        database = 'projects/$projectId/databases/${databaseId ?? '(default)'}',
        _listenRequestStreamMap = <String, _FirestoreGatewayStreamCache>{} {
    _setupClient();
  }

  Future<Page<Document>> getCollection(
      String path, int pageSize, String nextPageToken) async {
    var request = ListDocumentsRequest()
      ..parent = path.substring(0, path.lastIndexOf('/'))
      ..collectionId = path.substring(path.lastIndexOf('/') + 1)
      ..pageSize = pageSize
      ..pageToken = nextPageToken;
    var response =
        await _client.listDocuments(request).catchError(_handleError);
    var documents =
        response.documents.map((rawDocument) => Document(this, rawDocument));
    return Page(documents, response.nextPageToken);
  }

  Stream<List<Document>> streamCollection(String path) {
    // if (_listenRequestStreamMap.containsKey(path)) {
    //   return _mapCollectionStream(_listenRequestStreamMap[path]!);
    // }

    var selector = StructuredQuery_CollectionSelector()
      ..collectionId = path.substring(path.lastIndexOf('/') + 1);
    var query = StructuredQuery()..from.add(selector);
    final queryTarget = Target_QueryTarget()
      ..parent = path.substring(0, path.lastIndexOf('/'))
      ..structuredQuery = query;
    final target = Target()..query = queryTarget;
    final request = ListenRequest()
      ..database = database
      ..addTarget = target;

    final listenRequestStream = _FirestoreGatewayStreamCache(
        onDone: _handleDone, userInfo: path, onError: _handleError);
    // _listenRequestStreamMap[path] = listenRequestStream;

    listenRequestStream.setListenRequest(request, _client, database);

    return _mapCollectionStream(listenRequestStream);
  }

  Stream<List<Document>> streamQuery(QueryReference queryReference) {
    // TODO: this path should take all query parameters into account
    final queryString = queryReference.structuredQuery.toDebugString();
    final bytes = utf8.encode(queryString);
    final base64Str = base64.encode(bytes);
    final path = '${queryReference.fullPath}-${base64Str}';

    // if (_listenRequestStreamMap.containsKey(path)) {
    //   return _mapCollectionStream(_listenRequestStreamMap[path]!);
    // }

    var selector = StructuredQuery_CollectionSelector()
      ..collectionId = path.substring(path.lastIndexOf('/') + 1);
    var query = StructuredQuery()
      ..from.add(selector)
      ..where;
    final queryTarget = Target_QueryTarget()
      ..parent = path.substring(0, path.lastIndexOf('/'))
      ..structuredQuery = queryReference.structuredQuery;
    final target = Target()..query = queryTarget;
    final request = ListenRequest()
      ..database = queryReference.gateway.database
      ..addTarget = target;

    final listenRequestStream = _FirestoreGatewayStreamCache(
        onDone: _handleDone, userInfo: path, onError: _handleError);
    // _listenRequestStreamMap[path] = listenRequestStream;

    listenRequestStream.setListenRequest(request, _client, database);

    return _mapCollectionStream(listenRequestStream);
  }

  Future<Document> createDocument(
      String path, String? documentId, fs.Document document) async {
    var split = path.split('/');
    var parent = split.sublist(0, split.length - 1).join('/');
    var collectionId = split.last;

    var request = CreateDocumentRequest()
      ..parent = parent
      ..collectionId = collectionId
      ..documentId = documentId ?? ''
      ..document = document;

    var response =
        await _client.createDocument(request).catchError(_handleError);
    return Document(this, response);
  }

  Future<Document> getDocument(path) async {
    var rawDocument = await _client
        .getDocument(GetDocumentRequest()..name = path)
        .catchError(_handleError);
    return Document(this, rawDocument);
  }

  Future<void> updateDocument(
      String path, fs.Document document, bool update) async {
    document.name = path;

    var request = UpdateDocumentRequest()..document = document;

    if (update) {
      var mask = DocumentMask();
      document.fields.keys.forEach(mask.fieldPaths.add);
      request.updateMask = mask;
    }

    await _client.updateDocument(request).catchError(_handleError);
  }

  Future<void> deleteDocument(String path) => _client
      .deleteDocument(DeleteDocumentRequest()..name = path)
      .catchError(_handleError);

  Stream<Document?> streamDocument(String path) {
    // if (_listenRequestStreamMap.containsKey(path)) {
    //   return _mapDocumentStream(_listenRequestStreamMap[path]!);
    // }

    final documentsTarget = Target_DocumentsTarget()..documents.add(path);
    final target = Target()..documents = documentsTarget;
    final request = ListenRequest()
      ..database = database
      ..addTarget = target;

    final listenRequestStream = _FirestoreGatewayStreamCache(
      onDone: _handleDone,
      userInfo: path,
      onError: _handleError,
    );
    // _listenRequestStreamMap[path] = listenRequestStream;

    listenRequestStream.setListenRequest(request, _client, database);

    return _mapDocumentStream(listenRequestStream);
  }

  Future<List<Document>> runQuery(
      StructuredQuery structuredQuery, String fullPath) async {
    final runQuery = RunQueryRequest()
      ..structuredQuery = structuredQuery
      ..parent = fullPath.substring(0, fullPath.lastIndexOf('/'));
    final response = _client.runQuery(runQuery);
    return await response
        .where((event) => event.hasDocument())
        .map((event) => Document(this, event.document))
        .toList();
  }

  Future<void> close() async {
    final currentStreams = _listenRequestStreamMap.values.toList();
    _listenRequestStreamMap.clear();

    for (var stream in currentStreams) {
      stream._handleDone();
    }
    _channel.shutdown();
  }

  Future<void> resetData() async {
    final currentStreams = _listenRequestStreamMap.values.toList();
    _listenRequestStreamMap.clear();
    for (var stream in currentStreams) {
      stream._handleDone();
    }
  }

  void _setupClient() {
    final callOptions = _authenticator != null
        ? CallOptions(providers: [_authenticator!])
        : null;
    _listenRequestStreamMap.clear();
    _channel = _emulator == null
        ? ClientChannel(
            'firestore.googleapis.com',
            options: ChannelOptions(),
          )
        : ClientChannel(
            _emulator!.host,
            port: _emulator!.port,
            options: ChannelOptions(
              credentials: ChannelCredentials.insecure(),
            ),
          );
    _client = FirestoreClient(
      _channel,
      options: callOptions,
    );
  }

  void _handleError(e) {
    if (e is GrpcError &&
        [
          StatusCode.unknown,
          StatusCode.unimplemented,
          StatusCode.internal,
          StatusCode.unavailable,
          StatusCode.unauthenticated,
          StatusCode.dataLoss,
        ].contains(e.code)) {
      _setupClient();
    }
    throw e;
  }

  void _handleDone(String path) {
    _listenRequestStreamMap.remove(path);
  }

  // TODO(Fix this for not spamming when a bunch of documents already exist in the collection)
  Stream<List<Document>> _mapCollectionStream(
      _FirestoreGatewayStreamCache listenRequestStream) async* {
    // THIS WILL FIRE AN EMPTY ARRAY
    // yield listenRequestStream.documentMap.values.toList();

    await for (final response in listenRequestStream.stream) {
      if (response.hasTargetChange()) {
        final targetChange = response.targetChange;
        if (targetChange.targetChangeType ==
            TargetChange_TargetChangeType.CURRENT) {
          yield listenRequestStream.documentMap.values.toList();
        }

        if (targetChange.targetChangeType ==
            TargetChange_TargetChangeType.RESET) {
          listenRequestStream.documentMap.clear();
          yield listenRequestStream.documentMap.values.toList();
        }

        continue;
      }

      if (response.hasDocumentChange()) {
        listenRequestStream.documentMap[response.documentChange.document.name] =
            Document(this, response.documentChange.document);
      } else {
        listenRequestStream.documentMap
            .remove(response.documentDelete.document);
      }

      // this will fire every time there is a change in the collection
      // we only want to fire on current state
      // yield listenRequestStream.documentMap.values.toList();
    }
  }

  Stream<Document?> _mapDocumentStream(
      _FirestoreGatewayStreamCache listenRequestStream) {
    return listenRequestStream.stream
        .where((response) =>
            response.hasDocumentChange() ||
            response.hasDocumentRemove() ||
            response.hasDocumentDelete())
        .map((response) => response.hasDocumentChange()
            ? Document(this, response.documentChange.document)
            : null);
  }
}
