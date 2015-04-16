part of dart_amqp.client;

class _ChannelImpl implements Channel {

  // The allocated channel id
  final int channelId;

  _ClientImpl _client;
  FrameWriter _frameWriter;
  Completer<Channel> _channelOpened;
  Completer<Channel> _channelClosed;
  ListQueue<Completer> _pendingOperations;
  ListQueue<Object> _pendingOperationPayloads;
  Map<String, _ConsumerImpl> _consumers;
  Message _lastHandshakeMessage;
  Exception _channelCloseException;

  _ChannelImpl(this.channelId, _ClientImpl this._client) {
    _frameWriter = new FrameWriter(_client.tuningSettings);
    _pendingOperations = new ListQueue<Completer>();
    _pendingOperationPayloads = new ListQueue<Object>();
    _consumers = new Map<String, _ConsumerImpl>();

    // If we are opening a user channel signal to the server; otherwise perform connection handshake
    if (channelId > 0) {
      _channelOpened = new Completer<Channel>();
      writeMessage(new ChannelOpen(), completer : _channelOpened, futurePayload : this);
    } else {
      writeProtocolHeader();
    }
  }

  void writeProtocolHeader() {
    _pendingOperations.add(_client._connected);
    _pendingOperationPayloads.add(this);

    // Transmit handshake
    _frameWriter
      ..writeProtocolHeader(_client.settings.amqpProtocolVersion, _client.settings.amqpMajorVersion, _client.settings.amqpMinorVersion, _client.settings.amqpRevision)
      ..pipe(_client._socket);
  }

  void writeHeartbeat() {
    // Transmit heartbeat
    _frameWriter
      ..writeHeartbeat()
      ..pipe(_client._socket);
  }

  /**
   * Encode and transmit [message] optionally accompanied by a server frame with [payloadContent].
   *
   * A [StateError] will be thrown when trying to write a message to a closed channel
   */
  void writeMessage(Message message, { MessageProperties properties, Object payloadContent, Completer completer, Object futurePayload }) {
    if (_channelClosed != null && (_channelClosed != completer)) {
      throw _channelCloseException == null
      ? new StateError("Channel has been closed")
      : _channelCloseException;
    }

    // If an op completer is specified add it to the queue
    if (completer != null) {
      _pendingOperations.addLast(completer);
      _pendingOperationPayloads.addLast(futurePayload != null ? futurePayload : true);
    }

    _frameWriter
      ..writeMessage(channelId, message, properties : properties, payloadContent : payloadContent)
      ..pipe(_client._socket);
  }

  /**
   * Implement the handshake flow specified by the AMQP spec by
   * examining [serverFrame] and generating the appropriate response
   */
  void _processHandshake(DecodedMessage serverMessage) {

    // Handshake process includes the following steps
    // 1) S : ConnectionStart, C : ConnectionStartOk
    // 2) (optional multiple) S : ConnectionSecure, C : ConnectionSecureOk
    // 3) S : ConnectionTune, C : ConnectionTuneOk
    // 4) C : ConnectionOpen, S : ConnectionOpenOk
    switch (serverMessage.message.runtimeType) {
      case ConnectionStart:
        ConnectionStart serverResponse = (serverMessage.message as ConnectionStart);

        // Check if the currently supplied authentication provider is supported by the server.
        if (serverResponse.mechanisms.indexOf(_client.settings.authProvider.saslType) == -1) {
          _client._handleException(
              new FatalException(
                  "Selected authentication provider '${_client.settings.authProvider.saslType}' is unsupported by the server (server supports: ${serverResponse.mechanisms})"
              )
          );
          return;
        }

        ConnectionStartOk clientResponse = new ConnectionStartOk()
          ..clientProperties = {
          "product" : "Dart AMQP client",
          "version" : "0.0.1",
          "platform" : "Dart/${Platform.operatingSystem}"
        }
          ..locale = 'en_US'
          ..mechanism = _client.settings.authProvider.saslType
          ..response = _client.settings.authProvider.answerChallenge(null);

        // Transmit handshake response
        _lastHandshakeMessage = clientResponse;
        writeMessage(clientResponse);
        break;
      case ConnectionSecure:
        ConnectionSecure serverResponse = serverMessage.message as ConnectionSecure;

        ConnectionSecureOk clientResponse = new ConnectionSecureOk()
          ..response = _client.settings.authProvider.answerChallenge(serverResponse.challenge);

        // Transmit handshake response
        _lastHandshakeMessage = clientResponse;
        writeMessage(clientResponse);
        break;
      case ConnectionTune:
        ConnectionTune serverResponse = serverMessage.message as ConnectionTune;

        // Update tuning settings unless our client forces a specific value
        _client.tuningSettings
          ..maxFrameSize = serverResponse.frameMax
          ..maxChannels = _client.tuningSettings.maxChannels > 0 ? _client.tuningSettings.maxChannels : serverResponse.channelMax
          ..heartbeatPeriod = new Duration(seconds : serverResponse.heartbeat);

        // Respond with the mirrored tuning settings
        ConnectionTuneOk clientResponse = new ConnectionTuneOk()
          ..frameMax = serverResponse.frameMax
          ..channelMax = _client.tuningSettings.maxChannels
          ..heartbeat = serverResponse.heartbeat;

        _lastHandshakeMessage = clientResponse;
        writeMessage(clientResponse);

        // Also respond with a connection open request. The _channelOpened future has already been
        // pushed to the pending operations stack in the constructor so we do not need to do it here
        ConnectionOpen openRequest = new ConnectionOpen()
          ..virtualHost = _client.settings.virtualHost;
        _lastHandshakeMessage = clientResponse;
        writeMessage(openRequest);

        break;
      case ConnectionOpenOk:
        _lastHandshakeMessage = null;
        _completeOperation(serverMessage.message);
        break;
      default:
        throw new FatalException("Received unexpected message ${serverMessage.message.runtimeType} during handshake");
    }
  }

