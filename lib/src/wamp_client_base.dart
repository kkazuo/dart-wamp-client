import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

class WampCode {
  static const int hello = 1;
  static const int welcome = 2;
  static const int abort = 3;
  static const int challenge = 4;
  static const int authenticate = 5;
  static const int goodbye = 6;
  static const int error = 8;
  static const int publish = 16;
  static const int published = 17;
  static const int subscribe = 32;
  static const int subscribed = 33;
  static const int unsubscribe = 34;
  static const int unsubscribed = 35;
  static const int event = 36;
  static const int call = 48;
  static const int cancel = 49;
  static const int result = 50;
  static const int register = 64;
  static const int registered = 65;
  static const int unregister = 66;
  static const int unregistered = 67;
  static const int invocation = 68;
  static const int interrupt = 69;
  static const int yield = 70;
}

/// WAMP RPC arguments.
class WampArgs {
  /// Array arguments.
  final List<dynamic> args;

  /// Keyword arguments.
  final Map<String, dynamic> params;

  const WampArgs([
    this.args = const <dynamic>[],
    this.params = const <String, dynamic>{},
  ]);

  factory WampArgs._toWampArgs(List<dynamic> msg, [int idx = 4]) {
    return new WampArgs(
        idx < msg.length ? (msg[idx] as List<dynamic>) : (const <dynamic>[]),
        idx + 1 < msg.length
            ? (msg[idx + 1] as Map<String, dynamic>)
            : (const <String, dynamic>{}));
  }

  List toJson() => <dynamic>[args, params];

  String toString() => JSON.encode(this);
}

/// WAMP RPC procedure type.
typedef WampArgs WampProcedure(WampArgs args);

/// WAMP subscription event.
class WampEvent {
  final int id;
  final Map details;
  final WampArgs args;

  const WampEvent(this.id, this.details, this.args);

  Map toJson() => new Map<String, dynamic>()
    ..['id'] = id
    ..['details'] = details
    ..['args'] = args.args
    ..['params'] = args.params;

  String toString() => JSON.encode(this);
}

class _Subscription {
  final StreamController<WampEvent> cntl;

  _Subscription() : cntl = new StreamController.broadcast();
}

/// WAMP RPC registration.
class WampRegistration {
  final int id;
  const WampRegistration(this.id);

  String toString() => 'WampRegistration(id: $id)';
}

/// onConnect handler type.
typedef void WampOnConnect(WampClient client);

/// WAMP Client.
///
///     var wamp = new WampClient('realm1')
///       ..onConnect = (c) {
///         // setup code here...
///       };
///
///     await wamp.connect('ws://localhost:8080/ws');
///
///
/// * [publish] / [subscribe] for PubSub.
/// * [register] / [call] for RPC.
///
class WampClient {
  /// realm.
  final String realm;
  WebSocket _ws;
  var _sessionState = #closed;
  var _sessionId = 0;
  var _sessionDetails = const <String, dynamic>{};
  final Random _random;
  final Map<int, StreamController<dynamic>> _inflights;
  final Map<int, _Subscription> _subscriptions;
  final Map<int, WampProcedure> _registrations;

  /// create WAMP client with [realm].
  WampClient(this.realm)
      : _random = new Random.secure(),
        _inflights = <int, StreamController<dynamic>>{},
        _subscriptions = {},
        _registrations = {};

  /// default client roles.
  static const Map<String, dynamic> defaultClientRoles =
      const <String, dynamic>{
    'publisher': const <String, dynamic>{},
    'subscriber': const <String, dynamic>{},
  };

  static const _keyAcknowledge = 'acknowledge';

  /// [publish] should await acknowledge from server.
  static const Map<String, dynamic> optShouldAcknowledge =
      const <String, dynamic>{_keyAcknowledge: true};

  /// [subscribe] ([register]) should prefix match on topic (url).
  static const Map<String, dynamic> optPrefixMatching = const <String, dynamic>{
    'match': 'prefix'
  };

  /// [subscribe] ([register]) should wildcard match on topic (url).
  static const Map<String, dynamic> optWildcardMatching =
      const <String, dynamic>{'match': 'wildcard'};