  /**
   * Close the channel with an optional [replyCode] and [replyText] and return a [Future]
   * to be completed when the channel is closed. If the channel is closing due to an error
   * from an incoming [classId] and [methodId] they should be included as well when invoking
   * this method.
   *
   * After closing the channel any attempt to send a message over it will cause a [StateError]
   */
  Future<Channel> _close({ ErrorType replyCode, String replyText, int classId : 0, int methodId : 0}) {

    // Already closing / closed
    if (_channelClosed != null) {
      return _channelClosed.future;
    }

    _channelClosed = new Completer<Channel>();

    if (classId == null) {
      classId = 0;
    }
    if (methodId == null) {
      methodId = 0;
    }

    // Channel #0 should close the connection instead of closing the channel
    Message closeRequest;

    if (channelId == 0) {
      closeRequest = new ConnectionClose()
        ..replyCode = replyCode.value
        ..replyText = replyText
        ..classId = classId
        ..methodId = methodId;

    } else {
      closeRequest = new ChannelClose()
        ..replyCode = replyCode.value
        ..replyText = replyText
        ..classId = classId
        ..methodId = methodId;
    }

    writeMessage(closeRequest, completer : _channelClosed, futurePayload : this);
    return _channelClosed.future;
  }

  /**
   * Process an incoming [serverFrame] sent to this channel
   */
  void handleMessage(DecodedMessage serverMessage) {

    if (_client.handshaking) {
      _processHandshake(serverMessage);
      return;
    }

    if (serverMessage is HeartbeatFrameImpl) {
      connectionLogger.info("Received heartbeat frame");
      return;
    }

    switch (serverMessage.message.runtimeType) {
    // Connection
      case ConnectionCloseOk:
        _completeOperation(serverMessage.message);
        break;
    // Channels
      case ChannelClose:
      // Ack the closing of the channel
        writeMessage(new ChannelCloseOk());

        _completeOperationWithError(serverMessage.message);
        break;
      case ChannelOpenOk:
      case ChannelCloseOk:
      case TxSelectOk:
      case TxCommitOk:
      case TxRollbackOk:
      case ChannelFlowOk:
      case BasicRecoverOk:
        _completeOperation(serverMessage.message);
        break;
    // Queues
      case QueueDeclareOk:
        QueueDeclareOk serverResponse = serverMessage.message as QueueDeclareOk;
        (_pendingOperationPayloads.first as _QueueImpl)
          .._name = serverResponse.queue
          .._messageCount = serverResponse.messageCount
          .._consumerCount = serverResponse.consumerCount;

        _completeOperation(serverResponse);
        break;
      case QueueDeleteOk:
      case QueuePurgeOk:
      case QueueBindOk:
      case QueueUnbindOk:
        _completeOperation(serverMessage.message);
        break;
    // Basic
      case BasicQosOk:
        _completeOperation(serverMessage.message);
        break;
      case BasicConsumeOk:
        BasicConsumeOk serverResponse = (serverMessage.message as BasicConsumeOk);
        Consumer consumer = (_pendingOperationPayloads.first as _ConsumerImpl)
          .._tag = serverResponse.consumerTag;
        _consumers[serverResponse.consumerTag] = consumer;
        _completeOperation(serverResponse);
        break;
      case BasicCancelOk:
        BasicCancelOk serverResponse = (serverMessage.message as BasicCancelOk);
        _consumers.remove(serverResponse.consumerTag);
        _completeOperation(serverResponse);
        break;
      case BasicDeliver:
        BasicDeliver serverResponse = (serverMessage.message as BasicDeliver);
        _ConsumerImpl target = _consumers[ serverResponse.consumerTag ];

        // no cosumer with tag
        if (target == null) {
          break;
        }

        target.onMessage(serverMessage);
        break;
    // Exchange
      case ExchangeDeclareOk:
        _completeOperation(serverMessage.message);
        break;
      case ExchangeDeleteOk:
        _completeOperation(serverMessage.message);
        break;
    }
  }

  /**
   * Complete a pending operation with [result] after receiving [serverResponse]
   * from the socket
   */
  void _completeOperation(Message serverResponse) {
    if (_pendingOperations.isEmpty) {
      return;
    }

    // Complete the first pending operation in the queue with  the first future payload
    _pendingOperations.removeFirst().complete(_pendingOperationPayloads.removeFirst());
  }

  /**
   * Complete a pending operation with [error] after receiving [serverResponse]
   * from the socket
   */
  void _completeOperationWithError(Message serverResponse) {

    Exception ex;
    switch (serverResponse.runtimeType) {
      case ConnectionClose:
        ConnectionClose closeResponse = serverResponse as ConnectionClose;
        ex = new ConnectionException(closeResponse.replyText, ErrorType.valueOf(closeResponse.replyCode), serverResponse.msgClassId, serverResponse.msgMethodId);

        // Complete the first pending operation in the queue with  the first future payload
        _pendingOperationPayloads.removeFirst();
        _pendingOperations.removeFirst().completeError(ex);

        break;
      case ChannelClose:
        ChannelClose closeResponse = serverResponse as ChannelClose;

        // If we got a NOT_FOUND error and we have a pending Queue payload emit a QueueNotFoundException
        if (closeResponse.replyCode == ErrorType.NOT_FOUND.value && _pendingOperationPayloads.first is Queue) {
          ex = new QueueNotFoundException(closeResponse.replyText, channelId, ErrorType.valueOf(closeResponse.replyCode));
        } else {
          ex = new ChannelException(closeResponse.replyText, channelId, ErrorType.valueOf(closeResponse.replyCode));
        }

        // Mark the channel as closed
        if (_channelClosed == null) {
          _channelClosed = new Completer();
        }
        if (!_channelClosed.isCompleted) {
          _channelClosed.complete();
        }
        _channelCloseException = ex;

        break;
    }


    // Complete any first pending operation in the queue with the error
    while (!_pendingOperations.isEmpty) {
      _pendingOperationPayloads.removeFirst();
      _pendingOperations.removeFirst().completeError(ex);
    }
  }

  /**
   * Abort any pending operations with [exception] and mark the channel as closed
   */
  void handleException(exception) {
    // Ignore exception if we are closed
    if (_channelClosed != null && _channelClosed.isCompleted) {
      return;
    }

    bool flagChannelAsClosed = false;

    if (exception is FatalException || exception is ChannelException) {
      flagChannelAsClosed = true;
    } else if (exception is ConnectionException) {

      // If this is channel 0 then we need to close the connection with the appropriate error code
      if (channelId == 0) {
        // Close connection (channel 0) with the appropriate error code and consider the operation completed
        _close(replyCode : exception.errorType, replyText : exception.message, classId: exception.classId, methodId: exception.methodId);
        _completeOperation(null);
      } else {
        // Non-zero channels should be marked as closed
        flagChannelAsClosed = true;
      }
    }

    // Mark the channel as closed if we need to
    if (flagChannelAsClosed) {
      if (_channelClosed == null) {
        _channelClosed = new Completer();
      }

      if (!_channelClosed.isCompleted) {
        _channelClosed.complete();
      }
    }

    if (_client.handshaking) {
      return;
    }

    // Abort any pending operations unless we are currently opening the channel
    _pendingOperations.forEach((Completer completer) {
      if (!completer.isCompleted) {
        completer.completeError(exception);
      }
    });
    _pendingOperations.clear();
    _pendingOperationPayloads.clear();
  }