  /// on [connect] handler.
  ///
  ///     void myOnConnect(WampClient wamp) { ... }
  ///
  ///     var wamp = new WampClient('realm1')
  ///       ..onConnect = myOnConnect;
  ///
  ///     await wamp.connect('ws://localhost:8080/ws');
  ///
  WampOnConnect onConnect = (_) {};

  /// connect to WAMP server at [url].
  ///
  ///     await wamp.connect('wss://example.com/ws');
  Future connect(String url) async {
    _ws = await WebSocket.connect(url, protocols: ['wamp.2.json']);

    _hello();

    try {
      await for (final m in _ws) {
        final s = m is String ? m : new Utf8Decoder().convert(m as List<int>);
        final msg = JSON.decode(s) as List<dynamic>;
        _handle(msg);
      }
      print('disconnect');
    } catch (e) {
      print(e);
    }
  }

  void _handle(List<dynamic> msg) {
    switch (msg[0] as int) {
      case WampCode.hello:
        if (_sessionState == #establishing) {
          _sessionState = #closed;
        } else if (_sessionState == #established) {
          _sessionState = #failed;
        } else if (_sessionState == #shutting_down) {
          // ignore.
        } else {
          throw new Exception('on: $_sessionState, msg: $msg');
        }
        break;

      case WampCode.welcome:
        if (_sessionState == #establishing) {
          _sessionState = #established;
          _sessionId = msg[1] as int;
          _sessionDetails = msg[2] as Map<String, dynamic>;
          onConnect(this);
        } else if (_sessionState == #shutting_down) {
          // ignore.
        } else {
          throw new Exception('on: $_sessionState, msg: $msg');
        }
        break;

      case WampCode.abort:
        if (_sessionState == #shutting_down) {
          // ignore.
        } else if (_sessionState == #establishing) {
          _sessionState = #closed;
          print('aborted $msg');
        }
        break;

      case WampCode.goodbye:
        if (_sessionState == #shutting_down) {
          _sessionState = #closed;
          print('closed both!');
        } else if (_sessionState == #established) {
          _sessionState = #closing;
          goodbye();
        } else if (_sessionState == #establishing) {
          _sessionState = #failed;
        } else {
          throw new Exception('on: $_sessionState, msg: $msg');
        }
        break;

      case WampCode.subscribed:
        final code = msg[1] as int;
        final subid = msg[2] as int;
        final cntl = _inflights[code];
        if (cntl != null) {
          _inflights.remove(code);
          final sub = new _Subscription();
          sub.cntl.onCancel = () {
            _unsubscribe(subid);
          };
          _subscriptions[subid] = sub;
          cntl.add(sub.cntl.stream);
          cntl.close();
        } else {
          print('unknown subscribed: $msg');
        }
        break;

      case WampCode.unsubscribed:
        final code = msg[1] as int;
        final cntl = _inflights[code];
        if (cntl != null) {
          _inflights.remove(code);
          cntl.add(null);
          cntl.close();
        } else {
          print('unknown unsubscribed: $msg');
        }
        break;

      case WampCode.published:
        final code = msg[1] as int;
        final cntl = _inflights[code];
        if (cntl != null) {
          _inflights.remove(code);
          cntl.add(null);
          cntl.close();
        } else {
          print('unknown published: $msg');
        }
        break;

      case WampCode.event:
        final subid = msg[1] as int;
        final pubid = msg[2] as int;
        final details = msg[3] as Map<String, dynamic>;
        print(msg);
        final event = new WampEvent(
            pubid,
            details,
            new WampArgs(
                4 < msg.length
                    ? (msg[4] as List<dynamic>)
                    : (const <dynamic>[]),
                5 < msg.length
                    ? (msg[5] as Map<String, dynamic>)
                    : (const <String, dynamic>{})));
        final sub = _subscriptions[subid];
        if (sub != null) {
          sub.cntl.add(event);
        }
        break;

      case WampCode.registered:
        final code = msg[1] as int;
        final regid = msg[2] as int;
        final cntl = _inflights[code];
        if (cntl != null) {
          _inflights.remove(code);
          cntl.add(regid);
          cntl.close();
        } else {
          print('unknown registered: $msg');
        }
        break;

      case WampCode.unregistered:
        final code = msg[1] as int;
        final cntl = _inflights[code];
        if (cntl != null) {
          _inflights.remove(code);
          cntl.add(null);
          cntl.close();
        } else {
          print('unknown registered: $msg');
        }
        break;

      case WampCode.invocation:
        _invocation(msg);
        break;

      case WampCode.result:
        final code = msg[1] as int;
        final cntl = _inflights[code];
        if (cntl != null) {
          _inflights.remove(code);
          final args = new WampArgs._toWampArgs(msg, 3);
          cntl.add(args);
          cntl.close();
        } else {
          print('unknown result: $msg');
        }
        break;

      case WampCode.error:
        final cmd = msg[1] as int;
        switch (cmd) {
          case WampCode.call:
            final code = msg[2] as int;
            final cntl = _inflights[code];
            if (cntl != null) {
              _inflights.remove(code);
              final args = new WampArgs._toWampArgs(msg, 5);
              cntl.addError(args);
              cntl.close();
            } else {
              print('unknown invocation error: $msg');
            }
            break;

          case WampCode.register:
            final code = msg[2] as int;
            final cntl = _inflights[code];
            if (cntl != null) {
              _inflights.remove(code);
              final args = msg[4] as String;
              cntl.addError(new WampArgs(<dynamic>[args]));
              cntl.close();
            } else {
              print('unknown register error: $msg');
            }
            break;

          case WampCode.unregister:
            final code = msg[2] as int;
            final cntl = _inflights[code];
            if (cntl != null) {
              _inflights.remove(code);
              final args = msg[4] as String;
              cntl.addError(new WampArgs(<dynamic>[args]));
              cntl.close();
            } else {
              print('unknown unregister error: $msg');
            }
            break;

          default:
            print('unimplemented error: $msg');
        }
        break;

      case WampCode.publish:
      case WampCode.subscribe:
      case WampCode.unsubscribe:
      case WampCode.call:
      case WampCode.register:
      case WampCode.unregister:
      case WampCode.yield:
        if (_sessionState == #shutting_down) {
          // ignore.
        } else if (_sessionState == #establishing) {
          _sessionState = #failed;
        } else {
          print('unimplemented: $msg');
        }
        break;

      case WampCode.challenge:
      case WampCode.authenticate:
      case WampCode.cancel:
      case WampCode.interrupt:

      default:
        print('unexpected: $msg');
        break;
    }
  }

  void _invocation(List<dynamic> msg) {
    final code = msg[1] as int;
    final regid = msg[2] as int;
    final args = new WampArgs._toWampArgs(msg);
    final proc = _registrations[regid];
    if (proc != null) {
      try {
        final result = proc(args);
        _ws.add(JSON.encode([
          WampCode.yield,
          code,
          <String, dynamic>{},
          result.args,
          result.params
        ]));
      } on WampArgs catch (ex) {
        print('ex=$ex');
        _ws.add(JSON.encode([
          WampCode.error,
          WampCode.invocation,
          code,
          <String, dynamic>{},
          'wamp.error',
          ex.args,
          ex.params
        ]));
      } catch (ex) {
        _ws.add(JSON.encode([
          WampCode.error,
          WampCode.invocation,
          code,
          <String, dynamic>{},
          'error'
        ]));
      }
    } else {
      print('unknown invocation: $msg');
    }
  }

  void _hello() {
    if (_sessionState != #closed) {
      throw new Exception('cant send Hello after session established.');
    }

    _ws.add(JSON.encode([
      WampCode.hello,
      realm,
      {'roles': defaultClientRoles},
    ]));
    _sessionState = #establishing;
  }

  void goodbye([Map<String, dynamic> details = const <String, dynamic>{}]) {
    if (_sessionState != #established && _sessionState != #closing) {
      throw new Exception('cant send Goodbye before session established.');
    }

    void send_goodbye(String reason, Symbol next) {
      _ws.add(JSON.encode([
        WampCode.goodbye,
        details,
        reason,
      ]));
      _sessionState = next;
    }

    if (_sessionState == #established) {
      send_goodbye('wamp.error.close_realm', #shutting_down);
    } else {
      send_goodbye('wamp.error.goodbye_and_out', #closed);
    }
  }

  void _abort([Map<String, dynamic> details = const <String, dynamic>{}]) {
    if (_sessionState != #establishing) {
      throw new Exception('cant send Goodbye before session established.');
    }

    _ws.add(JSON.encode([
      WampCode.abort,
      details,
      'abort',
    ]));
    _sessionState = #closed;
  }

  /// register RPC at [uri] with [proc].
  ///
  ///     wamp.register('your.rpc.name', (arg) {
  ///       print('got $arg');
  ///       return arg;
  ///     });
  Future<WampRegistration> register(String uri, WampProcedure proc,
      [Map options = const <String, dynamic>{}]) {
    final cntl = new StreamController<int>();
    _goFlight(cntl, (code) => [WampCode.register, code, options, uri]);
    return cntl.stream.last.then((regid) {
      _registrations[regid] = proc;
      return new WampRegistration(regid);
    });
  }

  /// unregister RPC [id].
  ///
  ///     wamp.unregister(your_rpc_id);
  Future<Null> unregister(WampRegistration reg) {
    final cntl = new StreamController<int>();
    _goFlight(cntl, (code) => [WampCode.unregister, code, reg.id]);
    return cntl.stream.last.then((dynamic _) {
      _registrations.remove(reg.id);
      return null;
    });
  }

  /// call RPC with [args] and [params].
  ///
  ///     wamp.call('your.rpc.name', ['myarg', 3], {'hello': 'world'})
  ///       .then((result) {
  ///         print('got result=$result');
  ///       })
  ///       .catchError((error) {
  ///         print('call error=$error');
  ///       });
  Future<WampArgs> call(String uri,
      [List<dynamic> args = const <dynamic>[],
      Map<String, dynamic> params = const <String, dynamic>{},
      Map options = const <String, dynamic>{}]) {
    final cntl = new StreamController<WampArgs>();
    _goFlight(
        cntl, (code) => [WampCode.call, code, options, uri, args, params]);
    return cntl.stream.last;
  }

  /// subscribe [topic].
  ///
  ///     wamp.subscribe('topic').then((stream) async {
  ///       await for (var event in stream) {
  ///         print('event=$event');
  ///       }
  ///     });
  Future<Stream<WampEvent>> subscribe(String topic,
      [Map options = const <String, dynamic>{}]) {
    final cntl = new StreamController<Stream<WampEvent>>();
    _goFlight(cntl, (code) => [WampCode.subscribe, code, options, topic]);
    return cntl.stream.last;
  }

  Future _unsubscribe(int subid) {
    _subscriptions.remove(subid);

    final cntl = new StreamController<Null>();
    _goFlight(cntl, (code) => [WampCode.unsubscribe, code, subid]);
    return cntl.stream.last;
  }

  /// publish [topic].
  ///
  ///     wamp.publish('topic');
  Future<Null> publish(
    String topic, [
    List<dynamic> args = const <dynamic>[],
    Map<String, dynamic> params = const <String, dynamic>{},
    Map options = const <String, dynamic>{},
  ]) {
    final cntl = new StreamController<Null>();
    final code = _goFlight(
        cntl, (code) => [WampCode.publish, code, options, topic, args, params]);

    final dynamic acknowledge = options[_keyAcknowledge];
    if (acknowledge is bool && acknowledge) {
      return cntl.stream.last;
    } else {
      _inflights.remove(code);
      return new Future<Null>.value(null);
    }
  }

  int _flightCode(StreamController<dynamic> val) {
    int code = 0;
    do {
      code = _random.nextInt(1000000000);
    } while (_inflights.containsKey(code));

    _inflights[code] = val;
    return code;
  }

  int _goFlight(StreamController<dynamic> cntl, dynamic data(int code)) {
    final code = _flightCode(cntl);
    try {
      _ws.add(JSON.encode(data(code)));
      return code;
    } catch (_) {
      _inflights.remove(code);
      rethrow;
    }
  }
}