  /**
   * Close the channel and return a [Future] to be completed when the channel is closed.
   *
   * After closing the channel any attempt to send a message over it will cause a [StateError]
   */
  Future close() => _close(replyCode : ErrorType.SUCCESS, replyText : "Normal shutdown");

  Future<Queue> queue(String name, {bool passive : false, bool durable : false, bool exclusive : false, bool autoDelete : false, bool noWait : false, Map<String, Object> arguments }) {
    QueueDeclare queueRequest = new QueueDeclare()
      ..reserved_1 = 0
      ..queue = name
      ..passive = passive
      ..durable = durable
      ..exclusive = exclusive
      ..autoDelete = autoDelete
      ..noWait = noWait
      ..arguments = arguments;

    Completer opCompleter = new Completer();
    writeMessage(queueRequest, completer : opCompleter, futurePayload : new _QueueImpl(this, name));
    return opCompleter.future;
  }

  Future<Queue> privateQueue({bool noWait : false, Map<String, Object> arguments }) {
    QueueDeclare queueRequest = new QueueDeclare()
      ..reserved_1 = 0
      ..queue = null
      ..passive = false
      ..durable = false
      ..exclusive = true
      ..autoDelete = false
      ..noWait = noWait
      ..arguments = arguments;

    Completer opCompleter = new Completer();
    writeMessage(queueRequest, completer : opCompleter, futurePayload : new _QueueImpl(this, ""));
    return opCompleter.future;
  }

  Future<Exchange> exchange(String name, ExchangeType type, {bool passive : false, bool durable : false, bool noWait : false, Map<String, Object> arguments }) {
    if (name == null || name.isEmpty) {
      throw new ArgumentError("The name of the exchange cannot be empty");
    }
    if (type == null) {
      throw new ArgumentError("The type of the exchange needs to be specified");
    }
    ExchangeDeclare exchangeRequest = new ExchangeDeclare()
      ..reserved_1 = 0
      ..exchange = name
      ..type = type.value
      ..passive = passive
      ..durable = durable
      ..reserved_2 = false
      ..reserved_3 = false
      ..noWait = noWait
      ..arguments = arguments;

    Completer opCompleter = new Completer();
    writeMessage(exchangeRequest, completer : opCompleter, futurePayload : new _ExchangeImpl(this, name, type));
    return opCompleter.future;
  }

  Future<Channel> qos(int prefetchSize, int prefetchCount, {bool global : true}) {
    if (prefetchSize == null) {
      prefetchSize = 0;
    }
    if (prefetchCount == null) {
      prefetchCount = 0;
    }
    BasicQos qosRequest = new BasicQos()
      ..prefetchSize = prefetchSize
      ..prefetchCount = prefetchCount
      ..global = global;

    Completer opCompleter = new Completer();
    writeMessage(qosRequest, completer : opCompleter, futurePayload : this);
    return opCompleter.future;
  }

  void ack(int deliveryTag, {bool multiple : false}) {
    BasicAck ackRequest = new BasicAck()
      ..deliveryTag = deliveryTag
      ..multiple = multiple;

    writeMessage(ackRequest);
  }

  Future<Channel> select() {
    TxSelect selectRequest = new TxSelect();
    Completer opCompleter = new Completer();
    writeMessage(selectRequest, completer : opCompleter, futurePayload : this);
    return opCompleter.future;
  }

  Future<Channel> commit() {
    TxCommit commitRequest = new TxCommit();
    Completer opCompleter = new Completer();
    writeMessage(commitRequest, completer : opCompleter, futurePayload : this);
    return opCompleter.future;
  }

  Future<Channel> rollback() {
    TxRollback rollbackRequest = new TxRollback();
    Completer opCompleter = new Completer();
    writeMessage(rollbackRequest, completer : opCompleter, futurePayload : this);
    return opCompleter.future;
  }

  Future<Channel> flow(bool active) {
    ChannelFlow flowRequest = new ChannelFlow()
      ..active = active;

    Completer opCompleter = new Completer();
    writeMessage(flowRequest, completer : opCompleter, futurePayload : this);
    return opCompleter.future;
  }

  Future<Channel> recover(bool requeue) {
    BasicRecover recoverRequest = new BasicRecover()
      ..requeue = requeue;

    Completer opCompleter = new Completer();
    writeMessage(recoverRequest, completer : opCompleter, futurePayload : this);
    return opCompleter.future;
  }
}